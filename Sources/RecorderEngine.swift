import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import AudioToolbox

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case noDisplay
    case noWindow
    case writerCouldNotStart
    case noSamples
    case captureFailed(String)
    case writerFailed(String)
    case outputFileInvalid

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "すでに録画中、または録画処理中です。"
        case .notRecording:
            return "録画は開始されていません。"
        case .noDisplay:
            return "録画できるディスプレイが見つかりませんでした。"
        case .noWindow:
            return "録画できるウィンドウが見つかりませんでした。"
        case .writerCouldNotStart:
            return "動画ファイルの作成を開始できませんでした。"
        case .noSamples:
            return "映像データを取得できませんでした。画面収録の権限を確認してください。"
        case .captureFailed(let message):
            return "画面収録でエラーが発生しました。\n\(message)"
        case .writerFailed(let message):
            return "動画ファイルの保存に失敗しました。\n\(message)"
        case .outputFileInvalid:
            return "録画終了後の動画ファイルを正常に確定できませんでした。"
        }
    }
}

enum CaptureTarget {
    case display(SCDisplay)
    // ウィンドウ指定では単一SCWindowを直接キャプチャしない。
    // 対象ウィンドウが表示されているディスプレイの実画面を取得し、
    // そのウィンドウ矩形をsourceRectで切り出す。
    // これにより、別Windowとして描画されるプルダウン／ポップアップも
    // 対象矩形内に表示されている限り映像へ含められる。
    case window(
        display: SCDisplay,
        sourceRect: CGRect,
        excludingApplications: [SCRunningApplication]
    )
    case region(display: SCDisplay, sourceRect: CGRect)
}

