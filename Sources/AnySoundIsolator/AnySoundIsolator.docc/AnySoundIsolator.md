# ``AnySoundIsolator``

Isolate a sound, such as a voice, from a recording or a live stream, with a choice of engine.

## Overview

Create a ``SoundIsolator`` with a ``SoundIsolationModel``, which is the engine that does the work.
The default is ``SystemSoundIsolationModel``,
which uses the operating system's sound isolation audio unit and needs no download.

```swift
let isolator = SoundIsolator()
try await isolator.isolate(contentsOf: recording, to: voice)
```

Give the isolator a file with ``SoundIsolator/isolate(contentsOf:to:background:options:progress:)``,
one buffer with ``SoundIsolator/isolate(_:options:isolation:)``,
or a sequence of audio with ``SoundIsolator/streamIsolation(of:options:)``.
``SoundIsolator/streamIsolation(contentsOf:options:)`` reads a file
and returns results while the file is processed.

Every model gives output with the same properties.
The isolated sound has the input's sample rate, channel count, and number of frames,
and frame `n` of the output corresponds to frame `n` of the input.
The isolator removes an engine's delay and fixes the length of the output;
an engine only states its latency.

Because the output matches the input frame for frame,
the sound that was removed is the input minus the output.
``IsolatedAudio`` carries the matching input frames
and computes the background and a mix of the two.

When the input has more channels than the engine takes,
``IsolationOptions/channelPolicy`` selects what the isolator does.
By default it averages the channels, isolates the sound once,
and puts the result in every channel of the output,
so a mono engine does the same work for a stereo recording as for a mono one.
The background of each channel is still that channel's input minus the output.

A model that needs files installs them through an ``AssetInstallationRequest``,
which ``SoundIsolator/assetInstallationRequest()`` returns.
Isolation never downloads.

### The Inworld model

When you enable the package's `MLX` trait, the package also has `InworldSoundIsolationModel`,
which runs Inworld's Voice Isolator on the GPU with MLX.
Use it for recordings, where its quality is worth its cost:

```swift
let isolator = SoundIsolator(model: InworldSoundIsolationModel())
if let request = try await isolator.assetInstallationRequest() {
    try await request.downloadAndInstall()
}
try await isolator.isolate(contentsOf: recording, to: voice)
```

The request downloads one file of 256 MB into the Hugging Face cache and verifies it.
In a sandboxed app, the file goes into the app's container.
On an Apple M4 Max on 2026-11-20, the model isolated about 10 seconds of audio in each second,
with a peak memory footprint of 4.2 to 4.6 GB.
The network works in windows of 8 seconds,
so a stream receives its first frames after 8 seconds of input.
A stream and a file with the same audio give the same frames.

The trait supports macOS on Apple silicon.
The model compiles for iOS, but it is not run there,
and one window needs more memory than iOS gives to most apps.
This documentation shows the model's symbols only when it is built with the trait.

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

<!-- With the MLX trait, the package also has InworldSoundIsolationModel. -->

### Custom models

- ``SoundIsolationModel``
- ``SoundIsolationExecutor``
- ``SoundIsolationRequest``
- ``AudioSamples``

### Preparation and errors

- ``Availability``
- ``AssetInstallationRequest``
- ``SoundIsolationError``
