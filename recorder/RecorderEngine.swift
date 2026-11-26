import Foundation
import AVFoundation
import ScreenCaptureKit

struct QualitySpec {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var capturesAudio: Bool
}

/// ScreenCaptureKit 录屏引擎：录某个显示器、排除指定窗口、写 H.264/AAC 的 .mov
final class RecorderEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var stopRequested = false

    var onStatus: ((String) -> Void)?
    var onFinished: ((Bool, String, URL?) -> Void)?

    func start(display: SCDisplay, excluding windows: [SCWindow], quality: QualitySpec, outputURL: URL) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: windows)

        let cfg = SCStreamConfiguration()
        cfg.width = quality.width
        cfg.height = quality.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true
        cfg.capturesAudio = quality.capturesAudio
        if quality.capturesAudio {
            cfg.sampleRate = 48000
            cfg.channelCount = 2
        }

        let w = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: cfg.width,
            AVVideoHeightKey: cfg.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else {
            throw NSError(domain: "RecorderEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 无法添加视频输入"])
        }
        w.add(v)

        self.writer = w
        self.videoInput = v
        self.audioInput = nil
        self.stopRequested = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cloak.recorder.samples"))
        self.stream = s
        try await s.startCapture()
        onStatus?("录制中")
    }

    func stop() {
        stopRequested = true
        stream?.stopCapture { [weak self] _ in
            self?.finishWriting()
        }
    }

    private func finishWriting() {
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer?.finishWriting { [weak self] in
            guard let self else { return }
            let url = self.writer?.outputURL
            let ok = self.writer?.status == .completed
            let msg = ok ? "完成" : (self.writer?.error?.localizedDescription ?? "写入失败")
            self.onFinished?(ok, msg, url)
        }
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, let writer, !stopRequested else { return }
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            onStatus?("开始写入")
        }
        guard writer.status == .writing else { return }

        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let mediaType = CMFormatDescriptionGetMediaType(desc)
        if mediaType == kCMMediaType_Video {
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        } else if mediaType == kCMMediaType_Audio {
            appendAudio(sampleBuffer)
        }
    }

    private func appendAudio(_ buf: CMSampleBuffer) {
        guard let writer else { return }
        if audioInput == nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audioInput = a
            }
        }
        if audioInput?.isReadyForMoreMediaData == true {
            audioInput?.append(buf)
        }
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopRequested else { return }
        if writer?.status == .writing { finishWriting() }
        else { onFinished?(false, error.localizedDescription, nil) }
    }

    // MARK: 拼接（续录）
    /// 把 `segment` 追加到 `existing` 之后，写入 `output`（无损 passthrough）。
    /// 两个片段的编码/尺寸需保持一致（续录时已按原片参数采集）。
    static func concatenate(existing: URL, segment: URL, to output: URL) async throws {
        let a = AVURLAsset(url: existing)
        let b = AVURLAsset(url: segment)
        let comp = AVMutableComposition()

        // 关键：整个合成全程只能分别有一条视频轨 + 一条音频轨，
        // 各段按时间顺序插入“同一条”轨（否则会变成并列的多条轨，导致黑屏）。
        var videoTrack: AVMutableCompositionTrack?
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for asset in [a, b] {
            let dur = try await asset.load(.duration)
            if let src = (try? await asset.loadTracks(withMediaType: .video))?.first {
                if videoTrack == nil {
                    videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let srcDur = (try? await src.load(.timeRange).duration) ?? dur
                try videoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: srcDur), of: src, at: cursor)
            }
            if let src = (try? await asset.loadTracks(withMediaType: .audio))?.first {
                if audioTrack == nil {
                    audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let srcDur = (try? await src.load(.timeRange).duration) ?? dur
                try audioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: srcDur), of: src, at: cursor)
            }
            cursor = CMTimeAdd(cursor, dur)
        }

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "RecorderEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建合并会话"])
        }
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(domain: "RecorderEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "合并失败"])
        }
    }
}