final class RecorderEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private enum State: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    private let captureQueue = DispatchQueue(label: "app.local.MacScreenAudioRecorder.capture", qos: .userInitiated)
    private let stateLock = NSLock()

    private var state: State = .idle
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?

    private var sessionStarted = false
    private var sessionStartTime: CMTime = .invalid
    private var sawVideoSample = false
    private var sawAudioSample = false
    private var appendFailureMessage: String?
    private var finalizationStarted = false

    // macOSの画面共有UIからユーザー自身が停止した場合は正常な停止操作としてUIへ返す。
    var onUserStopped: ((Result<URL, Error>) -> Void)?

    // ScreenCaptureKitがユーザー操作以外で停止した場合も、壊れたMOVを残さず
    // 可能ならAVAssetWriterを正常終了させ、その結果をUIへ返す。
    var onUnexpectedStop: ((Result<URL, Error>) -> Void)?

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func currentState() -> State {
        withStateLock { state }
    }

    private func setState(_ newState: State) {
        withStateLock { state = newState }
    }

    var isRecording: Bool {
        let value = currentState()
        return value == .recording || value == .stopping
    }

    var isStopping: Bool {
        currentState() == .stopping
    }

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func getShareableContent(
        onScreenWindowsOnly: Bool = true,
        completion: @escaping (Result<SCShareableContent, Error>) -> Void
    ) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly) { content, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(RecorderError.captureFailed(error.localizedDescription)))
                } else if let content {
                    completion(.success(content))
                } else {
                    completion(.failure(RecorderError.noDisplay))
                }
            }
        }
    }

    func mainDisplay(from content: SCShareableContent) -> SCDisplay? {
        let mainDisplayID = CGMainDisplayID()
        return content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first
    }

    func startRecording(to url: URL, target: CaptureTarget, completion: @escaping (Result<Void, Error>) -> Void) {
        let canStart = withStateLock { () -> Bool in
            guard state == .idle else { return false }
            state = .starting
            return true
        }
        guard canStart else {
            completion(.failure(RecorderError.alreadyRecording))
            return
        }

        outputURL = url
        sessionStarted = false
        sessionStartTime = .invalid
        sawVideoSample = false
        sawAudioSample = false
        appendFailureMessage = nil
        finalizationStarted = false

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            try configureAndStart(target: target, outputURL: url, completion: completion)
        } catch {
            cleanup(deletePartialFile: true)
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }

    private func configureAndStart(
        target captureTarget: CaptureTarget,
        outputURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        let filter: SCContentFilter
        var sourceRect: CGRect?
        var logicalWidth: CGFloat
        var logicalHeight: CGFloat

        switch captureTarget {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            logicalWidth = CGFloat(display.width)
            logicalHeight = CGFloat(display.height)

        case .window(let display, let rect, let excludingApplications):
            // 単一ウィンドウのSCWindowキャプチャでは、macOSが別Windowとして
            // 描画するプルダウンやポップアップが含まれない場合がある。
            // そこでディスプレイの実表示をキャプチャ元にし、対象ウィンドウの
            // 矩形だけをsourceRectで切り出す。
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludingApplications,
                exceptingWindows: []
            )
            sourceRect = rect.standardized
            logicalWidth = max(rect.width, 2)
            logicalHeight = max(rect.height, 2)

        case .region(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: [])
            sourceRect = rect.standardized
            logicalWidth = max(rect.width, 2)
            logicalHeight = max(rect.height, 2)
        }

        let pointScale = max(CGFloat(filter.pointPixelScale), 1.0)
        let target = targetSize(
            sourceWidth: Int((logicalWidth * pointScale).rounded()),
            sourceHeight: Int((logicalHeight * pointScale).rounded())
        )

        let configuration = SCStreamConfiguration()
        configuration.width = target.width
        configuration.height = target.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.scalesToFit = true

        if let sourceRect {
            configuration.sourceRect = sourceRect
        }

        // v0.1でCubase録音に成功したシステム音声取得経路は変更しない。
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let newWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let pixels = target.width * target.height
        let videoBitRate: Int
        if pixels >= 7_000_000 {
            videoBitRate = 24_000_000
        } else if pixels >= 3_000_000 {
            videoBitRate = 16_000_000
        } else {
            videoBitRate = 10_000_000
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: target.width,
            AVVideoHeightKey: target.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        newVideoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000
        ]

        let newAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        newAudioInput.expectsMediaDataInRealTime = true

        guard newWriter.canAdd(newVideoInput), newWriter.canAdd(newAudioInput) else {
            throw RecorderError.writerCouldNotStart
        }

        newWriter.add(newVideoInput)
        newWriter.add(newAudioInput)

        guard newWriter.startWriting() else {
            throw RecorderError.writerFailed(newWriter.error?.localizedDescription ?? "AVAssetWriter.startWriting() が失敗しました。")
        }

        writer = newWriter
        videoInput = newVideoInput
        audioInput = newAudioInput

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        stream = newStream

        newStream.startCapture { [weak self] error in
            guard let self else { return }
            if let error {
                self.cleanup(deletePartialFile: true)
                DispatchQueue.main.async {
                    completion(.failure(RecorderError.captureFailed(error.localizedDescription)))
                }
                return
            }

            self.setState(.recording)
            DispatchQueue.main.async {
                completion(.success(()))
            }
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        let streamToStop: SCStream? = withStateLock {
            guard state == .recording else { return nil }
            state = .stopping
            return stream
        }

        guard let streamToStop else {
            completion(.failure(RecorderError.notRecording))
            return
        }

        // stopCaptureの完了後、同じcaptureQueueにfinalize処理を積む。
        // これにより既にqueueへ届いていた最後の画面/音声サンプルを処理し終えてから
        // AVAssetWriterInputをFinishedにできる。
        streamToStop.stopCapture { [weak self] stopError in
            guard let self else { return }
            self.captureQueue.async {
                self.finalizeRecording(stopError: stopError, completion: completion)
            }
        }
    }

    private func finalizeRecording(
        stopError: Error?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !finalizationStarted else { return }
        finalizationStarted = true

        guard sessionStarted, sawVideoSample else {
            writer?.cancelWriting()
            cleanup(deletePartialFile: true)
            DispatchQueue.main.async {
                completion(.failure(RecorderError.noSamples))
            }
            return
        }

        guard let writer, let outputURL else {
            cleanup(deletePartialFile: true)
            DispatchQueue.main.async {
                completion(.failure(RecorderError.writerCouldNotStart))
            }
            return
        }

        if writer.status == .failed || writer.status == .cancelled {
            let message = appendFailureMessage
                ?? writer.error?.localizedDescription
                ?? stopError?.localizedDescription
                ?? "AVAssetWriterが録画中に停止しました。"
            cleanup(deletePartialFile: true)
            DispatchQueue.main.async {
                completion(.failure(RecorderError.writerFailed(message)))
            }
            return
        }

        // endSession(atSourceTime:) は使わない。
        // 音声と映像の最後のPTSが一致しない場合や短時間録画でゼロ長になる可能性を避け、
        // 入力を最後まで受け切った後にmarkAsFinished → finishWritingでコンテナを確定する。
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let self else { return }

            let writerError = writer.error
            let appendError = self.appendFailureMessage
            let success = writer.status == .completed && self.validateOutputFile(outputURL)

            self.cleanup(deletePartialFile: !success)

            DispatchQueue.main.async {
                if success {
                    completion(.success(outputURL))
                } else if let writerError {
                    completion(.failure(RecorderError.writerFailed(writerError.localizedDescription)))
                } else if let appendError {
                    completion(.failure(RecorderError.writerFailed(appendError)))
                } else if let stopError {
                    completion(.failure(RecorderError.captureFailed(stopError.localizedDescription)))
                } else {
                    completion(.failure(RecorderError.outputFileInvalid))
                }
            }
        }
    }

    private func validateOutputFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 1024 else {
            return false
        }
        return true
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // アプリのSTOPを押した場合はstateが.stoppingなので、stopRecording側だけが確定処理する。
        // macOSの共有停止ボタンはSCStreamErrorUserStopped (-3817) としてここへ届くため、
        // それは「予期せぬ終了」ではなくユーザーによる正常な停止操作として扱う。
        let userStopped = isUserStoppedError(error)
        let shouldRecover = withStateLock { () -> Bool in
            if state == .recording {
                state = .stopping
                return true
            }
            if state == .starting {
                state = .idle
            }
            return false
        }

        guard shouldRecover else { return }

        captureQueue.async { [weak self] in
            guard let self else { return }
            self.finalizeRecording(stopError: userStopped ? nil : error) { [weak self] result in
                guard let self else { return }
                if userStopped {
                    self.onUserStopped?(result)
                } else {
                    self.onUnexpectedStop?(result)
                }
            }
        }
    }

    private func isUserStoppedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == -3817
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer, writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        switch type {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

            // 映像の最初のフレームを録画セッションの基準時刻にする。
            // 音声だけ先に来た場合は映像開始前の音声を捨てることでMOVの先頭を安定させる。
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStartTime = pts
                sessionStarted = true
            }

            guard !sessionStartTime.isValid || CMTimeCompare(pts, sessionStartTime) >= 0 else { return }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                if videoInput.append(sampleBuffer) {
                    sawVideoSample = true
                } else if appendFailureMessage == nil {
                    appendFailureMessage = writer.error?.localizedDescription ?? "映像サンプルの書き込みに失敗しました。"
                }
            }

        case .audio:
            guard sessionStarted else { return }
            guard !sessionStartTime.isValid || CMTimeCompare(pts, sessionStartTime) >= 0 else { return }
            if let audioInput, audioInput.isReadyForMoreMediaData {
                if audioInput.append(sampleBuffer) {
                    sawAudioSample = true
                } else if appendFailureMessage == nil {
                    appendFailureMessage = writer.error?.localizedDescription ?? "音声サンプルの書き込みに失敗しました。"
                }
            }

        default:
            break
        }
    }

    private func cleanup(deletePartialFile: Bool) {
        let url = outputURL
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        sessionStarted = false
        sessionStartTime = .invalid
        sawVideoSample = false
        sawAudioSample = false
        appendFailureMessage = nil
        finalizationStarted = false
        setState(.idle)

        if deletePartialFile, let url, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func targetSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let maxWidth = 3840.0
        let maxHeight = 2160.0
        let width = Double(max(sourceWidth, 2))
        let height = Double(max(sourceHeight, 2))
        let scale = min(1.0, min(maxWidth / width, maxHeight / height))

        var outWidth = Int((width * scale).rounded(.down))
        var outHeight = Int((height * scale).rounded(.down))

        outWidth = max(2, outWidth - (outWidth % 2))
        outHeight = max(2, outHeight - (outHeight % 2))
        return (outWidth, outHeight)
    }
}
