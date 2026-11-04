// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import CoreVideo
import ImageIO

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: message, code: 1) }
}
private func verify(_ directory: URL, writer: FrameWriter) async throws {
    let manifest = try Data(contentsOf: directory.appendingPathComponent("frames.jsonl"))
    let frames = try manifest.split(separator: 10).map { try JSONDecoder().decode(CaptureStreamFrame.self, from: Data($0)) }.filter(\.videoWritten)
    let count = try await CaptureVideoFrames.append(directory: directory, writer: writer)
    let records = await writer.snapshotRecords()
    try check(count == frames.count && records.count == frames.count, "one JPEG per accepted video sample")
    for (row, frame) in zip(records, frames) {
        try check(row.id == frame.frameID && row.timestamp == frame.timestamp && row.transform == frame.transform, "same ARFrame timestamp and pose")
        try check(row.intrinsics.fx == frame.intrinsics.fx && row.intrinsics.fy == frame.intrinsics.fy && row.intrinsics.cx == frame.intrinsics.cx && row.intrinsics.cy == frame.intrinsics.cy, "same per-frame K")
        let source = CGImageSourceCreateWithURL(directory.appendingPathComponent("images/"+row.imageFile) as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try check(image.width == frame.intrinsics.width && image.height == frame.intrinsics.height, "native sensor pixels without display rotation")
        if let a = row.depthFile, let b = frame.depthFile {
            try check(try Data(contentsOf: directory.appendingPathComponent("depth/"+a)) == Data(contentsOf: directory.appendingPathComponent(b)), "same frame depth bytes")
        }
    }
    let again = try await CaptureVideoFrames.append(directory: directory, writer: writer)
    let afterRetry = await writer.snapshotRecords()
    try check(again == count && afterRetry.count == count, "retry does not duplicate or replace images")
    try check(try Data(contentsOf: directory.appendingPathComponent("frames.jsonl")) == manifest, "continuous manifest immutable")
    print("PASS \(count) video samples: images, timestamps, K/c2w, native dimensions, depth, retry, immutable manifest")
}
@main enum Test {
    static func main() async throws {
        let fm = FileManager.default
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--replay" {
            let source = URL(fileURLWithPath: CommandLine.arguments[2]), target = URL(fileURLWithPath: CommandLine.arguments[3])
            try check(!fm.fileExists(atPath: target.path), "replay requires a new output directory")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in ["frames.jsonl", "capture-meta.json", "depth"] + (try fm.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".mov") }) {
                try fm.copyItem(at: source.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
            let writer = try FrameWriter(sessionDir: target, saveDepth: true, jpegQuality: 0.95)
            try await verify(target, writer: writer)
            _ = await writer.finish()
            return
        }
        let root = fm.temporaryDirectory.appendingPathComponent("full-video-frames-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel)
        let buffer = pixel!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetBytesPerRow(buffer)*240)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let recorder = try CaptureStreamRecorder(sessionDir: root)
        for i in 0..<16 {
            var frame = CaptureStreamFrame(frameID: i, timestamp: 123 + Double(i)*0.0333347,
                videoWritten: false, intrinsics: .init(fx: 200+Double(i), fy: 200, cx: 160, cy: 120, width: 320, height: 240),
                transform: [1,0,0,Double(i)*0.01,0,1,0,0,0,0,1,0,0,0,0,1], trackingState: i == 4 ? "limited" : "normal")
            frame.depthWidth = 4; frame.depthHeight = 3
            frame.exposureDuration = 1.0/120; frame.exposureOffsetEV = 0
            if i == 0 || i == 3 { frame.dropReason = "test_backpressure" }
            _ = try await recorder.append(.init(manifest: frame, color: frame.dropReason == nil ? buffer : nil,
                depth: Data(repeating: 0, count: 48), confidence: Data(repeating: 2, count: 12)))
            if i == 8 { try await recorder.finishSegment() }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await recorder.finish()
        let writer = try FrameWriter(sessionDir: root, saveDepth: true, jpegQuality: 0.95)
        try await verify(root, writer: writer)
        let records = await writer.snapshotRecords()
        try check(records.contains { $0.id == 4 } && !records.contains { $0.id == 0 || $0.id == 3 }, "limited tracking retained; dropped video never fabricated")
        try check(records.allSatisfy { $0.exposureDuration == 1.0/120 && $0.exposureMetadataAvailable == true }, "same-frame exposure preserved")
        // A corrupt time association must fail, rather than silently attach the next pose.
        let manifestURL = root.appendingPathComponent("frames.jsonl")
        var frames = try Data(contentsOf: manifestURL).split(separator: 10).map { try JSONDecoder().decode(CaptureStreamFrame.self, from: Data($0)) }
        let first = frames.firstIndex(where: \.videoWritten)!
        frames[first].videoPTS! += 0.01
        var changed = Data()
        for frame in frames { changed.append(try JSONEncoder().encode(frame)); changed.append(10) }
        try changed.write(to: manifestURL)
        do {
            _ = try await CaptureVideoFrames.append(directory: root, writer: writer)
            throw NSError(domain: "accepted bad PTS", code: 1)
        } catch CaptureVideoFrames.Failure.invalid { print("PASS corrupt PTS rejected") }
        _ = await writer.finish()
    }
}
