import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import AnySoundIsolator

/// Tests of file input and output. Each test writes its own files from signals made in code.
@Suite struct FileTests {
    /// `AVAudioFile` can return fewer frames from one read than the caller asked for,
    /// so these lengths are not multiples of its internal block.
    @Test(arguments: [1, 47_700, 48_000, 48_300, 70_000])
    func fileReaderReturnsEveryFrame(count: Int) async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "audio.wav")
        let samples = (0 ..< count).map { Float($0 % 100) / 100 }
        try TestAudio.write([samples], to: url)

        #expect(try await TestAudio.read(url) == [samples])
    }

    /// A CAF or M4A file that is cut short states more audio than it holds.
    /// The isolator reports that as an error and writes no output.
    /// (`AVAudioFile` reports the shorter length of a WAV file that is cut short, so that file is not an error.)
    @Test(arguments: ["caf", "m4a"])
    func fileCutShortIsAnError(type: String) async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.\(type)")
        let file = try AudioFile.create(source, format: PCM.floatFormat(sampleRate: 48_000, channelCount: 1))
        try file.write(from: TestAudio.buffer([TestAudio.voice(seconds: 2)]))
        file.close()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(size / 2))
        try handle.close()

        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: source, to: directory.appending(path: "voice.wav"))
        } throws: { error in
            guard case SoundIsolationError.invalidAudio = error else { return false }
            return true
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.\(type)"])
    }

    @Test(arguments: ["wav", "caf"])
    func fileOutputMatchesTheContract(type: String) async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        let voice = directory.appending(path: "voice.\(type)")
        let background = directory.appending(path: "background.\(type)")
        let input = [TestAudio.voice(seconds: 2.5, seed: 1), TestAudio.voice(seconds: 2.5, seed: 2)]
        try TestAudio.write(input, to: source)

        let isolator = SoundIsolator(model: StandInModel(gain: 0.25, latency: 999, blockSize: 5_000))
        let progress = Progress()
        try await isolator.isolate(
            contentsOf: source,
            to: voice,
            background: background,
            options: IsolationOptions(channelPolicy: .perChannel),
            progress: progress
        )

        let isolated = try await TestAudio.read(voice)
        let removed = try await TestAudio.read(background)
        #expect(isolated == input.map { channel in channel.map { $0 * 0.25 } })
        for channel in 0 ..< 2 {
            let sum = zip(isolated[channel], removed[channel]).map { $0 + $1 }
            #expect(TestAudio.maximumDifference(sum, input[channel]) < 1e-6)
        }
        #expect(progress.totalUnitCount == 120_000)
        #expect(progress.completedUnitCount == 120_000)
    }

    @Test func systemModelIsolatesAFile() async throws {
        try #require(SystemSoundIsolationModel().isAvailable)
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.wav")
        let input = TestAudio.voice(seconds: 4, sampleRate: 16_000)
        try TestAudio.write([input], to: source, sampleRate: 16_000)

        let isolator = SoundIsolator()
        try await isolator.isolate(contentsOf: source, to: voice, background: background)

        let isolated = try await TestAudio.read(voice)[0]
        let removed = try await TestAudio.read(background)[0]
        #expect(isolated.count == input.count)
        #expect(abs(Alignment.lag(of: isolated, behind: input, maximumLag: 800)) <= 1)
        #expect(TestAudio.maximumDifference(zip(isolated, removed).map { $0 + $1 }, input) < 1e-6)

        // A file and a buffer of the same audio give the same samples, where the system's audio unit is repeatable.
        // Where it is not, a difference is a known issue; see `TestAudio.expectSameRender`.
        let whole = try await isolator.isolate(try TestAudio.buffer([input], sampleRate: 16_000))
        TestAudio.expectSameRender([isolated], TestAudio.channels(whole.buffer))
        let format = try AVAudioFile(forReading: voice).fileFormat
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
    }

    @Test func compressedOutputHasTheInputLength() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        let voice = directory.appending(path: "voice.m4a")
        let input = TestAudio.voice(seconds: 2)
        try TestAudio.write([input], to: source)

        try await SoundIsolator(model: StandInModel(gain: 1)).isolate(contentsOf: source, to: voice)

        let decoded = try await TestAudio.read(voice)[0]
        #expect(decoded.count == input.count)
        #expect(Alignment.lag(of: decoded, behind: input, maximumLag: 4_000) == 0)
    }

    @Test func compressedInputIsRead() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.m4a")
        let voice = directory.appending(path: "voice.wav")
        let input = TestAudio.voice(seconds: 2, sampleRate: 44_100)
        try TestAudio.write([input, input], to: source, sampleRate: 44_100)
        let decoded = try await TestAudio.read(source)

        try await SoundIsolator(model: StandInModel(gain: 1)).isolate(
            contentsOf: source,
            to: voice,
            options: IsolationOptions(channelPolicy: .perChannel)
        )

        #expect(try await TestAudio.read(voice) == decoded)
    }

    @Test func fourChannelFileKeepsItsChannels() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.caf")
        let voice = directory.appending(path: "voice.caf")
        let input = (1 ... 4).map { TestAudio.voice(seconds: 0.5, seed: UInt64($0)) }
        try TestAudio.write(input, to: source)

        let isolator = SoundIsolator(model: StandInModel(gain: 0.5))
        try await isolator.isolate(
            contentsOf: source,
            to: voice,
            options: IsolationOptions(channelPolicy: .perChannel)
        )
        #expect(try await TestAudio.read(voice) == input.map { channel in channel.map { $0 * 0.5 } })

        // By default, the four channels of the output hold the one result of the downmix.
        try await isolator.isolate(contentsOf: source, to: voice)
        let downmixed = try await TestAudio.read(voice)
        #expect(downmixed.count == 4)
        #expect(downmixed.allSatisfy { $0 == downmixed[0] })
        #expect(downmixed[0].count == input[0].count)
    }

    @Test func sourceIsNeverADestination() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        let samples = TestAudio.voice(seconds: 0.5)
        try TestAudio.write([samples], to: source)

        await #expect {
            try await SoundIsolator(model: StandInModel()).isolate(contentsOf: source, to: source)
        } throws: { error in
            guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
            return true
        }
        #expect(try await TestAudio.read(source) == [samples])
    }

    @Test func failureLeavesNoOutputFile() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        try TestAudio.write([TestAudio.voice(seconds: 0.5)], to: source)
        let isolator = SoundIsolator(model: StandInModel(), isolating: .init(rawValue: "music"))

        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.wav")
        await #expect(throws: SoundIsolationError.self) {
            try await isolator.isolate(contentsOf: source, to: voice, background: background)
        }
        #expect(try Self.names(in: directory) == ["source.wav"])

        // An output type that the isolator cannot write is an error before any work.
        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: source, to: directory.appending(path: "voice.mp3"))
        } throws: { error in
            guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
            return true
        }
        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: directory.appending(path: "missing.wav"), to: voice)
        } throws: { error in
            guard case SoundIsolationError.invalidAudio = error else { return false }
            return true
        }
        #expect(try Self.names(in: directory) == ["source.wav"])
    }

    // MARK: - Existing files at the destinations

    /// The names of everything in a directory, hidden files included, in order.
    private static func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// A directory with a source of two seconds and some text for a file that must not change.
    private static func workspace() throws -> (directory: URL, source: URL, text: Data) {
        let directory = try TestAudio.temporaryDirectory()
        let source = directory.appending(path: "source.wav")
        try TestAudio.write([TestAudio.voice(seconds: 2)], to: source)
        return (directory, source, Data("Notes that the isolator must keep.".utf8))
    }

    private static func isUnsupportedConfiguration(_ error: any Error) -> Bool {
        guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
        return true
    }

    @Test func refusedOutputKeepsAnExistingFile() async throws {
        let (directory, source, text) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appending(path: "notes.txt")
        try text.write(to: notes)

        await #expect(throws: SoundIsolationError.self) {
            try await SoundIsolator(model: StandInModel()).isolate(contentsOf: source, to: notes)
        }
        #expect(try Data(contentsOf: notes) == text)
        #expect(try Self.names(in: directory) == ["notes.txt", "source.wav"])
    }

    @Test func refusedOutputKeepsAnExistingBackground() async throws {
        let (directory, source, text) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let background = directory.appending(path: "background.wav")
        try text.write(to: background)

        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: source, to: directory.appending(path: "voice.mp3"), background: background)
        } throws: {
            Self.isUnsupportedConfiguration($0)
        }
        #expect(try Data(contentsOf: background) == text)
        #expect(try Self.names(in: directory) == ["background.wav", "source.wav"])

        // A refused background keeps an existing output in the same way.
        let voice = directory.appending(path: "voice.wav")
        try text.write(to: voice)
        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: source, to: voice, background: directory.appending(path: "background.txt"))
        } throws: {
            Self.isUnsupportedConfiguration($0)
        }
        #expect(try Data(contentsOf: voice) == text)
    }

    @Test(arguments: ["output", "output.wav"])
    func directoryAsOutputIsKept(name: String) async throws {
        let (directory, source, text) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let kept = output.appending(path: "kept.txt")
        try text.write(to: kept)
        let background = directory.appending(path: "background.wav")

        await #expect {
            try await SoundIsolator(model: StandInModel()).isolate(contentsOf: source, to: output)
        } throws: {
            Self.isUnsupportedConfiguration($0)
        }
        // A directory is kept as a background also, and the output is not started.
        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: source, to: background, background: output)
        } throws: {
            Self.isUnsupportedConfiguration($0)
        }
        #expect(try Data(contentsOf: kept) == text)
        #expect(try Self.names(in: directory) == [name, "source.wav"])
    }

    @Test func engineFailureAfterTheFirstWriteKeepsExistingFiles() async throws {
        let (directory, source, text) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.wav")
        try text.write(to: voice)
        try text.write(to: background)

        // The source has 96,000 frames in blocks of 32,768, so the third block fails
        // after the isolator wrote the first two. The temporary files exist at that time.
        let temporaryFiles = Mutex<[String]>([])
        let model = StandInModel(afterProcess: { frames in
            guard frames > 70_000 else { return }
            temporaryFiles.withLock { $0 = (try? Self.names(in: directory).filter { $0.hasPrefix(".") }) ?? [] }
            throw SoundIsolationError.backendFailure(underlying: CocoaError(.fileReadUnknown))
        })
        let progress = Progress()
        await #expect {
            try await SoundIsolator(model: model)
                .isolate(contentsOf: source, to: voice, background: background, progress: progress)
        } throws: { error in
            guard case SoundIsolationError.backendFailure = error else { return false }
            return true
        }
        #expect(progress.completedUnitCount > 0)
        #expect(temporaryFiles.withLock { $0.count } == 2)
        #expect(try Data(contentsOf: voice) == text)
        #expect(try Data(contentsOf: background) == text)
        #expect(try Self.names(in: directory) == ["background.wav", "source.wav", "voice.wav"])
    }

    @Test func cancellationKeepsExistingFiles() async throws {
        let (directory, source, text) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.wav")
        try text.write(to: voice)

        // The engine cancels the task that calls it, after the isolator wrote the first block.
        let model = StandInModel(afterProcess: { frames in
            if frames > 40_000 { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let progress = Progress()
        let task = Task {
            try await SoundIsolator(model: model)
                .isolate(contentsOf: source, to: voice, background: background, progress: progress)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(progress.completedUnitCount > 0)
        #expect(try Data(contentsOf: voice) == text)
        #expect(try Self.names(in: directory) == ["source.wav", "voice.wav"])
    }

    @Test func successReplacesExistingFiles() async throws {
        let (directory, source, text) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.caf")
        try text.write(to: voice)
        try text.write(to: background)

        try await SoundIsolator(model: StandInModel())
            .isolate(contentsOf: source, to: voice, background: background)
        let input = try await TestAudio.read(source)
        #expect(try await TestAudio.read(voice) == input.map { channel in channel.map { $0 * 0.5 } })
        #expect(try await TestAudio.read(background)[0].count == input[0].count)
        #expect(try Self.names(in: directory) == ["background.caf", "source.wav", "voice.wav"])
    }

    @Test func failedSecondMoveKeepsTheDestination() async throws {
        let (directory, source, text) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.wav")
        try text.write(to: background)

        // The destination becomes a directory during the work, so its move fails.
        // The background moves first, as the documentation says.
        let model = StandInModel(afterProcess: { _ in
            try? FileManager.default.createDirectory(at: voice, withIntermediateDirectories: false)
        })
        await #expect {
            try await SoundIsolator(model: model).isolate(contentsOf: source, to: voice, background: background)
        } throws: { error in
            guard case SoundIsolationError.backendFailure = error else { return false }
            return true
        }
        #expect(try Self.names(in: directory) == ["background.wav", "source.wav", "voice.wav"])
        #expect(try Self.names(in: voice).isEmpty)
        let input = try await TestAudio.read(source)
        #expect(try await TestAudio.read(background)[0].count == input[0].count)
    }

    @Test func linksToTheSourceAreNotDestinations() async throws {
        let (directory, source, _) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let hardLink = directory.appending(path: "hard.wav")
        let symbolicLink = directory.appending(path: "symbolic.wav")
        try FileManager.default.linkItem(at: source, to: hardLink)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)

        for link in [hardLink, symbolicLink] {
            await #expect {
                try await SoundIsolator(model: StandInModel()).isolate(contentsOf: source, to: link)
            } throws: {
                Self.isUnsupportedConfiguration($0)
            }
            await #expect {
                try await SoundIsolator(model: StandInModel())
                    .isolate(contentsOf: source, to: directory.appending(path: "voice.wav"), background: link)
            } throws: {
                Self.isUnsupportedConfiguration($0)
            }
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Self.names(in: directory) == ["hard.wav", "source.wav", "symbolic.wav"])
    }

    /// Two new names that the volume treats as one name are one destination,
    /// because the second move would replace the first.
    @Test func namesThatTheVolumeTreatsAsOneAreOneFile() async throws {
        let (directory, source, _) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ignoresCase =
            try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames == false
        // APFS and HFS+ treat names with one character in its composed and decomposed forms as one name.
        let pairs = [
            ("Voice.wav", "voice.wav", ignoresCase),
            ("caf\u{E9}.wav", "cafe\u{301}.wav", true),
        ]
        for (first, second, isOneFile) in pairs {
            let voice = directory.appending(path: first)
            let background = directory.appending(path: second)
            if isOneFile {
                await #expect {
                    try await SoundIsolator(model: StandInModel())
                        .isolate(contentsOf: source, to: voice, background: background)
                } throws: {
                    Self.isUnsupportedConfiguration($0)
                }
                #expect(try Self.names(in: directory) == ["source.wav"])
            } else {
                try await SoundIsolator(model: StandInModel())
                    .isolate(contentsOf: source, to: voice, background: background)
                #expect(try Self.names(in: directory).count == 3)
                try FileManager.default.removeItem(at: voice)
                try FileManager.default.removeItem(at: background)
            }
        }
    }

    /// The file iterator ends for good after an error or the end of the file,
    /// as `AsyncIteratorProtocol` requires.
    @Test func fileIteratorStaysFinished() async throws {
        let (directory, source, _) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        // After an error, the iterator does not try again, even when the file appears.
        let missing = directory.appending(path: "missing.wav")
        var failed = AudioFileBuffers(url: missing).makeAsyncIterator()
        await #expect {
            _ = try await failed.next()
        } throws: { error in
            guard case SoundIsolationError.invalidAudio = error else { return false }
            return true
        }
        try FileManager.default.copyItem(at: source, to: missing)
        #expect(try await failed.next() == nil)

        // After the end, a cancelled task gets `nil`, not `CancellationError`.
        let frames = try await Task {
            var iterator = AudioFileBuffers(url: source, blockSize: 40_000).makeAsyncIterator()
            var frames = 0
            while let input = try await iterator.next() {
                frames += Int(input.buffer.frameLength)
            }
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(try await iterator.next() == nil)
            return frames
        }.value
        #expect(frames == 96_000)

        // Cancellation is an error that ends the iteration too.
        let afterCancellation = try await Task {
            var iterator = AudioFileBuffers(url: source).makeAsyncIterator()
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { _ = try await iterator.next() }
            return try await iterator.next() == nil
        }.value
        #expect(afterCancellation)
    }

    /// A consumer on the main actor does not open or read the file there:
    /// the read waits for the iterator's queue, and the main actor is free in the meantime.
    @MainActor @Test func fileIteratorReadsOffTheConsumersActor() async throws {
        let (directory, source, _) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchSerialQueue(label: "AnySoundIsolatorTests.file")
        queue.suspend()
        var isSuspended = true
        defer { if isSuspended { queue.resume() } }

        let marks = CallMarks()
        let consumer = Task { @MainActor in
            var iterator = AudioFileBuffers.AsyncIterator(url: source, blockSize: 40_000, queue: queue)
            marks.hasStarted = true
            defer { marks.hasReturned = true }
            var frames: [AVAudioFrameCount] = []
            while let input = try await iterator.next() {
                frames.append(input.buffer.frameLength)
            }
            return frames
        }
        try await waitUntil("the consumer starts") { marks.hasStarted }
        #expect(!marks.hasReturned)
        queue.resume()
        isSuspended = false
        // A read can return fewer frames than the block size, so check the blocks and the total.
        let frames = try await consumer.value
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0 <= 40_000 })
        #expect(frames.reduce(0, +) == 96_000)
    }
}
