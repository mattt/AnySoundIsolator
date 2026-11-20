import AVFoundation
import AudioToolbox
import Synchronization

/// One instance of the system's sound isolation audio unit, driven through the Audio Unit C API.
///
/// The unit renders a block of output when asked and pulls the same number of input frames
/// through a callback, so the same code serves a whole file and a live stream.
/// On an Apple M4 Max with macOS 27, its output does not depend on the size of the blocks.
/// It does depend on the position of the stack at the render call,
/// so every render call is made from a fixed position.
/// With that, two units in one process gave the same output for the same samples on that Mac.
/// The package does not promise this on every machine:
/// on virtual machines with macOS 27, two renders of the same samples differed in some runs,
/// in most frames and with the same level, for a cause that is not known.
/// The output can also differ between builds of the package and between versions of the system.
/// The output trails the input by ``latency`` frames.
final class SoundIsolationUnit {
    /// The largest number of frames in one render call.
    private static let maximumFrames = 4096

    private static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// Whether the system has the audio unit.
    static var isInstalled: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    /// The frames by which the output trails the input, as the unit reports, rounded to a whole frame.
    let latency: Int

    /// The units of the process: those in use, and those that wait for their disposal or are in it.
    struct Census: Equatable {
        var inUse = 0
        var inDisposal = 0
    }

    /// The count of the units of the process, for diagnostics.
    static var census: Census { counts.withLock { $0 } }

    private static let counts = Mutex(Census())

    /// Waits until every unit that was released has been disposed of.
    ///
    /// This blocks the caller's thread. The diagnostic test uses it; the package does not.
    static func waitForDisposals() {
        disposal.sync {}
    }

    private let unit: AudioUnit
    private let channelCount: Int
    private let feed: Feed
    private let output: AVAudioPCMBuffer
    private var sampleTime: Float64 = 0

    /// The input for the render call in progress, which the render callback reads.
    private final class Feed {
        var channels: [UnsafePointer<Float>] = []
        var frameCount = 0
    }

