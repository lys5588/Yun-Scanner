// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import AVFoundation
import CoreVideo
import simd

/// Bounded, post-recording JPEG encoding. Every accepted MOV sample must match exactly
/// one manifest row. No nominal-FPS resampling, preferredTransform, crop or interpolation.
nonisolated enum CaptureVideoFrames {
    enum Failure: Error { case invalid(String) }

    private static func file(_ path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw Failure.invalid("unsafe capture media path")
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.invalid("symbolic link") }
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.invalid("missing capture media") }
        return url
    }

    static func append(directory: URL, writer: FrameWriter,
                       progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws -> Int {
        let worker = Task.detached(priority: .userInitiated) {
            try await extract(directory: directory, writer: writer, progress: progress)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func extract(directory: URL, writer: FrameWriter,
                                progress: @Sendable (Double) -> Void) async throws -> Int {
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: file("frames.jsonl", in: directory))
        let all = try data.split(separator: 10).map { try decoder.decode(CaptureStreamFrame.self, from: Data($0)) }
        guard Set(all.map(\.frameID)).count == all.count,
              zip(all, all.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else { throw Failure.invalid("invalid continuous frame order") }
        let frames = all.filter(\.videoWritten)
        guard !frames.isEmpty, frames.allSatisfy({ $0.dropReason == nil && $0.videoFile != nil && $0.videoPTS?.isFinite == true }) else {
            throw Failure.invalid("invalid accepted video index")
        }
        let existing = await writer.snapshotRecords()
        guard existing.count <= frames.count else { throw Failure.invalid("unexpected existing JPEGs") }
        for (row, frame) in zip(existing, frames) {
            guard row.sourceFrameID == frame.frameID, row.timestamp == frame.timestamp,
                  row.transform == frame.transform, row.imageSource == "decoded_recorded_video_native_pixels" else {
                throw Failure.invalid("cannot append full frames to a keyframe collection")
            }
            _ = try file("images/" + row.imageFile, in: directory)
        }
        var segments: [String] = []
        for frame in frames where segments.last != frame.videoFile {
            guard !segments.contains(frame.videoFile!) else { throw Failure.invalid("non-contiguous movie segment") }
            segments.append(frame.videoFile!)
        }
        var completed = 0
        for segment in segments {
            try Task.checkCancellation()
            let expected = frames.filter { $0.videoFile == segment }
            let asset = AVURLAsset(url: try file(segment, in: directory))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.invalid("missing video track") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.invalid("cannot decode capture video") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure.invalid("cannot start video reader") }
            defer { reader.cancelReading() }
            var index = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                guard index < expected.count, let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure.invalid("unexpected decoded video sample") }
                let frame = expected[index]
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                // Legacy manifests stored unrounded seconds; MOV was written at timescale 600.
                guard pts.isFinite, abs(pts - frame.videoPTS!) <= 0.5 / 600 + 1e-7,
                      CVPixelBufferGetWidth(buffer) == frame.intrinsics.width,
                      CVPixelBufferGetHeight(buffer) == frame.intrinsics.height else { throw Failure.invalid("video/ARFrame timestamp or dimensions mismatch") }
                if completed >= existing.count {
                    let stem = String(format: "frame_%08d", frame.frameID)
                    var row = FrameRecord(id: frame.frameID, timestamp: frame.timestamp,
                        transform: frame.transform, intrinsics: frame.intrinsics,
                        exposureDuration: frame.exposureDuration ?? 0, exposureOffsetEV: frame.exposureOffsetEV ?? 0,
                        iso: frame.iso ?? 0, estimatedBlurPx: frame.estimatedBlurPx ?? 0,
                        imageFile: stem + ".jpg", depthFile: frame.depthFile == nil ? nil : stem + ".f32",
                        confidenceFile: frame.confidenceFile == nil ? nil : stem + ".u8",
                        depthWidth: frame.depthWidth, depthHeight: frame.depthHeight)
                    row.sourceFrameID = frame.frameID; row.sourceVideoFile = segment; row.sourceVideoPTS = pts
                    row.imageSource = "decoded_recorded_video_native_pixels"
                    row.exposureMetadataAvailable = frame.exposureDuration != nil
                    let depth = try frame.depthFile.map { try Data(contentsOf: file($0, in: directory)) }
                    let confidence = try frame.confidenceFile.map { try Data(contentsOf: file($0, in: directory)) }
                    if let depth {
                        guard let w = frame.depthWidth, let h = frame.depthHeight, w > 0, h > 0, w <= 8192, h <= 8192,
                              depth.count == w * h * 4, confidence == nil || confidence?.count == w * h else { throw Failure.invalid("invalid same-frame depth") }
                    } else if confidence != nil { throw Failure.invalid("confidence without depth") }
                    // FrameWriter uses the matrix only as stored metadata; no rendering warp.
                    try await writer.write(Keyframe(pixelBuffer: buffer, depthData: depth, confidenceData: confidence,
                        depthWidth: frame.depthWidth ?? 0, depthHeight: frame.depthHeight ?? 0,
                        c2w: matrix_identity_float4x4, record: row))
                }
                completed += 1; index += 1
                if completed % 30 == 0 { progress(Double(completed) / Double(frames.count)) }
            }
            guard reader.status == .completed, index == expected.count else { throw reader.error ?? Failure.invalid("missing decoded video samples") }
        }
        try Task.checkCancellation()
        let report: [String: Any] = ["schemaVersion": 1, "status": "complete", "source": "recorded_video",
            "imageCount": completed, "recordedVideoFrameCount": frames.count,
            "droppedFrameIDs": all.filter { !$0.videoWritten }.map(\.frameID),
            "imageSource": "decoded_recorded_video_native_pixels", "additionalGeometryWarp": false,
            "note": "Video compression precedes JPEG encoding; no FPS resampling or interpolated frames"]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("frame-images.json"), options: .atomic)
        await writer.releaseEncodingCaches()
        progress(1)
        return completed
    }
}
