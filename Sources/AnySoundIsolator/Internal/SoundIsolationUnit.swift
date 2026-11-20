import AVFoundation
import AudioToolbox

/// One instance of the system's sound isolation audio unit, driven through the Audio Unit C API.
///
/// The unit renders a block of output when asked and pulls the same number of input frames
/// through a callback, so the same code serves a whole file and a live stream.
/// Its output does not depend on the size of the blocks.
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
                guard
                    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &stream, streamSize)
                        == noErr
                else {
                    throw SoundIsolationError.unsupportedConfiguration(
                        "The sound isolation audio unit does not accept \(channelCount) channels at \(sampleRate) Hz."
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
            guard AudioUnitInitialize(unit) == noErr else {
                throw SoundIsolationError.unsupportedConfiguration(
                    "The sound isolation audio unit does not accept \(channelCount) channels at \(sampleRate) Hz."
                )
            }
            // The unit knows its latency after it is initialized with a format.
            var seconds: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            do {
                try Self.check(
                    AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
                )
            } catch {
                AudioUnitUninitialize(unit)
                throw error
            }
            self.latency = Int((seconds * sampleRate).rounded())
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit
        self.channelCount = channelCount
        self.feed = feed
        self.output = output
    }

    /// The queue that disposes of units.
    ///
    /// The unit's disposal waits for work that the unit put on a dispatch queue of its own.
    /// That work needs a thread. When every thread of Swift's cooperative pool waits in a disposal,
    /// such as at the end of many streams at a low priority, no thread remains, and the process stops.
    /// A disposal on this queue does not hold a thread of the pool.
    private static let disposal = DispatchQueue(label: "AnySoundIsolator.SoundIsolationUnit.disposal")

    deinit {
        nonisolated(unsafe) let unit = unit
        Self.disposal.async {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    /// Renders output frames while the unit reads the input.
    ///
    /// - Parameters:
    ///   - input: The next frames of the input. If it has fewer frames than `frameCount`,
    ///     the unit reads silence after them.
    ///   - frameCount: The number of frames to render.
    /// - Returns: The next `frameCount` frames of the unit's output.
    func render(_ input: AudioSamples, frameCount: Int) throws -> AudioSamples {
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
                var flags = AudioUnitRenderActionFlags()
                var timestamp = AudioTimeStamp()
                timestamp.mFlags = .sampleTimeValid
                timestamp.mSampleTime = sampleTime
                try Self.check(
                    AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(count), output.mutableAudioBufferList)
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
