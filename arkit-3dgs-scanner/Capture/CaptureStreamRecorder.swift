// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
//
//  CaptureStreamRecorder.swift
//  Append-only research capture stream. It deliberately owns copies of ARKit buffers;
//  ARFrame and ARKit-owned CVPixelBuffers never leave the session callback.

import Foundation
import AVFoundation
import CoreVideo

nonisolated struct CaptureStreamFrame: Codable, Sendable {
    var frameID: Int
    var timestamp: Double
    var videoPTS: Double?
    var videoFile: String?
    var videoWritten: Bool
    var dropReason: String?
    var intrinsics: CameraIntrinsics
    /// Row-major ARKit camera-to-world transform.
    var transform: [Double]
    var trackingState: String
    var depthFile: String?
    var confidenceFile: String?
    var depthWidth: Int?
    var depthHeight: Int?
    var exposureDuration: Double? = nil
    var exposureOffsetEV: Double? = nil
    /// Device readback; unlike exposureDuration, ISO is not an ARFrame property.
    var iso: Double? = nil
    var estimatedBlurPx: Double? = nil
}

nonisolated struct CaptureStreamPacket: @unchecked Sendable {
    var manifest: CaptureStreamFrame
    /// App-owned clone. nil means this frame is recorded as intentionally not written.
    var color: CVPixelBuffer?
    var depth: Data?
    var confidence: Data?
}

