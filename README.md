# AnySoundIsolator

AnySoundIsolator is a Swift package that isolates a sound, such as a voice,
from a recording or a live stream.

```swift
import AnySoundIsolator

let isolator = SoundIsolator()
try await isolator.isolate(contentsOf: recording, to: voice)
```

By default, `SoundIsolator` uses Apple's built-in sound isolation audio unit.
It can isolate live audio without a download.
For recordings, the [`MLX` package trait](#inworld) adds
[Inworld's Voice Isolator](https://github.com/inworld-ai/voice-isolator),
a neural network that runs on the GPU with [MLX](https://github.com/ml-explore/mlx-swift).
It needs a 256 MB download, runs slower, and uses more memory.

Every model preserves the input's sample rate, channel count, and frame count.
Frame `n` of the output corresponds to frame `n` of the input.
The isolator removes the engine's delay so you can crossfade
between the isolated sound and the original.
See [Limitations](#limitations) for timing precision.

## Requirements

- Swift 6.2 or later
- macOS 26 or later, or iOS 26 or later

The Inworld model supports macOS on Apple silicon.
Install the Metal toolchain with `xcodebuild -downloadComponent MetalToolchain`.
Command-line builds need SwiftPM support for MLX's Metal shaders.
MLX Swift 0.31.6 and later need Swift 6.3.
Xcode can also build MLX Swift 0.31.4.

## Installation

Add the package to your `Package.swift`.

```swift
.package(url: "https://github.com/mattt/AnySoundIsolator", branch: "main")
```

With the default traits, the library has no dependencies.
Enable the `MLX` trait to add the Inworld model,
[MLX Swift](https://github.com/ml-explore/mlx-swift),
and [swift-huggingface](https://github.com/huggingface/swift-huggingface).

```swift
.package(url: "https://github.com/mattt/AnySoundIsolator", branch: "main", traits: ["MLX"])
```

## Usage

### Isolate a recording

Input can be any file `AVAudioFile` reads.
Pass `background` to save the removed sound and `progress` to track progress.

```swift
let isolator = SoundIsolator()
let progress = Progress()
try await isolator.isolate(
    contentsOf: recording,
    to: voice,
    background: background,
    progress: progress
)
```

Use `.wav` or `.caf` to preserve Float32 samples exactly,
or `.m4a` for a smaller, lossy AAC file.
Both built-in models process recordings in blocks to keep memory use bounded.

The isolator checks both destinations before opening a file,
then writes temporary files alongside them.
If isolation fails or you cancel the task,
the isolator discards temporary files and preserves existing destinations.
After writing all the audio, it replaces the background file first.
If the second move fails, the new background stays in place.

### Stream results from a file

To play or display results in order, call `streamIsolation(contentsOf:)`.

```swift
for try await audio in isolator.streamIsolation(contentsOf: recording) {
    await player.scheduleBuffer(audio.buffer)
}
```

Each `IsolatedAudio` contains the isolated `buffer`,
the corresponding `source` frames, and their `framePosition` on the input timeline.

### Isolate live audio

Supply an `AsyncSequence` of `AudioInput` values in a single PCM format.
Unlike `AVAudioPCMBuffer`, `AudioInput` is `Sendable`.
It copies the capture buffer so the audio system can reuse it.

```swift
let (buffers, input) = AsyncStream<AudioInput>.makeStream()
engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
    input.yield(AudioInput(buffer: buffer))
}
try engine.start()

for try await audio in isolator.streamIsolation(of: buffers) {
    await player.scheduleBuffer(audio.buffer)
}
```

The isolator reads on demand without an input queue.
If capture outpaces isolation, this `AsyncStream` buffers without limit.
Pass `.bufferingNewest(8)` to `makeStream` to drop audio when the buffer is full.
Output frame positions stay consecutive.

Output is deinterleaved Float32.
Engine latency delays the first frames and leaves a tail after input ends.
Buffer sizes can differ, but total frame counts match.
For one buffer in memory, call `isolate(_:)`.

### The background and the mix

`IsolatedAudio` computes the background by subtracting the isolated sound
from the source.

```swift
let background = audio.background()
let mostlyVoice = audio.mixed(backgroundLevel: 0.25)
```

The mix, `(1 - level) * buffer + level * source`,
ranges from isolated sound at 0 to source at 1.
For playback with `AVAudioMix`, set the original track's volume to `level`
and the isolated track's volume to `1 - level`.

### Stereo input and a mono engine

When the input has more channels than the engine accepts,
the isolator averages them, processes the downmix once,
and copies the result to each channel.
Only the background retains the differences between channels.
For an interview with one speaker per channel, use `perChannel`.

```swift
let options = IsolationOptions(channelPolicy: .perChannel)
try await isolator.isolate(contentsOf: interview, to: voices, options: options)
```

Processing each channel separately costs more.
In each channel, the isolated sound and background add up to the source.
All isolation methods accept `options`.
A model that accepts all input channels ignores the policy,
as the system model does for stereo.

### Choose a model

Pass a model to `SoundIsolator` and request any assets before isolation.
The system model needs no files, so its request is always `nil`.

```swift
let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: .standard))
guard isolator.isAvailable else { return }
if let request = try await isolator.assetInstallationRequest() {
    try await request.downloadAndInstall()
}
```

`InworldSoundIsolationModel` downloads and verifies one file on request.
Without the file, isolation throws `SoundIsolationError.missingAssets`.

```swift
let isolator = SoundIsolator(model: InworldSoundIsolationModel())
if let request = try await isolator.assetInstallationRequest() {
    print("Downloading \(request.progress.totalUnitCount) bytes")
    try await request.downloadAndInstall()
}
try await isolator.isolate(contentsOf: recording, to: voice)
```

### Command-line tool

`silence` isolates the voice in a local file with its default subcommand, `isolate`.
Pass `--background` to save the removed sound.
Use `--channel-policy perChannel` for separate channels
when the model accepts fewer channels than the file has.

```console
$ swift run silence recording.m4a voice.wav
$ swift run silence isolate recording.m4a voice.m4a --background rest.m4a --quality standard
$ swift run silence status
```

With `MLX` enabled, `prepare` verifies the Inworld model in the Hugging Face cache,
downloading it if needed.

```console
$ swift run --traits MLX silence prepare --model inworld
$ swift run --traits MLX silence recording.m4a voice.wav --model inworld
$ swift run --traits MLX silence status --model inworld
```

Use `status` to check availability and installed files.
Neither isolation nor `status` downloads files.
Run `swift run silence --help` for all options.

## Models

### System

`SystemSoundIsolationModel` uses the `kAudioUnitSubType_AUSoundIsolation` audio unit offline.

| | `.high` (default) | `.standard` |
| --- | --- | --- |
| Audio unit sound type | High-quality voice | Voice |
| Delay that the package removes, mono at 48 kHz | 4,440 frames (92.5 ms) | 2,705 frames (56.4 ms) |
| Delay that the package removes, stereo at 48 kHz | 6,360 frames (132.5 ms) | 3,665 frames (76.4 ms) |

The audio unit accepts mono and stereo at the input sample rate.
It processes stereo channels jointly.
The left output depends on the right input,
and identical stereo channels give a different result from mono.
For three or more channels, the [channel policy](#stereo-input-and-a-mono-engine)
selects a mono downmix by default or one audio unit per channel with `perChannel`.

In a live stream, each frame waits for the audio that follows it.
Samples can differ across runs.
On macOS 27 virtual machines, two runs differed in most samples
but kept the same length, timing, and level.

#### Performance

A release build of `silence` processed 10 minutes of synthetic 48 kHz audio
on an M4 Max running macOS 27.0.
Both quality settings took about the same time.

| Input | Time | Peak memory |
| --- | --- | --- |
| Mono | 6.6 to 6.9 s | 41 to 45 MB |
| Stereo | 14.2 to 15.1 s | 41 to 53 MB |

### Inworld

`InworldSoundIsolationModel` is a Swift port of
[Inworld's Voice Isolator](https://github.com/inworld-ai/voice-isolator)
that runs the offline `voice-isolator-v1` checkpoint with MLX.
The network takes 48 kHz mono audio.
Other rates require resampling.
The default [channel policy](#stereo-input-and-a-mono-engine) gives stereo the same cost as mono.

#### Install the model

The model uses `denoiser.safetensors` (256,260,128 bytes)
from [`inworld/voice-isolator`](https://huggingface.co/inworld/voice-isolator).
`assetInstallationRequest()` returns a request, or `nil` if the model is ready.
It throws if the hardware cannot run the model or a file you supply is missing.
Call `downloadAndInstall()` to fetch the pinned revision,
verify its size and SHA-256 digest, and record verification.
It verifies an existing cached file without downloading it again.

Other tools can share the Hugging Face cache.
Set `HF_HUB_CACHE` to choose the cache directory.
Otherwise, the package uses `hub` under `HF_HOME` if set,
or `~/.cache/huggingface/hub`.
Without either variable, a sandboxed app uses
`Application Support/AnySoundIsolator/HuggingFace/hub` in its container,
which the package excludes from backups.
Besides App Sandbox, only downloading requires an entitlement for outgoing network connections.
Pass `assets: .file(url)` to use your own file without downloading or checking its digest.

#### Streaming

As in Inworld's offline render, the stream uses 8-second windows with a 2-second overlap.
The last window ends with the clip.
Every window is full unless the entire clip is shorter than 8 seconds.

After 8 seconds of input, the stream returns the first 6 seconds
and holds 2 seconds for the crossfade.
It then returns 6 seconds for each 6 seconds of input and the rest when input ends.
Streams shorter than 8 seconds return all frames at the end.
Use the system model for live conversation.

#### Performance and memory

These measurements used release builds with MLX Swift 0.33.0
on an M4 Max with 36 GB of memory running macOS 27.0.1,
after the process's first render on 2026-11-20.

| Audio (48 kHz mono) | Time, file to file | Peak memory footprint |
| --- | --- | --- |
| 11 s | 1.17 to 1.21 s | 4.2 GB |
| 1 min | 5.79 to 5.84 s | 4.3 to 4.6 GB |
| 10 min | 58.6 to 59.6 s | 4.4 GB |

File output began after about 0.6 s.
Open streams share the 256 MB weights and process one window at a time
to keep memory use bounded.

By default, MLX caches freed GPU buffers without a limit.
While a stream is open, the package limits the process-wide cache to 512 MiB
unless the limit is already lower.
It restores the previous limit afterward unless the app has set another one.
Without the limit, a one-minute render used 5.5 GB and ran 3 percent faster.

Metal compiles GPU kernels on first use and caches them per app.
An empty cache added about 2.4 s.
Later launches start at full speed unless another process of the app
holds the cache file open, forcing recompilation.
This applies inside and outside the sandbox.
To compile at launch, isolate a short silent buffer.

```swift
let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
silence.frameLength = 4_800
_ = try await isolator.isolate(silence)
```

This took 2.6 s with an empty cache and 0.05 s on later launches.

### Custom models

Implement `SoundIsolationModel` for configuration
and `SoundIsolationExecutor` for each stream.
The executor declares its sample rate, channel count, and latency.
The isolator resamples in both directions, applies `IsolationOptions` for mono engines,
removes latency, and pads or trims the end to match the input length.
It handles file I/O, progress, background, and mixing.

An executor can return zero or more frames per call.
Input stays in memory until the executor returns matching output.
Waiting until `finish()` requires memory for the whole recording.

This model halves the volume.

```swift
import AnySoundIsolator

struct HalfVolumeModel: SoundIsolationModel {
    var availability: Availability<Never> { .available }

    func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor {
        HalfVolumeExecutor(sampleRate: request.sampleRate, channelCount: request.channelCount)
    }
}

struct HalfVolumeExecutor: SoundIsolationExecutor {
    let sampleRate: Double
    let channelCount: Int
    let latency = 0

    func process(_ input: AudioSamples) async throws -> AudioSamples {
        AudioSamples(channels: input.channels.map { channel in channel.map { $0 * 0.5 } })
    }

    func finish() async throws -> AudioSamples {
        AudioSamples(channelCount: channelCount)
    }
}

let isolator = SoundIsolator(model: HalfVolumeModel())
```

Report required files in `availability` and return an installation request
from `assetInstallationRequest()`.
If files are missing, `makeExecutor(for:)` throws `SoundIsolationError.missingAssets`.

## Limitations

- The package does not have Inworld's realtime checkpoint.
- Inworld is untested on an Intel Mac or with less than 36 GB of memory.
  The library compiles for iOS with the `MLX` trait, but nobody has run it there.
  On a Mac, the process used more than 4 GB,
  likely more than iOS gives to most apps.
  Do not rely on this model on iOS.
- In mono, the audio unit reports 92.5 ms of delay at high quality
  and about 56.35 ms at standard quality.
  The package rounds to a whole frame.
  Fractional delays can put the output less than one frame off the input timeline,
  as at 44.1 kHz or at 16 kHz with standard quality.
- At standard quality, the measured voice delay was one frame less than the audio unit reported.
- Extract audio from video files before isolation.
- The package hasn't been tested on a physical iPhone, on the OS 26 runtime,
  or with the minimum Swift 6.2 toolchain.

## Development

The [mise](https://mise.jdx.dev/) tasks use Swift from the selected Xcode.
MLX tasks require Apple silicon and the Metal toolchain.

| Task | Description |
| --- | --- |
| `mise run setup` | Resolve package dependencies. |
| `mise run build` | Build the library and the `silence` command. |
| `mise run build:ios` | Compile the library for iOS. |
| `mise run build:mlx` | Build the library and `silence` with the `MLX` trait. |
| `mise run build:mlx:ios` | Compile the library for iOS with the `MLX` trait. |
| `mise run test` | Run the tests, which make their own audio. |
| `mise run test:mlx` | Run the tests with the `MLX` trait and its GPU tests, without a download. |
| `mise run test:parity` | Compare the Inworld model with Inworld's golden fixtures. Downloads the checkpoint (256 MB) unless it is in the Hugging Face cache. |
| `mise run fetch:fixtures` | Download Inworld's golden fixtures (3 MB, CC BY 4.0) into `Fixtures/`, which Git ignores. |
| `mise run prepare:inworld` | Download and verify the Inworld checkpoint (256 MB). |
| `mise run lint` | Check the formatting of the Swift sources. |
| `mise run format` | Format the Swift sources in place. |

## License

AnySoundIsolator is available under the [Apache License, Version 2.0](LICENSE).
Inworld publishes its code and weights under the same license.
See [NOTICE](NOTICE) for attribution.
Apps can display `InworldSoundIsolationModel().attribution`.
