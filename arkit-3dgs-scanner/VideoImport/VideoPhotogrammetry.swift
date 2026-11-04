// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.

import Foundation
import RealityKit
import ImageIO
import simd

/// Converts extracted video frames to the same portable scan contract as prepare_video_scan.
/// All camera parameters and sparse points come from PhotogrammetrySession; ordinary video
/// supplies neither ARKit measurements nor physical scale. Run from the import worker task.
nonisolated enum VideoPhotogrammetry {
    struct Result: Sendable {
        let validFrames: Int
        let points: Int
    }

    enum PrepareError: LocalizedError {
        case unsupported, missing(String), malformed(String), reconstruction(String), ambiguousPose(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "PhotogrammetrySession with estimated camera intrinsics is not supported on this device."
            case .missing(let value): return "Missing required input: \(value)"
            case .malformed(let value): return "Invalid video frames: \(value)"
            case .reconstruction(let value): return "Photogrammetry reconstruction failed: \(value)"
            case .ambiguousPose(let value): return "Cannot establish a safe camera convention: \(value)"
            }
        }
    }

    static var isSupported: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return PhotogrammetrySession.isSupported }
        return false
    }

    @available(iOS 26.0, macOS 26.0, *)
    static var maximumInputImages: Int { PhotogrammetrySession.limits.maximumNumberOfInputImages }

    @available(iOS 26.0, macOS 26.0, *)
    static var maximumInputImageDimension: Int { PhotogrammetrySession.limits.maximumInputImageDimension }

    struct VideoFrame: Codable {
        let imageFile: String
        let timestamp: Double
    }

    static func validateTimeline(_ timeline: [VideoFrame]) throws {
        guard timeline.count >= 8 else { throw PrepareError.malformed("video-frames.json must contain at least 8 frames") }
        // Source PTS may begin before zero. Preserve that time origin; only ordering and
        // finite values are required for image-to-video correspondence and time differences.
        guard Set(timeline.map(\.imageFile)).count == timeline.count,
              timeline.allSatisfy({ $0.timestamp.isFinite }),
              zip(timeline, timeline.dropFirst()).allSatisfy({ pair in pair.0.timestamp < pair.1.timestamp }) else {
            throw PrepareError.malformed("video-frames.json requires unique imageFile names and finite strictly increasing source timestamps")
        }
    }

    struct Intrinsics: Codable {
        let fx: Double, fy: Double, cx: Double, cy: Double
        let width: Int, height: Int
    }

    /// JSON-compatible subset of FrameRecord. It deliberately has the same wire keys, while
    /// video-import.json records that this is not an ARKit/metre coordinate system.
    struct PoseRecord: Codable {
        let id: Int
        let timestamp: Double
        let transform: [Double]
        let intrinsics: Intrinsics
        let exposureDuration: Double
        let exposureOffsetEV: Double
        let iso: Double
        let ambientLux: Double?
        let estimatedBlurPx: Double
        let sharpness: Double
        let sharpnessRatio: Double
        let blurVerdict: String
        let imageFile: String
        let depthFile: String?
        let confidenceFile: String?
        let depthWidth: Int?
        let depthHeight: Int?
    }

    struct RawPose: Codable {
        var estimationBatchID: Int? = nil
        let sampleID: Int
        let imageFile: String
        let timestamp: Double
        let translation: [Float]
        let rotationIXIYIZR: [Float]
        let transformColumnMajor: [Float]
        let intrinsicsColumnMajor: [Float]?
        let lensDistortion: RawLensDistortion?
    }

    struct RawLensDistortion: Codable {
        let center: [Float]
        let radialLookupTable: [Float]
    }

    struct Drop: Codable {
        let imageFile: String
        let timestamp: Double
        let reason: String
    }

    struct CandidateScore: Codable {
        let name: String
        let evaluatedFrames: Int
        let projectedPoints: Int
        let positiveDepthPoints: Int
        let inBoundsPoints: Int
    }

    struct ImportManifest: Codable {
        let version: Int
        let method: String
        let sourceImagesDirectory: String
        let sourceTimingFile: String
        let coordinateSystem: String
        let unit: String
        let metricScale: Bool
        let normalizationCenter: [Float]
        let normalizationScale: Float
        let coordinateAdaptation: String
        let projectionCheck: [CandidateScore]
        let validFrames: [String]
        let droppedFrames: [Drop]
        let sourceCameraMetadata: String
        let sourceExposureAndISO: String
        let trainingFrameSelection: String
        let rawPoseFile: String
        let rawPointCloudFile: String
        let normalizedPointCloudFile: String
    }

    struct Point {
        var position: SIMD3<Float>
        var rgb: SIMD3<UInt8>
    }

    struct UsablePose {
        let sampleID: Int
        let fileName: String
        let timestamp: Double
        let matrix: simd_float4x4
        let intrinsics: simd_float3x3
        let imageSize: SIMD2<Int>
    }

    static func matrixColumnMajor(_ matrix: simd_float4x4) -> [Float] {
        (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
    }

    static func matrixColumnMajor(_ matrix: simd_float3x3) -> [Float] {
        (0..<3).flatMap { column in (0..<3).map { row in matrix[column][row] } }
    }

    static func matrixRowMajor(_ matrix: simd_float4x4) -> [Double] {
        (0..<4).flatMap { row in (0..<4).map { column in Double(matrix[column][row]) } }
    }

    static func imageSize(_ url: URL) throws -> SIMD2<Int> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else {
            throw PrepareError.malformed("cannot read image dimensions for \(url.lastPathComponent)")
        }
        return SIMD2(width, height)
    }

    static func isFinite(_ matrix: simd_float3x3) -> Bool {
        (0..<3).allSatisfy { col in (0..<3).allSatisfy { row in matrix[col][row].isFinite } }
    }

    static func isFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { col in (0..<4).allSatisfy { row in matrix[col][row].isFinite } }
    }

    static func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    static func intrinsics(_ matrix: simd_float3x3, size: SIMD2<Int>) -> Intrinsics? {
        guard isFinite(matrix) else { return nil }
        let fx = Double(matrix[0][0]), fy = Double(matrix[1][1])
        let cx = Double(matrix[2][0]), cy = Double(matrix[2][1])
        guard fx > 0, fy > 0, cx >= 0, cy >= 0,
              abs(matrix[0][1]) < 1e-4, abs(matrix[1][0]) < 1e-4,
              abs(matrix[0][2]) < 1e-4, abs(matrix[1][2]) < 1e-4, abs(matrix[2][2] - 1) < 1e-4,
              cx <= Double(size.x), cy <= Double(size.y) else { return nil }
        return Intrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: size.x, height: size.y)
    }

    static func yzFlip() -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, -1, 0, 0),
                                    SIMD4(0, 0, -1, 0), SIMD4(0, 0, 0, 1)))
    }

    /// Scores two explicit interpretations against the returned sparse cloud. Candidate `direct`
    /// treats the reported pose as GL-style c2w. `local_yz_flip` maps a +Z-forward/+Y-down local
    /// camera basis into that GL-style convention. We do not choose when the evidence is weak.
    static func scoreCandidate(name: String, poses: [UsablePose], points: [Point], flipLocalYZ: Bool) -> CandidateScore {
        guard !poses.isEmpty, !points.isEmpty else {
            return CandidateScore(name: name, evaluatedFrames: 0, projectedPoints: 0, positiveDepthPoints: 0, inBoundsPoints: 0)
        }
        let selectedPoses = Array(poses.prefix(24))
        let step = max(1, points.count / 20_000)
        var projected = 0, positive = 0, inBounds = 0
        let localFlip = yzFlip()
        for pose in selectedPoses {
            let c2w = flipLocalYZ ? pose.matrix * localFlip : pose.matrix
            let w2c = c2w.inverse
            let fx = pose.intrinsics[0][0], fy = pose.intrinsics[1][1]
            let cx = pose.intrinsics[2][0], cy = pose.intrinsics[2][1]
            for index in Swift.stride(from: 0, to: points.count, by: step) {
                let p = points[index].position
                let camera = w2c * SIMD4(p.x, p.y, p.z, 1)
                projected += 1
                // GL camera convention: forward is -Z; pixel y grows downwards.
                let depth = -camera.z
                guard depth.isFinite, depth > 1e-5 else { continue }
                positive += 1
                let x = fx * camera.x / depth + cx
                let y = -fy * camera.y / depth + cy
                if x >= 0, x < Float(pose.imageSize.x), y >= 0, y < Float(pose.imageSize.y) { inBounds += 1 }
            }
        }
        return CandidateScore(name: name, evaluatedFrames: selectedPoses.count, projectedPoints: projected,
                              positiveDepthPoints: positive, inBoundsPoints: inBounds)
    }

    static func chooseConvention(poses: [UsablePose], points: [Point]) throws -> (Bool, [CandidateScore]) {
        let direct = scoreCandidate(name: "direct_pose_as_gl_c2w", poses: poses, points: points, flipLocalYZ: false)
        let flipped = scoreCandidate(name: "local_yz_flip_to_gl_c2w", poses: poses, points: points, flipLocalYZ: true)
        let scores = [direct, flipped]
        let ordered = scores.sorted { $0.inBoundsPoints > $1.inBoundsPoints }
        guard let winner = ordered.first, let runnerUp = ordered.dropFirst().first,
              winner.evaluatedFrames >= 8,
              winner.inBoundsPoints >= max(64, winner.evaluatedFrames * 5),
              winner.positiveDepthPoints >= winner.inBoundsPoints,
              winner.inBoundsPoints >= runnerUp.inBoundsPoints * 3 / 2 + 10 else {
            throw PrepareError.ambiguousPose("projection candidates are not sufficiently separated: \(scores)")
        }
        return (winner.name == "local_yz_flip_to_gl_c2w", scores)
    }

    static func normalized(points: [Point]) throws -> (center: SIMD3<Float>, scale: Float, points: [Point]) {
        guard !points.isEmpty else { throw PrepareError.reconstruction("point cloud is empty") }
        let center = points.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.position } / Float(points.count)
        let radius = points.map { simd_length($0.position - center) }.sorted()
        // A high percentile avoids one sparse outlier deciding every Gaussian's numeric scale.
        let reference = radius[min(radius.count - 1, Int(Float(radius.count - 1) * 0.95))]
        guard reference.isFinite, reference > 1e-6 else { throw PrepareError.reconstruction("point cloud has no spatial extent") }
        let scale: Float = 1 / reference
        guard isFinite(center), scale.isFinite else { throw PrepareError.reconstruction("point cloud normalization is non-finite") }
        return (center, scale, points.map { Point(position: ($0.position - center) * scale, rgb: $0.rgb) })
    }

    static func appendLittleEndian(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    static func writePLY(_ points: [Point], to url: URL) throws {
        let header = "ply\nformat binary_little_endian 1.0\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + points.count * 15)
        for point in points {
            appendLittleEndian(point.position.x, to: &data)
            appendLittleEndian(point.position.y, to: &data)
            appendLittleEndian(point.position.z, to: &data)
            data.append(point.rgb.x); data.append(point.rgb.y); data.append(point.rgb.z)
        }
        try data.write(to: url, options: .atomic)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// The trained-model archive carries video-import.json. Embed the extractor's original
    /// JSON object so source identity, color conversion, pixel orientation and exact PTS
    /// policy travel with that archive without requiring another ZIP member. Older raw-result
    /// fixtures have no extraction metadata; a present but invalid file must never be ignored.
    static func manifestData(_ manifest: ImportManifest, scanDirectory: URL) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let source = scanDirectory.appendingPathComponent("video-source.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return data }
        guard let preprocessing = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any],
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PrepareError.malformed("video-source.json must contain a JSON metadata object")
        }
        object["videoPreprocessing"] = preprocessing
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static let outputNames = ["photogrammetry-poses.json", "photogrammetry-points.ply",
                                      "points.ply", "poses.jsonl", "video-import.json"]

    /// The extractor owns this directory until the whole import is published to ScanLibrary.
    /// Reject existing prepared output rather than mixing a previous reconstruction with new
    /// frames. A retry should use a fresh staging directory or remove its own failed output.
    static func loadTimeline(scanDirectory: URL) throws -> [VideoFrame] {
        try Task.checkCancellation()
        let images = scanDirectory.appendingPathComponent("images", isDirectory: true)
        let data = try Data(contentsOf: scanDirectory.appendingPathComponent("video-frames.json"))
        let timeline = try JSONDecoder().decode([VideoFrame].self, from: data)
        try validateTimeline(timeline)
        let resolvedImages = images.resolvingSymlinksInPath().standardizedFileURL
        for frame in timeline {
            guard !frame.imageFile.isEmpty, frame.imageFile != ".", frame.imageFile != "..",
                  !frame.imageFile.contains("/"), !frame.imageFile.contains("\\"),
                  (frame.imageFile as NSString).lastPathComponent == frame.imageFile else {
                throw PrepareError.malformed("imageFile must be a unique filename inside images/")
            }
            let url = images.appendingPathComponent(frame.imageFile)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == resolvedImages.path else {
                throw PrepareError.malformed("image is not a regular file inside images/: \(frame.imageFile)")
            }
        }
        // Session(input: URL) ingests all image files in the directory. Reject untracked files
        // so a resumed extraction cannot silently alter the camera reconstruction.
        let actualFiles = try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)
        guard Set(actualFiles.map(\.lastPathComponent)) == Set(timeline.map(\.imageFile)) else {
            throw PrepareError.malformed("images/ does not match video-frames.json")
        }
        for name in outputNames where FileManager.default.fileExists(atPath: scanDirectory.appendingPathComponent(name).path) {
            throw PrepareError.malformed("prepared output already exists: \(name)")
        }
        return timeline
    }

    /// Cancellation can arrive on another executor while RealityKit is awaiting output.
    /// Only start/cancel cross that boundary, serialized here; result processing stays on the
    /// worker task. Serializing start closes the cancel-before-process race.
    @available(iOS 26.0, macOS 26.0, *)
    private final class SessionControl: @unchecked Sendable {
        private let lock = NSLock()
        private let session: PhotogrammetrySession
        private var cancelled = false

        init(_ session: PhotogrammetrySession) { self.session = session }

        func start() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try session.process(requests: [.poses, .pointCloud])
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            session.cancel()
        }

        func checkCancellation() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }

        func stopAfterFailureOrCompletion() {
            lock.lock()
            defer { lock.unlock() }
            session.cancel()
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func prepare(scanDirectory: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> Result {
        try Task.checkCancellation()
        guard isSupported else { throw PrepareError.unsupported }
        let timeline = try loadTimeline(scanDirectory: scanDirectory)
        guard timeline.count <= maximumInputImages else {
            throw PrepareError.malformed("\(timeline.count) frames exceed this device's \(maximumInputImages)-image limit")
        }
        let images = scanDirectory.appendingPathComponent("images", isDirectory: true)
        var referenceSize: SIMD2<Int>?
        for frame in timeline {
            try Task.checkCancellation()
            let size = try imageSize(images.appendingPathComponent(frame.imageFile))
            guard max(size.x, size.y) <= maximumInputImageDimension else {
                throw PrepareError.malformed("image dimensions exceed this device's \(maximumInputImageDimension)-pixel limit")
            }
            guard referenceSize == nil || referenceSize == size else {
                throw PrepareError.malformed("training frames must have one common image resolution")
            }
            referenceSize = size
        }
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        // URL input lets RealityKit load images from disk instead of retaining every decoded
        // video frame in memory. The importer has already baked orientation into JPEG pixels.
        let session = try PhotogrammetrySession(input: images, configuration: configuration)
        let control = SessionControl(session)
        // An unstructured worker is not itself cancelled when its caller is cancelled. It
        // keeps consuming RealityKit outputs until cancellation is acknowledged, so the
        // caller cannot delete images while the session is still reading them.
        let work = Task {
            defer { control.stopAfterFailureOrCompletion() }
            try control.start()
            progress(0)
            var poseProgress = 0.0
            var cloudProgress = 0.0
            var posesResult: PhotogrammetrySession.Poses?
            var cloudResult: PhotogrammetrySession.PointCloud?
            var completed = false
            var requestFailure: String?
            outputLoop: for try await output in session.outputs {
                switch output {
                case .requestProgress(let request, let fraction):
                    guard fraction.isFinite else { continue }
                    let value = min(1, max(0, fraction))
                    switch request {
                    case .poses: poseProgress = max(poseProgress, value)
                    case .pointCloud: cloudProgress = max(cloudProgress, value)
                    default: break
                    }
                    progress((poseProgress + cloudProgress) * 0.45)
                case .requestComplete(_, let result):
                    switch result {
                    case .poses(let poses): posesResult = poses; poseProgress = 1
                    case .pointCloud(let cloud): cloudResult = cloud; cloudProgress = 1
                    default: break
                    }
                    progress((poseProgress + cloudProgress) * 0.45)
                case .requestError(_, let error):
                    requestFailure = error.localizedDescription
                    control.stopAfterFailureOrCompletion()
                case .processingComplete:
                    completed = true
                    break outputLoop
                case .processingCancelled:
                    // RealityKit can emit requestError before processingCancelled in response
                    // to our cancel(). A user cancellation takes precedence over that error.
                    try control.checkCancellation()
                    if let requestFailure { throw PrepareError.reconstruction(requestFailure) }
                    throw CancellationError()
                default: break
                }
            }
            try control.checkCancellation()
            if let requestFailure { throw PrepareError.reconstruction(requestFailure) }
            guard completed, let posesResult, let cloudResult, !cloudResult.points.isEmpty else {
                throw PrepareError.reconstruction("poses and sparse point cloud did not complete")
            }
            let byName = Dictionary(uniqueKeysWithValues: timeline.map { ($0.imageFile, $0) })
            var raw: [RawPose] = []
            for (id, pose) in posesResult.posesBySample.sorted(by: { $0.key < $1.key }) {
                try control.checkCancellation()
                guard let url = posesResult.urlsBySample[id], let source = byName[url.lastPathComponent] else {
                    throw PrepareError.reconstruction("a camera pose has no matching source video frame")
                }
                raw.append(RawPose(sampleID: id, imageFile: source.imageFile, timestamp: source.timestamp,
                                   translation: [pose.translation.x, pose.translation.y, pose.translation.z],
                                   rotationIXIYIZR: [pose.rotation.imag.x, pose.rotation.imag.y, pose.rotation.imag.z, pose.rotation.real],
                                   transformColumnMajor: matrixColumnMajor(pose.transform.matrix),
                                   intrinsicsColumnMajor: pose.intrinsics.map(matrixColumnMajor),
                                   lensDistortion: pose.lensDistortionData.map {
                                       RawLensDistortion(center: [$0.center.x, $0.center.y], radialLookupTable: $0.radialLookupTable)
                                   }))
            }
            let points = cloudResult.points.map { Point(position: $0.position, rgb: SIMD3($0.color.x, $0.color.y, $0.color.z)) }
            try control.checkCancellation()
            let result = try writeReconstruction(scanDirectory: scanDirectory, timeline: timeline, raw: raw, rawPoints: points,
                                                 checkCancellation: control.checkCancellation)
            try control.checkCancellation()
            progress(1)
            return result
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            control.cancel()
        }
    }

    /// Also exercised with saved, real RealityKit output by the CPU regression harness. This
    /// stage never estimates or substitutes camera intrinsics, poses, depth, or metric scale.
    static func writeReconstruction(scanDirectory: URL, timeline: [VideoFrame], raw: [RawPose], rawPoints: [Point],
                                    checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Result {
        try checkCancellation()
        try validateTimeline(timeline)
        guard !rawPoints.isEmpty, rawPoints.allSatisfy({ isFinite($0.position) }) else {
            throw PrepareError.reconstruction("sparse point cloud is empty or contains non-finite coordinates")
        }
        guard Set(raw.map(\.sampleID)).count == raw.count, Set(raw.map(\.imageFile)).count == raw.count else {
            throw PrepareError.reconstruction("duplicate camera sample IDs or source frames")
        }
        let images = scanDirectory.appendingPathComponent("images", isDirectory: true)
        let byName = Dictionary(uniqueKeysWithValues: timeline.map { ($0.imageFile, $0) })
        var usable: [UsablePose] = []
        var dropped: [Drop] = []
        for pose in raw {
            try checkCancellation()
            guard let source = byName[pose.imageFile], source.timestamp == pose.timestamp,
                  pose.translation.count == 3, pose.rotationIXIYIZR.count == 4,
                  pose.transformColumnMajor.count == 16,
                  pose.translation.allSatisfy(\.isFinite), pose.rotationIXIYIZR.allSatisfy(\.isFinite),
                  pose.transformColumnMajor.allSatisfy(\.isFinite) else {
                throw PrepareError.reconstruction("invalid camera sample \(pose.sampleID)")
            }
            let values = pose.transformColumnMajor
            let matrix = simd_float4x4(columns: (SIMD4(values[0], values[1], values[2], values[3]),
                                                SIMD4(values[4], values[5], values[6], values[7]),
                                                SIMD4(values[8], values[9], values[10], values[11]),
                                                SIMD4(values[12], values[13], values[14], values[15])))
            guard abs(matrix.determinant) > 1e-6, isFinite(matrix.inverse) else {
                throw PrepareError.reconstruction("singular camera transform \(pose.sampleID)")
            }
            let size = try imageSize(images.appendingPathComponent(pose.imageFile))
            guard let v = pose.intrinsicsColumnMajor, v.count == 9, v.allSatisfy(\.isFinite) else {
                dropped.append(Drop(imageFile: pose.imageFile, timestamp: pose.timestamp, reason: "missing_or_invalid_intrinsics"))
                continue
            }
            let k = simd_float3x3(columns: (SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8])))
            guard intrinsics(k, size: size) != nil else {
                dropped.append(Drop(imageFile: pose.imageFile, timestamp: pose.timestamp, reason: "missing_or_invalid_intrinsics"))
                continue
            }
            usable.append(UsablePose(sampleID: pose.sampleID, fileName: pose.imageFile, timestamp: pose.timestamp,
                                     matrix: matrix, intrinsics: k, imageSize: size))
        }
        guard usable.count >= 8 else {
            throw PrepareError.reconstruction("only \(usable.count) frames have pose and estimated intrinsics; need 8")
        }
        guard let size = usable.first?.imageSize, usable.allSatisfy({ $0.imageSize == size }) else {
            throw PrepareError.malformed("training frames must have one common image resolution")
        }
        let (flipLocalYZ, scores) = try chooseConvention(poses: usable, points: rawPoints)
        try checkCancellation()
        let norm = try normalized(points: rawPoints)
        let localFlip = yzFlip()
        var records: [PoseRecord] = []
        for pose in usable.sorted(by: { $0.timestamp < $1.timestamp }) {
            try checkCancellation()
            let c2w = flipLocalYZ ? pose.matrix * localFlip : pose.matrix
            var adjusted = c2w
            let translation = SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
            adjusted.columns.3 = SIMD4((translation - norm.center) * norm.scale, 1)
            guard let k = intrinsics(pose.intrinsics, size: pose.imageSize) else {
                throw PrepareError.reconstruction("camera intrinsics changed during preparation")
            }
            records.append(PoseRecord(id: pose.sampleID, timestamp: pose.timestamp, transform: matrixRowMajor(adjusted), intrinsics: k,
                                      exposureDuration: 0, exposureOffsetEV: 0, iso: 0, ambientLux: nil,
                                      estimatedBlurPx: 0, sharpness: 0, sharpnessRatio: 1, blurVerdict: "keep",
                                      imageFile: pose.fileName, depthFile: nil, confidenceFile: nil, depthWidth: nil, depthHeight: nil))
        }
        let validNames = Set(records.map(\.imageFile))
        for entry in timeline where !validNames.contains(entry.imageFile) && !dropped.contains(where: { $0.imageFile == entry.imageFile }) {
            dropped.append(Drop(imageFile: entry.imageFile, timestamp: entry.timestamp, reason: "no_photogrammetry_pose"))
        }
        let manifest = ImportManifest(version: 1, method: "RealityKit.PhotogrammetrySession",
                                      sourceImagesDirectory: "images", sourceTimingFile: "video-frames.json",
                                      coordinateSystem: "photogrammetry_estimated_c2w_adapted_to_gl_camera_basis",
                                      unit: "arbitrary_photogrammetry_unit_normalized", metricScale: false,
                                      normalizationCenter: [norm.center.x, norm.center.y, norm.center.z], normalizationScale: norm.scale,
                                      coordinateAdaptation: flipLocalYZ ? "local_yz_flip_to_gl_c2w" : "direct_pose_as_gl_c2w",
                                      projectionCheck: scores, validFrames: records.map(\.imageFile), droppedFrames: dropped,
                                      sourceCameraMetadata: "ordinary video: no ARKit pose, depth, or physical-scale metadata was supplied; training uses the estimated pinhole camera; optional lens distortion is preserved in raw poses, not applied to source pixels",
                                      sourceExposureAndISO: "unknown; poses.jsonl writes zero placeholders only for legacy FrameRecord compatibility",
                                      trainingFrameSelection: "stored",
                                      rawPoseFile: "photogrammetry-poses.json", rawPointCloudFile: "photogrammetry-points.ply",
                                      normalizedPointCloudFile: "points.ply")
        let encodedManifest = try manifestData(manifest, scanDirectory: scanDirectory)
        let fm = FileManager.default
        for name in outputNames where fm.fileExists(atPath: scanDirectory.appendingPathComponent(name).path) {
            throw PrepareError.malformed("prepared output already exists: \(name)")
        }
        let staging = scanDirectory.appendingPathComponent(".photogrammetry-output-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try checkCancellation()
        try writeJSON(raw, to: staging.appendingPathComponent("photogrammetry-poses.json"))
        try checkCancellation()
        try writePLY(rawPoints, to: staging.appendingPathComponent("photogrammetry-points.ply"))
        try checkCancellation()
        try writePLY(norm.points, to: staging.appendingPathComponent("points.ply"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var rows = Data()
        for record in records { rows.append(try encoder.encode(record)); rows.append(0x0A) }
        try rows.write(to: staging.appendingPathComponent("poses.jsonl"), options: .atomic)
        try encodedManifest.write(to: staging.appendingPathComponent("video-import.json"), options: .atomic)
        var published: [URL] = []
        do {
            // The manifest is the final commit marker. On interruption or a file error remove
            // only outputs moved by this call; original images and timing data stay untouched.
            for name in outputNames {
                try checkCancellation()
                let destination = scanDirectory.appendingPathComponent(name)
                try fm.moveItem(at: staging.appendingPathComponent(name), to: destination)
                published.append(destination)
            }
            try checkCancellation()
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
        return Result(validFrames: records.count, points: norm.points.count)
    }
}

