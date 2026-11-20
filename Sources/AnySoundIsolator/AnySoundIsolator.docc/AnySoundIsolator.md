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

Give the isolator a file with ``SoundIsolator/isolate(contentsOf:to:background:progress:)``,
one buffer with ``SoundIsolator/isolate(_:isolation:)``,
or a sequence of audio with ``SoundIsolator/streamIsolation(of:)``.
``SoundIsolator/streamIsolation(contentsOf:)`` reads a file
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

A model that needs files installs them through an ``AssetInstallationRequest``,
which ``SoundIsolator/assetInstallationRequest()`` returns.
Isolation never downloads.

## Topics

### Isolation

- ``SoundIsolator``
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
