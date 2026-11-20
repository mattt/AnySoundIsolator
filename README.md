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

The package has one engine now:
Apple's sound isolation audio unit, which is part of the operating system.
The engine interface also fits models that download their weights and hosted services.

## Requirements

- Swift 6.2 or later
- macOS 26 or later, or iOS 26 or later

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/mattt/AnySoundIsolator", from: "0.1.0")
```

The library has no dependencies.

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
To stop, cancel the task; the isolator removes the files that it started.

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

The `hush` executable isolates the voice in a local file:

```console
$ swift run hush recording.m4a voice.wav
$ swift run hush isolate recording.m4a voice.m4a --background rest.m4a --quality standard
$ swift run hush status
```

`isolate` is the default subcommand.
`--background` also writes the sound that was removed.
`--channel-policy perChannel` isolates each channel separately
when the model takes fewer channels than the file has.
`status` reports whether the model can run, without downloading.
Run `swift run hush --help` for all options.

## Performance

We measured a release build of `hush` on an M4 Max with macOS 27.0,
on 10 minutes of 48 kHz audio made in code.
Both qualities took about the same time.

| Input | Time | Peak memory |
| --- | --- | --- |
| Mono | 6.6 to 6.9 s | 41 to 45 MB |
| Stereo | 14.2 to 15.1 s | 41 to 53 MB |

## Limitations

- Nobody has compared the engines by ear for this package.
  The tests check length and timing with signals made in code; they do not check sound quality.
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
No task downloads a model.

| Task | Description |
| --- | --- |
| `mise run setup` | Resolve package dependencies. |
| `mise run build` | Build the library and the `hush` command. |
| `mise run build:ios` | Compile the library for iOS. |
| `mise run test` | Run the tests, which make their own audio. |
| `mise run lint` | Check the formatting of the Swift sources. |
| `mise run format` | Format the Swift sources in place. |

The examples in this file are also in
[`ReadmeExamples.swift`](Tests/AnySoundIsolatorTests/ReadmeExamples.swift),
so the tests fail to build when an example no longer compiles.

## License

AnySoundIsolator is available under the Apache License, Version 2.0.
See [LICENSE](LICENSE) for details.
