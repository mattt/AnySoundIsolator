# AnySoundIsolator

AnySoundIsolator is a Swift package that isolates a sound, such as a voice,
from a recording or a live stream.

```swift
import AnySoundIsolator

let isolator = SoundIsolator()
try await isolator.isolate(contentsOf: recording, to: voice)
```

The default engine uses Apple's built-in sound isolation audio unit.
It handles live audio without a download.
For recordings, the `MLX` [package trait](#inworld) adds
[Inworld's Voice Isolator](https://github.com/inworld-ai/voice-isolator),
a neural network that runs on the GPU with [MLX](https://github.com/ml-explore/mlx-swift).
It needs a 256 MB download, runs slower, and uses much more memory.

Every model preserves the input's sample rate, channel count, and frame count.
Frame `n` of the output corresponds to frame `n` of the input.
The isolator removes the engine's delay,
so you can crossfade between the isolated sound and the original.

## Requirements

- Swift 6.2 or later
- macOS 26 or later, or iOS 26 or later

## Installation

Add the package to your `Package.swift`.

```swift
.package(url: "https://github.com/mattt/AnySoundIsolator", branch: "main")
```

With the default traits, the library has no dependencies.
Enable the `MLX` trait to include the Inworld model,
[MLX Swift](https://github.com/ml-explore/mlx-swift),
and [swift-huggingface](https://github.com/huggingface/swift-huggingface).

```swift
.package(url: "https://github.com/mattt/AnySoundIsolator", branch: "main", traits: ["MLX"])
```

## Usage

### Isolate a recording

Optionally, pass a `Progress` object to track progress
and a second destination to save the background.

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

Input can be any file `AVAudioFile` reads.
Choose a destination ending in `wav` or `caf` to preserve Float32 samples exactly,
or `m4a` for smaller, lossy AAC files.

The isolator reads and writes in blocks.
Both built-in models return audio incrementally, keeping memory use bounded.
An engine that defers all output needs memory for the whole recording.

The isolator checks both destinations before opening a file,
then writes temporary files alongside them.
After writing all audio, it moves each file into place, replacing any existing file.
Cancel the task to stop.
On error or cancellation, the isolator discards temporary files and preserves existing destinations.
The background moves first and keeps its new contents if the second move fails.

### Stream results from a file

Play or display results in order with `streamIsolation(contentsOf:)`.

```swift
for try await audio in isolator.streamIsolation(contentsOf: recording) {
    await player.scheduleBuffer(audio.buffer)
}
```

Each `IsolatedAudio` contains the isolated `buffer`,
the corresponding `source` frames, and their `framePosition` on the input timeline.

### Isolate live audio

Supply captured audio as an `AsyncSequence` of `AudioInput` values.
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

The isolator reads on demand and has no input queue.
If capture outpaces isolation, the example's `AsyncStream` buffers without limit.
To limit it, give `makeStream` a buffering policy, such as `.bufferingNewest(8)`;
the stream then drops audio.
The output continues without the dropped audio, and its frame positions stay consecutive.

Supply your own capture in any PCM format and use that format throughout the stream.
Output is deinterleaved Float32 at the input's sample rate and channel count.
Engine latency delays the first frames and leaves a tail after input ends.
Buffer sizes can differ, but total frame counts match.

For one buffer in memory, use `isolate(_:)`.

### The background and the mix

`IsolatedAudio` computes the background by subtracting the isolated sound
from the source.

```swift
let background = audio.background()
let mostlyVoice = audio.mixed(backgroundLevel: 0.25)
```

The mix, `(1 - level) * buffer + level * source`, ranges from isolated sound at 0 to source at 1.
A player can set the original and isolated track volumes to `level` and `1 - level`
with an `AVAudioMix`.

### Stereo input and a mono engine

When the input has more channels than the engine accepts,
the isolator averages them, processes the downmix once,
and copies the isolated sound to every output channel.
Use `perChannel` for an interview with one speaker per channel.

```swift
let options = IsolationOptions(channelPolicy: .perChannel)
try await isolator.isolate(contentsOf: interview, to: voices, options: options)
```

With `perChannel`, each channel adds work for the engine.
Both policies preserve the channel count.
In each channel, the isolated sound and background add up to the source.
After a downmix, only the background retains the differences between channels.

All isolation methods accept `options`.
The policy has no effect when the engine accepts all channels,
as the system model does for stereo.

### Choose a model

Pass a model to `SoundIsolator`.
Request any assets before isolation, which never downloads files.

```swift
let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: .standard))
guard isolator.isAvailable else { return }
if let request = try await isolator.assetInstallationRequest() {
    try await request.downloadAndInstall()
}
```

The default system model needs no files, so its request is always `nil`.
With `MLX`, `InworldSoundIsolationModel` downloads and verifies one file on request.

```swift
let isolator = SoundIsolator(model: InworldSoundIsolationModel())
if let request = try await isolator.assetInstallationRequest() {
    print("Downloading \(request.progress.totalUnitCount) bytes")
    try await request.downloadAndInstall()
}
try await isolator.isolate(contentsOf: recording, to: voice)
```

Without the file, isolation throws `SoundIsolationError.missingAssets`.
See [Inworld](#inworld) for performance and memory use.

### Command-line tool

Use `silence` to isolate the voice in a local file.
Its default subcommand, `isolate`, accepts `--background` to save the removed sound.
Use `--channel-policy perChannel` for separate channels
when the model takes fewer channels than the file has.

```console
$ swift run silence recording.m4a voice.wav
$ swift run silence isolate recording.m4a voice.m4a --background rest.m4a --quality standard
$ swift run silence status
```

With `MLX` enabled, `prepare` downloads and verifies the Inworld model
or verifies a copy in the Hugging Face cache.

```console
$ swift run --traits MLX silence prepare --model inworld
$ swift run --traits MLX silence recording.m4a voice.wav --model inworld
$ swift run --traits MLX silence status --model inworld
```

Both isolation and `status` work without downloads.
Use `status` to check availability and installed files.
Run `swift run silence --help` for all options.

## Models

### System

`SystemSoundIsolationModel` uses the `kAudioUnitSubType_AUSoundIsolation` audio unit offline.

| | `.high` (default) | `.standard` |
| --- | --- | --- |
| Audio unit sound type | High-quality voice | Voice |
| Delay that the package removes, mono at 48 kHz | 4,440 frames (92.5 ms) | 2,705 frames (56.4 ms) |
| Delay that the package removes, stereo at 48 kHz | 6,360 frames (132.5 ms) | 3,665 frames (76.4 ms) |

The audio unit runs at the input sample rate.
Tests cover 8, 16, 44.1, 48, and 96 kHz.
Mono and stereo input go directly to the unit, which processes stereo channels jointly.
The left output depends on the right input,
and identical stereo channels give a different result from mono.
For three or more channels, the [channel policy](#stereo-input-and-a-mono-engine)
selects a mono downmix by default or one audio unit per channel with `perChannel`.

In a live stream, the audio unit delays each frame
because it needs the following audio to isolate it.

The audio unit does not always give the same samples for the same audio.
On an M4 Max running macOS 27, a buffer, a stream, and a file gave identical samples.
On virtual machines running macOS 27, two runs differed in most samples
but kept the same length, timing, and level; the cause is unknown.
Do not compare the system model's output sample for sample.

#### Performance

A release build of `silence` processed 10 minutes of synthetic 48 kHz audio
on an M4 Max running macOS 27.0.
Both quality settings took about the same time.

| Input | Time | Peak memory |
| --- | --- | --- |
| Mono | 6.6 to 6.9 s | 41 to 45 MB |
| Stereo | 14.2 to 15.1 s | 41 to 53 MB |

[Inworld](#inworld) took about 59 s and 4.4 GB for 10 minutes of mono audio.

### Inworld

With the `MLX` trait, `InworldSoundIsolationModel` runs `voice-isolator-v1`,
the offline checkpoint of [Inworld's Voice Isolator](https://github.com/inworld-ai/voice-isolator),
in a Swift port for MLX.
See [Limitations](#limitations).

**Output.** The port matches Inworld's reference renders within Inworld's 1e-4 tolerance.
On the GPU, maximum file API errors for the two golden fixtures were
4.2e-7 for 3 seconds and 5.4e-7 for 11 seconds.

**Assets.** The model uses `denoiser.safetensors` (256,260,128 bytes)
from [`inworld/voice-isolator`](https://huggingface.co/inworld/voice-isolator) on Hugging Face.
`assetInstallationRequest()` downloads nothing.
It returns a request, or `nil` when the model is ready.
It throws on hardware that cannot run the model or when a file that you supply is missing.
Call `downloadAndInstall()` to fetch the pinned revision,
verify its size and SHA-256 digest, and record verification.

The file goes into the Hugging Face cache, which other tools share.
The cache is the directory that `HF_HUB_CACHE` names, or else `hub` in the directory that `HF_HOME` names,
or else `~/.cache/huggingface/hub`.
A file that is already in the cache is verified and not downloaded again.
Without those variables, a sandboxed app keeps the file in its container,
in `Application Support/AnySoundIsolator/HuggingFace/hub`, which the package excludes from backups.
Besides App Sandbox, only downloading requires an entitlement for outgoing network connections.
Pass `assets: .file(url)` to use your own file without downloading or checking its digest.

**Format.** The network takes mono audio at 48 kHz.
Other rates need resampling.
The default [channel policy](#stereo-input-and-a-mono-engine) gives stereo the same cost as mono.

**Windows.** The network uses 8-second windows with a 2-second overlap.
Inworld's offline render places the windows with the length of the clip known:
every window is a full one, and the last window ends at the end of the clip.
A clip shorter than 8 seconds is one short window.
A stream returns the first 6 seconds and holds the 2-second crossfade
until the next window or end of input.
This matches Inworld's placement without knowing the length in advance.
What differs is when the frames arrive:
the first frames come after 8 seconds of input, then 6 seconds of output for each 6 seconds of input,
and the rest after the input ends.
A stream shorter than 8 seconds returns all of its frames after the input ends.
In tests, a file, a single buffer, and streams of several buffer sizes
produced a sample difference of exactly 0.
Use the system model for live conversation.

**Cost.** These measurements used release builds with MLX Swift 0.33.0
on an M4 Max with 36 GB of memory running macOS 27.0.1,
after the process's first render on 2026-11-20.

| Audio (48 kHz mono) | Time, file to file | Peak memory footprint |
| --- | --- | --- |
| 11 s | 1.17 to 1.21 s | 4.2 GB |
| 1 min | 5.79 to 5.84 s | 4.3 to 4.6 GB |
| 10 min | 58.6 to 59.6 s | 4.4 GB |

The model processed about 10 seconds of audio per second.
File output began after about 0.6 s.
Processing one window at a time keeps memory use bounded.
Before integration, MLX used about 3.6 GB of GPU memory at peak for one window.
Open streams keep the 256 MB weights loaded and shared, rendering windows in turn.

MLX caches freed GPU buffers without a limit by default.
While a stream is open, the package lowers that limit to 512 MiB,
and it restores the earlier limit afterward.
It leaves a lower limit alone, and it keeps a limit that the app sets in the meantime.
This process-wide limit also applies to other MLX code.
Without it, a one-minute render used 5.5 GB and ran 3 percent faster.

**First render.** Metal compiles the GPU kernels on first use and caches them per app.
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

**Platforms.** The trait supports macOS on Apple silicon.
The library also compiles for iOS with the trait, but nobody has run it there.
On a Mac, the process used more than 4 GB, which is likely more than iOS gives to most apps,
so do not rely on the model on iOS.

**Toolchain.** Command-line builds need SwiftPM support for MLX's Metal shaders.
Builds used Swift 6.4.2.
MLX Swift 0.31.6 and later need Swift 6.3.
Xcode also builds MLX Swift 0.31.4, which gave maximum errors of 4.2e-7 and 6.0e-7, also within the tolerance.
Install the Metal toolchain with `xcodebuild -downloadComponent MetalToolchain`.
`mise run build:mlx` locates it.

**License.** Inworld publishes its code and weights under the Apache License, Version 2.0.
Apps can display `InworldSoundIsolationModel().attribution`.
See [NOTICE](NOTICE) for the parts adapted from Inworld's code.

### Custom models

Implement `SoundIsolationModel` for configuration and `SoundIsolationExecutor` per stream.
The executor declares its sample rate, channel count, and latency.
The isolator resamples in both directions, applies `IsolationOptions` for mono engines,
removes latency from the start, and pads or trims the end to match the input length.
It handles file I/O, progress, background, and mixing.

An executor can return zero or more frames per call,
such as a completed window or a hosted service's entire result from `finish()`.
Input stays in memory until the executor returns matching output.

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

- In an earlier prototype, [Inworld](#inworld) sounded much better to me
  than the system model on one long voice recording.
  No one has listened to this package's output.
  Tests check length and timing with synthetic signals
  and compare Inworld output with its reference renders.
- The package does not have Inworld's realtime checkpoint.
- Inworld is untested on an Intel Mac or with less than 36 GB of memory.
- The audio unit reports a delay of 92.5 ms for high quality and about 56.35 ms for standard quality in mono.
  The package rounds it to a whole frame.
  Where it is not a whole number of frames, such as at 44.1 kHz, or at 16 kHz with standard quality,
  the output can be off the input's timeline by less than one frame.
- With the standard quality, the measured delay of the isolated voice
  was one frame less than the delay that the audio unit reports.
- Extract the audio from video files before isolation.
- The package hasn't been tested on a physical iPhone, on the OS 26 runtime,
  or with the minimum Swift 6.2 toolchain.

## Development

The [mise](https://mise.jdx.dev/) tasks use Swift from the selected Xcode.
Model downloads are listed in the task descriptions.
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

`Package.resolved` pins dependencies with the `MLX` trait enabled.
SwiftPM saves pins for the current build's traits,
so `swift build` or `swift run` without the trait rewrites the file in a checkout.
The tasks that build, test, or run with SwiftPM pass `--only-use-versions-from-resolved-file`,
which makes SwiftPM read the file and not write it.
`build:ios` uses `xcodebuild` and does not pass the flag.
To update a version, run `xcrun swift package --traits MLX update` and commit the file.

The tests compile the examples in
[`ReadmeExamples.swift`](Tests/AnySoundIsolatorTests/ReadmeExamples.swift),
including the Inworld examples when the `MLX` trait is enabled.

## License

AnySoundIsolator is available under the Apache License, Version 2.0.
See [LICENSE](LICENSE) for details.
The Inworld model is adapted from Inworld's Voice Isolator under the same license.
See [NOTICE](NOTICE).