/// One actor serializes the movie, raw depth and jsonl manifest. Segment files avoid
/// reopening an AVAssetWriter (which is single-use) when a review scan is resumed.
actor CaptureStreamRecorder {
    enum RecorderError: LocalizedError {
        case closed, cannotStartWriter, cannotAddVideoInput, appendFailed, invalidPixelBuffer, noSamples
        case terminalFailure(String)
        var errorDescription: String? {
            switch self {
            case .closed: return "continuous capture recorder is closed"
            case .cannotStartWriter: return "unable to start continuous color movie writer"
            case .cannotAddVideoInput: return "unable to configure continuous color movie writer"
            case .appendFailed: return "unable to append continuous color frame"
            case .invalidPixelBuffer: return "continuous color buffer has invalid dimensions"
            case .noSamples: return "continuous color stream contains no written video samples"
            case .terminalFailure(let reason): return "continuous color stream finalization failed: \(reason)"
            }
        }
    }

    private let colorDirectory: URL
    private let depthDirectory: URL
    private let encoder: JSONEncoder
    private var manifestHandle: FileHandle?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var segmentStartTimestamp: Double?
    private var activeSegmentURL: URL?
    private var activeSegmentName: String?
    private var activeSegmentSamples = 0
    private var closed = false
    /// Once finalization has failed, subsequent finish/append calls must keep reporting the
    /// failure rather than returning already-written earlier segments as a successful package.
    private var terminalFailure: RecorderError?
    private var segmentFiles: [String] = []
    /// Test seam for deterministic AVAssetWriter readiness coverage. Production passes nil.
    private let writerReadyOverride: (@Sendable () -> Bool)?

    init(sessionDir: URL, writerReadyOverride: (@Sendable () -> Bool)? = nil) throws {
        colorDirectory = sessionDir
        depthDirectory = sessionDir.appendingPathComponent("depth/continuous", isDirectory: true)
        try FileManager.default.createDirectory(at: depthDirectory, withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("frames.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        manifestHandle = try FileHandle(forWritingTo: url)
        let json = JSONEncoder(); json.outputFormatting = [.sortedKeys]
        encoder = json
        self.writerReadyOverride = writerReadyOverride
    }

    func append(_ packet: CaptureStreamPacket) throws -> CaptureStreamFrame {
        if let terminalFailure { throw terminalFailure }
        guard !closed, let manifestHandle else { throw RecorderError.closed }
        var frame = packet.manifest
        if let color = packet.color {
            switch try appendColor(color, sourceTimestamp: frame.timestamp) {
            case .written(let pts):
                frame.videoWritten = true
                frame.videoPTS = pts
                frame.videoFile = segmentFiles.last
            case .backpressured:
                // Real-time AVAssetWriter backpressure is expected; preserve this ARFrame's
                // calibration/pose (and any depth) but state explicitly that no video sample
                // was accepted. This is not a terminal encoder failure.
                frame.dropReason = "writer_backpressure"
            }
        }
        if let depth = packet.depth {
            let name = String(format: "%08d.f32", frame.frameID)
            try depth.write(to: depthDirectory.appendingPathComponent(name), options: .atomic)
            frame.depthFile = "depth/continuous/" + name
        }
        if let confidence = packet.confidence {
            let name = String(format: "%08d.u8", frame.frameID)
            try confidence.write(to: depthDirectory.appendingPathComponent(name), options: .atomic)
            frame.confidenceFile = "depth/continuous/" + name
        }
        var line = try encoder.encode(frame)
        line.append(0x0A)
        try manifestHandle.write(contentsOf: line)
        return frame
    }

    /// Finish the active movie but retain the append-only manifest for resume.
    func finishSegment() async throws {
        guard let writer else { return }
        guard activeSegmentSamples > 0 else {
            discardActiveSegment()
            return
        }
        videoInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            let error = writer.error ?? RecorderError.appendFailed
            discardActiveSegment()
            closeTerminal(.terminalFailure(error.localizedDescription))
            throw error
        }
        resetActiveSegment()
    }

    func finish() async throws -> [String] {
        if closed {
            if let terminalFailure { throw terminalFailure }
            guard !segmentFiles.isEmpty else { throw RecorderError.noSamples }
            return segmentFiles
        }
        do {
            try await finishSegment()
        } catch {
            if terminalFailure == nil { closeTerminal(.terminalFailure(error.localizedDescription)) }
            throw error
        }
        guard !segmentFiles.isEmpty else {
            closeTerminal(.noSamples)
            throw RecorderError.noSamples
        }
        do {
            try closeManifest()
        } catch {
            closeTerminal(.terminalFailure(error.localizedDescription))
            throw error
        }
        return segmentFiles
    }

    func segments() -> [String] { segmentFiles }

    private enum AppendResult { case written(Double), backpressured }

    private func appendColor(_ pixelBuffer: CVPixelBuffer, sourceTimestamp: Double) throws -> AppendResult {
        if writer == nil { try startSegment(for: pixelBuffer) }
        guard let writer, let input = videoInput, let adaptor else {
            throw RecorderError.cannotStartWriter
        }
        guard writer.status == .writing else {
            let error = writer.error ?? RecorderError.appendFailed
            discardActiveSegment()
            closeTerminal(.terminalFailure(error.localizedDescription))
            throw error
        }
        guard input.isReadyForMoreMediaData && (writerReadyOverride?() ?? true) else { return .backpressured }
        // The writer session is zero-based. Do not use a backpressured frame as its source
        // origin: AVAssetWriter would fill that leading gap and create a MOV sample with no
        // matching manifest row. The first *accepted* ARFrame is always PTS zero.
        let seconds = activeSegmentSamples == 0 ? 0 : max(0, sourceTimestamp - (segmentStartTimestamp ?? sourceTimestamp))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            if writer.status == .writing { return .backpressured }
            let error = writer.error ?? RecorderError.appendFailed
            discardActiveSegment()
            closeTerminal(.terminalFailure(error.localizedDescription))
            throw error
        }
        if activeSegmentSamples == 0 {
            if let name = activeSegmentName { segmentFiles.append(name) }
            segmentStartTimestamp = sourceTimestamp
        }
        activeSegmentSamples += 1
        return .written(CMTimeGetSeconds(time))
    }

    private func startSegment(for pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { throw RecorderError.invalidPixelBuffer }
        let index = segmentFiles.count
        let name = index == 0 ? "color.mov" : String(format: "color-%04d.mov", index)
        let url = colorDirectory.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 5)]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.cannotAddVideoInput }
        writer.add(input)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                            sourcePixelBufferAttributes: attributes)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStartWriter }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; videoInput = input; self.adaptor = adaptor
        segmentStartTimestamp = nil
        activeSegmentURL = url
        activeSegmentName = name
        activeSegmentSamples = 0
    }

    private func resetActiveSegment() {
        writer = nil
        videoInput = nil
        adaptor = nil
        segmentStartTimestamp = nil
        activeSegmentURL = nil
        activeSegmentName = nil
        activeSegmentSamples = 0
    }

    /// An AVAssetWriter with no accepted samples cannot make a valid MOV. Remove it rather
    /// than exposing an empty segment as a completed continuous stream.
    private func discardActiveSegment() {
        writer?.cancelWriting()
        if let name = activeSegmentName, segmentFiles.last == name { segmentFiles.removeLast() }
        if let url = activeSegmentURL { try? FileManager.default.removeItem(at: url) }
        resetActiveSegment()
    }

    private func closeManifest() throws {
        let handle = manifestHandle
        manifestHandle = nil
        closed = true
        try handle?.close()
    }

    /// Closing flushes the append-only manifest for diagnosis while permanently preventing a
    /// caller from relabelling a terminal stream failure as successful.
    private func closeTerminal(_ failure: RecorderError) {
        terminalFailure = failure
        let handle = manifestHandle
        manifestHandle = nil
        closed = true
        try? handle?.close()
    }
}
