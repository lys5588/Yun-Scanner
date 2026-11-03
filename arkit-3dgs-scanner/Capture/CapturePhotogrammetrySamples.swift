// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import RealityKit
import ImageIO
import CoreVideo
import CoreGraphics

/// Loads one sample at a time. Never retain an array of full-resolution pixel buffers.
/// Camera priors cannot be assigned through PhotogrammetrySample's public API.
@available(iOS 26.0, macOS 26.0, *)
nonisolated final class CapturePhotogrammetrySamples: Sequence, @unchecked Sendable {
    struct Input: Sendable {
        let record: FrameRecord
        let image: URL
        let depth: URL?
        let confidence: URL?
        let width: Int
        let height: Int
    }
    let inputs: [Input]
    private let lock = NSLock()
    private var error: String?
    private var depthIDs = Set<Int>()
    private var cancelled = false
    init(inputs: [Input]) { self.inputs = inputs }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return error }
    var suppliedDepthIDs: [Int] { lock.lock(); defer { lock.unlock() }; return depthIDs.sorted() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    struct Iterator: IteratorProtocol {
        let owner: CapturePhotogrammetrySamples
        var index = 0
        mutating func next() -> PhotogrammetrySample? {
            guard index < owner.inputs.count else { return nil }
            owner.lock.lock()
            let stopped = owner.cancelled || owner.error != nil
            owner.lock.unlock()
            guard !stopped else { return nil }
            let input = owner.inputs[index]; index += 1
            do { return try autoreleasepool { try owner.sample(input) } }
            catch {
                owner.lock.lock(); owner.error = String(describing: error); owner.lock.unlock()
                return nil
            }
        }
    }
    func makeIterator() -> Iterator { Iterator(owner: self) }
    enum Failure: String, Error { case invalidImage, invalidDepth, pixelBuffer }
    static func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = format == kCVPixelFormatType_32BGRA
            ? [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] : [:]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &result) == kCVReturnSuccess,
              let result else { throw Failure.pixelBuffer }
        return result
    }
    func sample(_ input: Input) throws -> PhotogrammetrySample {
        guard let source = CGImageSourceCreateWithURL(input.image as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: Swift.max(input.width,input.height),
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw Failure.invalidImage }
        let buffer = try Self.pixelBuffer(width: input.width, height: input.height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: input.width, height: input.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw Failure.pixelBuffer }
        context.draw(image, in: CGRect(x: 0, y: 0, width: input.width, height: input.height))
        var sample = PhotogrammetrySample(id: input.record.id, image: buffer)
        // Pixels stay in sensor orientation. No invented EXIF focal length, camera prior or gravity.
        guard sample.orientation == .up else { throw Failure.invalidImage }
        if let depth = try depthBuffer(input) {
            sample.depthDataMap = depth
            lock.lock(); depthIDs.insert(input.record.id); lock.unlock()
        }
        return sample
    }
    /// Expand the aligned sensor depth to the actual sample image size without changing meters.
    /// Low-confidence/invalid depth becomes NaN, never zero or fabricated range measurements.
    func depthBuffer(_ input: Input) throws -> CVPixelBuffer? {
        guard let url = input.depth else { return nil }
        let r = input.record
        guard let w = r.depthWidth, let h = r.depthHeight, w > 0, h > 0,
              w <= r.intrinsics.width, h <= r.intrinsics.height,
              abs(Double(w)/Double(h) - Double(r.intrinsics.width)/Double(r.intrinsics.height)) < 0.01 else { throw Failure.invalidDepth }
        let data = try Data(contentsOf: url)
        let confidence = try input.confidence.map { try Data(contentsOf: $0) }
        guard data.count == w*h*4, confidence == nil || confidence?.count == w*h else { throw Failure.invalidDepth }
        var values = [Float](repeating: .nan, count: w*h)
        var valid = 0
        for i in values.indices {
            let bits = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i*4, as: UInt32.self)) }
            let depth = Float(bitPattern: bits)
            if let confidence, confidence[i] > 2 { throw Failure.invalidDepth }
            if depth.isFinite, depth > 0, confidence == nil || confidence![i] >= 1 { values[i] = depth; valid += 1 }
        }
        guard valid >= Swift.max(1, values.count/100) else { return nil }
        let buffer = try Self.pixelBuffer(width: input.width, height: input.height, format: kCVPixelFormatType_DepthFloat32)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.pixelBuffer }
        for y in 0..<input.height {
            let row = base.advanced(by: y*CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float.self)
            let dy = Swift.min(h-1, Int((Double(y)+0.5)*Double(h)/Double(input.height)))
            for x in 0..<input.width {
                let dx = Swift.min(w-1, Int((Double(x)+0.5)*Double(w)/Double(input.width)))
                row[x] = values[dy*w+dx]
            }
        }
        return buffer
    }
}
