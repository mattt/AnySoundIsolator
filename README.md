# AnySoundIsolator

AnySoundIsolator is a Swift package that isolates a sound, such as a voice,
from a recording or a live stream, with a choice of engine.

```swift
import AnySoundIsolator

let isolator = SoundIsolator()
try await isolator.isolate(contentsOf: recording, to: voice)
```

Every engine gives output with the same properties:

- The isolated sound has the input's sample rate, channel count, and number of frames.
- Frame `n` of the output corresponds to frame `n` of the input.
  The package removes an engine's delay, so you never correct for it.

Because of this, the sound that was removed is the input minus the output,
and a mix of the two is a crossfade.
You can play the isolated sound in place of the original
and let a listener mix the background back in.

The package has two engines:

- Apple's sound isolation audio unit, which is part of the operating system.
  It needs no download, and it is fast enough for live audio.
- [Inworld's Voice Isolator](https://github.com/inworld-ai/voice-isolator),
  a neural network that runs on the GPU with [MLX](https://github.com/ml-explore/mlx-swift).
  It is for recordings: it downloads a 256 MB file, and it is slower and uses much more memory.
  The package includes it only when you enable the `MLX` [package trait](#inworld).

The engine interface also fits other models that download their weights, and hosted services.

## Requirements

- Swift 6.2 or later
- macOS 26 or later, or iOS 26 or later

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/mattt/AnySoundIsolator", from: "0.1.0")
```

The library has no dependencies.
To add the Inworld model, enable the `MLX` trait,
which adds [MLX Swift](https://github.com/ml-explore/mlx-swift)
and [swift-huggingface](https://github.com/huggingface/swift-huggingface):

```swift
.package(url: "https://github.com/mattt/AnySoundIsolator", from: "0.1.0", traits: ["MLX"])
```

## Usage

### Isolate the voice in a recording

Give the isolator a file and a place for the result.
A `Progress` object reports how far the work is,
and an optional second file receives the sound that was removed:

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

The source can be any file that `AVAudioFile` reads.
The destination's extension selects its type:
`wav` and `caf` hold Float32 samples, so they hold the output exactly,
and `m4a` holds AAC, which is smaller and is not exact.
The isolator reads and writes one block at a time,
so a long recording does not need more memory than a short one.

The isolator checks both destinations before it opens a file,
and writes each output to a temporary file in the destination's directory.
It moves the temporary files to their destinations only when all the audio is written,
and that move replaces a file that is already there.
To stop, cancel the task.
After a cancellation or an error, the isolator removes the temporary files,
and each destination is as it was before the call.
The background moves first:
if the move of the isolated sound then fails, the background holds its new content.

### Get results while a long file is processed

`streamIsolation(contentsOf:)` returns the isolated sound in pieces, in order,
so that you can play or show the start of a recording before the end is ready:

```swift
for try await audio in isolator.streamIsolation(contentsOf: recording) {
    await player.scheduleBuffer(audio.buffer)
}
```

Each `IsolatedAudio` has the isolated sound in `buffer`,
the matching frames of the input in `source`,
and their position on the input's timeline in `framePosition`.

### Isolate live audio

Supply audio as an `AsyncSequence` of `AudioInput` values.
`AudioInput` copies a capture buffer, so the audio system can reuse the buffer,
and it is `Sendable`, which `AVAudioPCMBuffer` is not:

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

The package does not capture audio.
The input can be in any PCM format, and every input of a stream must have the same format.
The output is deinterleaved Float32 audio at the input's sample rate and channel count.
An engine with a delay returns the first frames late and the last frames after the input ends,
so the pieces of output do not have the sizes of the pieces of input.
Across the whole stream, the output has exactly as many frames as the input.

For audio that is already in memory, `isolate(_:)` takes one buffer and returns one result.

### The background and the mix

The background is the source minus the isolated sound,
and `IsolatedAudio` computes it and a mix for you:

```swift
let background = audio.background()
let mostlyVoice = audio.mixed(backgroundLevel: 0.25)
```

A background level of 0 gives the isolated sound alone, and 1 gives the source.
The mix is `(1 - level) * buffer + level * source`,
so a player needs no background track.
Keep two tracks, the original and the isolated sound,
and set their volumes to `level` and `1 - level`,
for example with an `AVAudioMix`.

### Stereo input and a mono engine

Some engines take one channel.
When the input has more channels than the engine takes,
the isolator averages the channels, isolates the sound once,
and puts the result in every channel of the output.
The engine then does the same work for a stereo recording as for a mono one.
To isolate the sound in each channel separately instead,
pass options with the `perChannel` policy:

```swift
let options = IsolationOptions(channelPolicy: .perChannel)
try await isolator.isolate(contentsOf: interview, to: voices, options: options)
```

Use `perChannel` when the channels hold different sounds,
such as an interview with one speaker in each channel.
The engine's work grows with the number of channels.

With either policy, the output has the input's channel count,
and in each channel the isolated sound and the background add up to the source.
After a downmix, the isolated sound is the same in every channel,
so it has no stereo position,
and the background of a channel is that channel's source minus the isolated sound.
The background therefore keeps the differences between the channels,
and a mix at a background level of 1 is still the source.

The policy has no effect on an engine that takes all of the input's channels,
such as the system model with stereo input.
Every isolation method takes the same `options` parameter.

### Choose a model

Pass a model when you create the isolator.
A model that needs files installs them through an explicit request;
isolation never downloads:

```swift
let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: .standard))
guard isolator.isAvailable else { return }
if let request = try await isolator.assetInstallationRequest() {
    try await request.downloadAndInstall()
}
```

The system model needs no files, so its request is always `nil`.

With the `MLX` trait, `InworldSoundIsolationModel` isolates the voice in a recording.
Its request downloads one file of 256 MB and verifies it:

```swift
let isolator = SoundIsolator(model: InworldSoundIsolationModel())
if let request = try await isolator.assetInstallationRequest() {
    print("Downloading \(request.progress.totalUnitCount) bytes")
    try await request.downloadAndInstall()
}
try await isolator.isolate(contentsOf: recording, to: voice)
```

Without the file, isolation throws `SoundIsolationError.missingAssets`.
See [Inworld](#inworld) for what the model costs.

## Models

### System

`SystemSoundIsolationModel` uses the audio unit `kAudioUnitSubType_AUSoundIsolation`.
It needs no download and runs offline.

| | `.high` (default) | `.standard` |
| --- | --- | --- |
| Audio unit sound type | High-quality voice | Voice |
| Delay that the package removes, mono at 48 kHz | 4,440 frames (92.5 ms) | 2,705 frames (56.4 ms) |
| Delay that the package removes, stereo at 48 kHz | 6,360 frames (132.5 ms) | 3,665 frames (76.4 ms) |

The model processes audio in the format that it arrives in:

- **Sample rate.** The audio unit runs at the input's sample rate.
  The tests cover 8, 16, 44.1, 48, and 96 kHz.
- **Mono and stereo.** One or two channels go to the audio unit together.
  The unit processes two channels jointly:
  the left output depends on the right input,
  and a stereo file with two identical channels does not give the mono result.
- **More channels.** With three or more channels, the model takes one channel,
  so the [channel policy](#stereo-input-and-a-mono-engine) applies:
  by default the isolator averages the channels and isolates the voice once,
  and with `perChannel` each channel has its own audio unit.

A live stream receives each frame of output later than its input by the delay in the table,
because the audio unit needs that much audio after a frame to isolate it.

### Inworld

`InworldSoundIsolationModel` runs `voice-isolator-v1`,
the offline checkpoint of [Inworld's Voice Isolator](https://github.com/inworld-ai/voice-isolator),
in a Swift port for MLX.
The type exists only when the package is built with the `MLX` trait.
By ear, on one long voice recording, Inworld's model was much better than the system model.

**Output.** The port gives the output of Inworld's reference renders.
For Inworld's two golden fixtures, the largest error through this package's file API
was 4.2e-7 for 3 seconds of audio and 5.4e-7 for 11 seconds, on the GPU.
Inworld's own tolerance is 1e-4.

**Assets.** The model needs `denoiser.safetensors` (256,260,128 bytes), from
[`inworld/voice-isolator`](https://huggingface.co/inworld/voice-isolator) on Hugging Face.
`assetInstallationRequest()` downloads the file at a pinned revision,
checks its size and its SHA-256 digest, and records that it is verified.
The file goes into the Hugging Face cache, which other tools share:
`~/.cache/huggingface/hub`, or the directory that `HF_HUB_CACHE` or `HF_HOME` names.
A file that is already in the cache is verified and not downloaded again.
A sandboxed app keeps the file in its container,
in `Application Support/AnySoundIsolator/HuggingFace/hub`, which the package excludes from backups.
Besides the App Sandbox entitlement, the app needs only the one for outgoing network connections,
and it needs that one only for the download.
To supply the file yourself, create the model with `assets: .file(url)`;
the package then uses your file without a download and without a digest check.

**Format.** The network takes one channel at 48 kHz.
The isolator resamples other rates,
and the [channel policy](#stereo-input-and-a-mono-engine) applies to stereo input:
by default, a stereo recording costs the same as a mono one.

**Windows.** The network works in windows of 8 seconds that overlap by 2 seconds.
Inworld's offline render places the windows with the length of the clip known:
every window is a full one, and the last window ends at the end of the clip.
This package gives a stream the same frames, although a stream does not know its length.
It runs a window when the stream has its 8 seconds, returns the first 6,
and holds the 2-second crossfade until the next window or the end of the stream,
where it places the last window as Inworld does.
In our tests, a stream in pieces of several sizes, one buffer, and a file
gave the same samples for the same audio, with a difference of exactly 0.
What differs is when the frames arrive:
the first frames come after 8 seconds of input, then 6 seconds of output for each 6 seconds of input,
and the rest after the input ends.
This delay is too long for a conversation, so use the system model for live audio.

**Cost.** We measured release builds on an M4 Max with 36 GB of memory and macOS 27.0.1,
on 2026-11-20, with MLX Swift 0.33.0, after the first render of the process.

| Audio (48 kHz mono) | Time, file to file | Peak memory footprint |
| --- | --- | --- |
| 11 s | 1.17 to 1.21 s | 4.2 GB |
| 1 min | 5.79 to 5.84 s | 4.3 to 4.6 GB |
| 10 min | 58.6 to 59.6 s | 4.4 GB |

- The model isolates about 10 seconds of audio in each second.
  The first frames of a file arrive after about 0.6 s.
- Memory does not grow with the length of the audio, because the isolator works one window at a time.
  For one window, MLX had about 3.6 GB of GPU memory in use at its peak,
  in a measurement of the port before it came into this package.
  The weights are 256 MB, and they stay loaded while a stream is open.
- MLX keeps the GPU buffers that it frees, without a limit by default.
  While a stream is open, the package limits that cache to 512 MB, and it restores the earlier limit afterward.
  The limit is one setting for the process, so it applies to other MLX code in the app during that time.
  Without the limit, the footprint for one minute of audio was 5.5 GB, and the render was 3 percent faster.
- Streams that are open at the same time share the weights and render their windows in turn.

**The first render.** Metal compiles the network's GPU kernels the first time that an app uses them,
and keeps them in a cache for the app.
With an empty cache, the first render took about 2.4 s longer than later ones.
Later launches of the app read the cache and start at the steady speed.
The cache does not help a process that starts while another process of the same app is alive:
the first process holds the cache file, and the second compiles the kernels again.
A sandboxed app behaves the same as an app outside the sandbox in each of these cases.
To keep the compilation away from the user's first recording,
isolate a short silent buffer after the app starts:

```swift
let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
silence.frameLength = 4_800
_ = try await isolator.isolate(silence)
```

That call took 2.6 s with an empty cache and 0.05 s on later launches.

**Platforms.** The trait supports macOS on Apple silicon.
The library also compiles for iOS with the trait, but nobody has run it there,
and the memory for one window is more than iOS gives to most apps,
so do not rely on the model on iOS.

**Toolchain.** From the command line, the trait needs a SwiftPM that compiles MLX's Metal shaders;
we built it with Swift 6.4.2, and MLX Swift 0.31.6 and later need Swift 6.3.
Xcode also builds MLX Swift 0.31.4, which gave the same parity (4.2e-7 and 6.0e-7).
`mise run build:mlx` finds the Metal toolchain, which
`xcodebuild -downloadComponent MetalToolchain` installs.

**License.** Inworld publishes the code and the weights under the Apache License, Version 2.0.
`InworldSoundIsolationModel().attribution` has a line of attribution for an app to show.
See [NOTICE](NOTICE) for the parts of this package that are adapted from Inworld's code.

## Custom models

To add an engine, implement `SoundIsolationModel` for its configuration
and `SoundIsolationExecutor` for one stream.
The executor states its sample rate, its channel count, and its latency,
and returns audio when it has some.
The isolator does the rest:

- It resamples the input to the executor's sample rate, and the output back.
- When the executor takes one channel and the input has more,
  it gives the executor the average of the channels,
  or makes one executor for each channel, as the caller's `IsolationOptions` say.
- It removes the latency from the start of the output
  and pads or trims the end to the input's length.
- It reads and writes files, reports progress, and computes the background and the mix.

An executor can return any number of frames from a call, including none.
An engine that works in windows returns a window when it is complete,
and a hosted service can return everything from `finish()`.

This model halves the volume instead of isolating a sound:

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

A model that needs files reports them in `availability`
and returns a request from `assetInstallationRequest()`.
It throws `SoundIsolationError.missingAssets` from `makeExecutor(for:)`
instead of downloading.

## Command-line tool

The `silence` executable isolates the voice in a local file.
Its name says what it does: it silences everything except the sound that you want.

```console
$ swift run silence recording.m4a voice.wav
$ swift run silence isolate recording.m4a voice.m4a --background rest.m4a --quality standard
$ swift run silence status
```

With the `MLX` trait, `silence` also has the Inworld model.
`prepare` downloads and verifies its file, or only verifies a file that is already in the Hugging Face cache:

```console
$ swift run --traits MLX silence prepare --model inworld
$ swift run --traits MLX silence recording.m4a voice.wav --model inworld
$ swift run --traits MLX silence status --model inworld
```

`isolate` is the default subcommand.
`--background` also writes the sound that was removed.
`--channel-policy perChannel` isolates each channel separately
when the model takes fewer channels than the file has.
`prepare` installs the files that a model needs; isolation never downloads.
`status` reports whether the model can run and has its files, without downloading.
Run `swift run silence --help` for all options.

## Performance

We measured a release build of `silence` with the system model on an M4 Max with macOS 27.0,
on 10 minutes of 48 kHz audio made in code.
Both qualities took about the same time.

| Input | Time | Peak memory |
| --- | --- | --- |
| Mono | 6.6 to 6.9 s | 41 to 45 MB |
| Stereo | 14.2 to 15.1 s | 41 to 53 MB |

The Inworld model took about 59 s for 10 minutes of mono audio, with a footprint of 4.4 GB;
see [Inworld](#inworld).

## Limitations

- Nobody has listened to this package's output.
  The tests check length and timing with signals made in code,
  and they compare the Inworld model with Inworld's reference renders;
  they do not check sound quality.
- The Inworld model returns the first frames of a stream after 8 seconds of input.
  The package does not have Inworld's realtime checkpoint.
- The Inworld model is not run on iOS, on an Intel Mac, or with less than 36 GB of memory.
- At a sample rate that does not divide 48,000, such as 44.1 kHz,
  the audio unit's delay is not a whole number of frames,
  so the output can be off the input's timeline by less than one frame.
- With the standard quality, the measured delay of the isolated voice
  was one frame less than the delay that the audio unit reports.
- The package reads audio files, not video files.
  Extract a video's audio first.
- The package is not tested on a physical iPhone, on the OS 26 runtime,
  or with the minimum Swift 6.2 toolchain.

## Development

The repository uses [mise](https://mise.jdx.dev/) tasks.
Swift comes from the selected Xcode.
No task downloads a model unless its description says so.
The MLX tasks need Apple silicon and the Metal toolchain.

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

The examples in this file are also in
[`ReadmeExamples.swift`](Tests/AnySoundIsolatorTests/ReadmeExamples.swift),
so the tests fail to build when an example no longer compiles.
The examples of the Inworld model compile in the tests with the `MLX` trait.

## License

AnySoundIsolator is available under the Apache License, Version 2.0.
See [LICENSE](LICENSE) for details.
The Inworld model is adapted from Inworld's Voice Isolator, which has the same license;
see [NOTICE](NOTICE).