    /// Creates and initializes a unit for a format.
    ///
    /// - Parameters:
    ///   - sampleRate: The sample rate of the input and the output.
    ///   - channelCount: The number of channels, 1 or 2.
    ///   - soundType: A value for `kAUSoundIsolationParam_SoundToIsolate`.
    ///   - wetDryMixPercent: A value for `kAUSoundIsolationParam_WetDryMixPercent`:
    ///     100 for the isolated sound alone, and 0 for the unprocessed input.
    init(sampleRate: Double, channelCount: Int, soundType: Int, wetDryMixPercent: Float) throws {
        let format = try PCM.floatFormat(sampleRate: sampleRate, channelCount: channelCount)
        var description = Self.componentDescription
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
            AudioComponentInstanceNew(component, &instance) == noErr,
            let unit = instance,
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.maximumFrames))
        else {
            throw SoundIsolationError.unavailableModel(
                "The sound isolation audio unit could not be created."
            )
        }
        let feed = Feed()
        do {
            var stream = format.streamDescription.pointee
            let streamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
                let status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &stream, streamSize)
                guard status == noErr else {
                    throw SoundIsolationError.unsupportedConfiguration(
                        "The sound isolation audio unit does not accept \(channelCount) channels "
                            + "at \(sampleRate) Hz (stream format, status \(status))."
                    )
                }
            }
            var maximumFrames = UInt32(Self.maximumFrames)
            try Self.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0,
                    &maximumFrames,
                    UInt32(MemoryLayout<UInt32>.size)
                )
            )
            var callback = AURenderCallbackStruct(
                inputProc: Self.renderInput,
                inputProcRefCon: Unmanaged.passUnretained(feed).toOpaque()
            )
            try Self.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                )
            )
            try Self.check(
                AudioUnitSetParameter(
                    unit,
                    AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                    kAudioUnitScope_Global,
                    0,
                    wetDryMixPercent,
                    0
                )
            )
            try Self.check(
                AudioUnitSetParameter(
                    unit,
                    AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
                    kAudioUnitScope_Global,
                    0,
                    AudioUnitParameterValue(soundType),
                    0
                )
            )
            try Self.start(sampleRate: sampleRate, channelCount: channelCount) {
                AudioUnitInitialize(unit)
            }
            // The unit knows its latency after it is initialized with a format.
            var seconds: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            try Self.check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
            )
            self.latency = Int((seconds * sampleRate).rounded())
        } catch {
            Self.dispose(unit)
            throw error
        }
        self.unit = unit
        self.channelCount = channelCount
        self.feed = feed
        self.output = output
        Self.counts.withLock { $0.inUse += 1 }
    }

    /// Initializes a unit with a closure that calls `AudioUnitInitialize`.
    ///
    /// The unit can fail to start with `kAudioUnitErr_FailedInitialization` for a format that it supports.
    /// On a virtual machine with macOS 27, this occurred for two channels at 48 kHz with high quality.
    /// In one CI run, three units failed in this way after three calls each,
    /// so a second call does not help, and the method makes one.
    /// The cause is unknown.
    ///
    /// - Throws: ``SoundIsolationError/unsupportedConfiguration(_:)`` when the unit refuses the format,
    ///   or ``SoundIsolationError/backendFailure(underlying:)`` with the status
    ///   when the unit fails to start for a format that it accepts.
    static func start(sampleRate: Double, channelCount: Int, _ initialize: () -> OSStatus) throws {
        let status = initialize()
        guard status != noErr else { return }
        // The messages name the step and the status,
        // so that a refused format and a unit that failed to start are different in a report.
        guard status == kAudioUnitErr_FailedInitialization else {
            throw SoundIsolationError.unsupportedConfiguration(
                "The sound isolation audio unit does not accept \(channelCount) channels "
                    + "at \(sampleRate) Hz (initialization, status \(status))."
            )
        }
        throw SoundIsolationError.backendFailure(
            underlying: NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The sound isolation audio unit failed to start "
                        + "for \(channelCount) channels at \(sampleRate) Hz (status \(status))."
                ]
            )
        )
    }

    /// The queue that disposes of units.
    ///
    /// The unit's disposal waits for work that the unit put on a dispatch queue of its own.
    /// That work needs a thread. When every thread of Swift's cooperative pool waits in a disposal,
    /// such as at the end of many streams at a low priority, no thread remains, and the process stops.
    /// A disposal on this queue does not hold a thread of the pool.
    private static let disposal = DispatchQueue(label: "AnySoundIsolator.SoundIsolationUnit.disposal")

    deinit {
        Self.counts.withLock { $0.inUse -= 1 }
        Self.dispose(unit)
    }

    /// Uninitializes and disposes of a unit on the disposal queue.
    ///
    /// The initializer also disposes of a unit that it could not set up in this way.
    private static func dispose(_ unit: AudioUnit) {
        nonisolated(unsafe) let unit = unit
        counts.withLock { $0.inDisposal += 1 }
        disposal.async {
            // The unit may not be initialized, so the status of this call does not matter.
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            counts.withLock { $0.inDisposal -= 1 }
        }
    }

    /// Renders output frames while the unit reads the input.
    ///
    /// - Parameters:
    ///   - input: The next frames of the input. If it has fewer frames than `frameCount`,
    ///     the unit reads silence after them.
    ///   - frameCount: The number of frames to render.
    /// - Returns: The next `frameCount` frames of the unit's output.
    /// - Throws: ``SoundIsolationError/invalidAudio(_:)`` when the input does not have the unit's channel count
    ///   or its channels have different lengths, before the unit reads it.
    func render(_ input: AudioSamples, frameCount: Int) throws -> AudioSamples {
        // The render callback copies the same number of frames from each channel,
        // so a short channel would be read past its end.
        // `AudioSamples.channels` is a public property, so its lengths can differ.
        guard input.channelCount == channelCount else {
            throw SoundIsolationError.invalidAudio(
                "The system executor takes \(channelCount) channels, and the input has \(input.channelCount)."
            )
        }
        guard input.hasEqualChannelLengths else {
            throw SoundIsolationError.invalidAudio(
                "The input has channels with \(input.channels.map(\.count)) samples, which are not equal."
            )
        }
        var result = AudioSamples(channelCount: channelCount)
        for index in result.channels.indices {
            result.channels[index].reserveCapacity(frameCount)
        }
        var rendered = 0
        while rendered < frameCount {
            let count = min(Self.maximumFrames, frameCount - rendered)
            let available = max(0, min(count, input.frameCount - rendered))
            try withPointers(to: input.channels, offset: rendered) { pointers in
                feed.channels = pointers
                feed.frameCount = available
                defer {
                    feed.channels = []
                    feed.frameCount = 0
                }
                output.frameLength = AVAudioFrameCount(count)
                try Self.check(
                    Self.renderAtFixedStackAlignment(
                        unit,
                        sampleTime: sampleTime,
                        frameCount: UInt32(count),
                        into: output.mutableAudioBufferList
                    )
                )
            }
            // The unit can point the buffer list at its own memory, so read through the list.
            let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            for channel in 0 ..< channelCount {
                guard let data = buffers[channel].mData else {
                    throw SoundIsolationError.invalidResult("The sound isolation audio unit returned no audio.")
                }
                result.channels[channel].append(
                    contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
                )
            }
            sampleTime += Float64(count)
            rendered += count
        }
        return result
    }

    /// Calls `AudioUnitRender` from a fixed position of the stack within 64 bytes.
    ///
    /// Apple has a report of the dependence that follows, with the number FB25659939.
    ///
    /// The unit's output depends on that position.
    /// On macOS 27 with an Apple M4 Max, the same samples gave three different outputs,
    /// one for each of three positions of the stack modulo 64 bytes at this call.
    /// One second of a voice at a level of 0.11 differed in 9 of 10 frames, by as much as 0.012.
    /// The position depends on the caller: on the functions between it and this call, on the thread,
    /// and on whether the Swift runtime resumes a task inline or as a new job.
    /// So two streams of the same samples could differ, and which of them differed was not repeatable.
    ///
    /// The method measures where a stack allocation is, and makes a second allocation
    /// that is larger by that offset, so the second one starts at the same position each time.
    /// The frames between it and `AudioUnitRender` have a fixed size in one build,
    /// so every render in a process calls the unit from the same position.
    /// The timestamp and the flags of the call are in that allocation.
    ///
    /// This relies on `withUnsafeTemporaryAllocation` using the stack, as it does for a size this small.
    /// If it used the heap, the call would be as it was before: correct, and not repeatable.
    @inline(never)
    private static func renderAtFixedStackAlignment(
        _ unit: AudioUnit,
        sampleTime: Float64,
        frameCount: UInt32,
        into buffers: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        // Find where a stack allocation is now, within 64 bytes.
        let offset = withUnsafeTemporaryAllocation(byteCount: 16, alignment: 16) { probe in
            Int(UInt(bitPattern: probe.baseAddress) % 64)
        }
        // The stack grows down, so an allocation that is larger by that offset
        // starts at the same position within 64 bytes each time.
        // The arguments of the call are in the allocation, so the compiler cannot remove it.
        let flagsOffset = MemoryLayout<AudioTimeStamp>.stride
        let byteCount = flagsOffset + MemoryLayout<AudioUnitRenderActionFlags>.stride
        return withUnsafeTemporaryAllocation(byteCount: (byteCount + 15) / 16 * 16 + offset, alignment: 16) { anchor in
            guard let base = anchor.baseAddress else { return kAudio_MemFullError }
            let timestamp = base.bindMemory(to: AudioTimeStamp.self, capacity: 1)
            let flags = (base + flagsOffset).bindMemory(to: AudioUnitRenderActionFlags.self, capacity: 1)
            timestamp.initialize(to: AudioTimeStamp())
            timestamp.pointee.mFlags = .sampleTimeValid
            timestamp.pointee.mSampleTime = sampleTime
            flags.initialize(to: [])
            return AudioUnitRender(unit, flags, timestamp, 0, frameCount, buffers)
        }
    }

    /// Calls a closure with a pointer into each channel, starting at an offset.
    private func withPointers<Result>(
        to channels: [[Float]],
        offset: Int,
        index: Int = 0,
        pointers: [UnsafePointer<Float>] = [],
        _ body: ([UnsafePointer<Float>]) throws -> Result
    ) throws -> Result {
        guard index < channels.count else { return try body(pointers) }
        return try channels[index].withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, offset < buffer.count else {
                // No input remains; the callback supplies silence.
                return try body([])
            }
            return try withPointers(
                to: channels,
                offset: offset,
                index: index + 1,
                pointers: pointers + [base + offset],
                body
            )
        }
    }

    /// Supplies the unit's input: the frames of the current render call, then silence.
    private static let renderInput: AURenderCallback = { context, _, _, _, frameCount, data in
        guard let data else { return kAudio_ParamError }
        let feed = Unmanaged<Feed>.fromOpaque(context).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        let requested = Int(frameCount)
        for (channel, buffer) in buffers.enumerated() {
            guard let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            let supplied = channel < feed.channels.count ? min(requested, feed.frameCount) : 0
            if supplied > 0 {
                destination.update(from: feed.channels[channel], count: supplied)
            }
            if supplied < requested {
                (destination + supplied).update(repeating: 0, count: requested - supplied)
            }
        }
        // A second pull in the same render call gets silence, not the same frames again.
        if !feed.channels.isEmpty {
            feed.channels = feed.channels.map { $0 + min(requested, feed.frameCount) }
            feed.frameCount -= min(requested, feed.frameCount)
        }
        return noErr
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw SoundIsolationError.backendFailure(
                underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            )
        }
    }
}
