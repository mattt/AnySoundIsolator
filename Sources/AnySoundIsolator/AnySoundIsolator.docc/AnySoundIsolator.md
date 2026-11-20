# ``AnySoundIsolator``

Isolate a voice or other sound from recorded or live audio.

## Overview

Create a ``SoundIsolator`` with a ``SoundIsolationModel``.
The default ``SystemSoundIsolationModel`` uses Apple's sound isolation audio unit without a download.

```swift
let isolator = SoundIsolator()
try await isolator.isolate(contentsOf: recording, to: voice)
```

Use ``SoundIsolator/isolate(contentsOf:to:background:options:progress:)`` for files,
``SoundIsolator/isolate(_:options:isolation:)`` for one buffer,
or ``SoundIsolator/streamIsolation(of:options:)`` for a sequence of buffers.
For results as a file is processed, use ``SoundIsolator/streamIsolation(contentsOf:options:)``.

The isolator compensates for the latency each engine reports
and preserves the input's sample rate, channel count, and frame count.
Each ``IsolatedAudio`` holds the matching input frames
and computes each channel's background (input minus isolated sound) or a mix.

``IsolationOptions/channelPolicy`` applies
when the input has more channels than the engine accepts.
By default, the isolator averages the channels, runs a mono engine once
even for stereo input, and copies the result to every channel.

Install model files with the ``AssetInstallationRequest`` from
``SoundIsolator/assetInstallationRequest()``.
Isolation never downloads files.

### The Inworld model

For recordings, the `MLX` trait adds `InworldSoundIsolationModel`,
which runs Inworld's Voice Isolator on the GPU with MLX.

```swift
let isolator = SoundIsolator(model: InworldSoundIsolationModel())
if let request = try await isolator.assetInstallationRequest() {
    try await request.downloadAndInstall()
}
try await isolator.isolate(contentsOf: recording, to: voice)
```

The request downloads and verifies one 256 MB file in the Hugging Face cache.
In a sandboxed app, the file goes into the app's container.

On 2026-11-20, an Apple M4 Max processed about 10 seconds of audio per second.
Peak memory use was 4.2 to 4.6 GB.
The network works in windows of 8 seconds,
so a stream receives its first frames after 8 seconds of input.
File and stream input produce the same frames for the same audio.

The trait supports macOS on Apple silicon.
The model compiles for iOS, but it is not run there,
and one window needs more memory than iOS gives to most apps.
Only documentation built with the trait includes the model's symbols.

## Topics

### Isolation

- ``SoundIsolator``
- ``IsolationOptions``
- ``IsolatedAudio``
- ``IsolationStream``

### Input

- ``AudioInput``
- ``AudioFileBuffers``

### Models

- ``SystemSoundIsolationModel``

### Custom models

- ``SoundIsolationModel``
- ``SoundIsolationExecutor``
- ``SoundIsolationRequest``
- ``AudioSamples``

### Preparation and errors

- ``Availability``
- ``AssetInstallationRequest``
- ``SoundIsolationError``
