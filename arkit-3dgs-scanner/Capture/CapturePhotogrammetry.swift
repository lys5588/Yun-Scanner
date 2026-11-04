// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import RealityKit
import CryptoKit
import simd
#if canImport(UIKit)
import UIKit
#endif

/// An additional per-keyframe estimate, never a replacement for captured K/c2w or depth.
nonisolated enum CapturePhotogrammetry {
    static let reportName = "camera-estimation.json"
    struct Report: Codable, Sendable {
        var schemaVersion = 2
        var alignmentPolicy: String? = "global_similarity_fit_outliers_retained"
        var method = "RealityKit.PhotogrammetrySession"
        var status = "processing"
        var reason: String?
        var inputFrameCount = 0
        var estimatedFrameCount = 0
        var rawEstimatedFrameCount = 0
        var depthFrameIDs: [Int] = []
        var missingCameraFrameIDs: [Int] = []
        var sourcePosesSHA256 = ""
        var rawCameraFile: String?
        var rawPointCloudFile: String?
        var coordinateAdaptation: String?
        var cameraFile: String?
        var pointCloudFile: String?
        var alignment: MetricCameraAlignment.Result?
        var seconds = 0.0
        var originalCameraFile = "poses.jsonl"
        var scope = "saved_keyframes_only; continuous frames.jsonl is unchanged"
        var worldCoordinates = "original ARKit world, meters, gravity-aligned Y-up"
        var cameraConvention = "OpenGL camera-to-world, row-major"
        var scaleReference = "original ARKit camera trajectory"
        var accuracy = "Global coordinate registration only; disagreement is diagnostic, not an accuracy verdict"
        var depthPolicy = "same-frame metric depth; confidence below medium masked as NaN; resized to sample pixels"
        var projectionChecks: [VideoPhotogrammetry.CandidateScore]?
    }
    struct Camera: Codable, Sendable {
        let id: Int
        let imageFile: String
        let timestamp: Double
        let intrinsics: CameraIntrinsics
        let originalIntrinsics: CameraIntrinsics
        let transform: [Double]
        let worldToCamera: [Double]
        let opencvWorldToCamera: [Double]
        let estimationWidth: Int
        let estimationHeight: Int
        let lensDistortionInEstimationPixels: VideoPhotogrammetry.RawLensDistortion?
    }
    struct SparsePoint: Codable { let position: [Double]; let rgb: [UInt8] }
    enum Failure: Error { case invalidInput(String), processing(String) }
    static func readReport(in directory: URL) -> Report? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(reportName)) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    /// Only caller-owned child paths are read; input never follows a symlink outside a scan.
    static func file(_ name: String, under directory: URL) throws -> URL {
        guard !name.isEmpty, (name as NSString).lastPathComponent == name, name != ".", name != ".." else {
            throw Failure.invalidInput("unsafe filename")
        }
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path else {
            throw Failure.invalidInput("unsafe source file")
        }
        return url
    }
    static func records(_ data: Data) throws -> [FrameRecord] {
        let decoder = JSONDecoder()
        let rows = try data.split(separator: 10).filter { !$0.isEmpty }.map { try decoder.decode(FrameRecord.self, from: Data($0)) }
        guard Set(rows.map(\.id)).count == rows.count, Set(rows.map(\.imageFile)).count == rows.count,
              rows.allSatisfy({ r in
                  r.id >= 0 && r.id <= Int(Int32.max) && r.timestamp.isFinite &&
                  MetricCameraAlignment.matrix(r.transform) != nil && r.intrinsics.width > 0 && r.intrinsics.height > 0 &&
                  [r.intrinsics.fx,r.intrinsics.fy,r.intrinsics.cx,r.intrinsics.cy].allSatisfy(\.isFinite) &&
                  r.intrinsics.fx > 0 && r.intrinsics.fy > 0
              }), zip(rows, rows.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else {
            throw Failure.invalidInput("invalid or duplicate captured camera records")
        }
        return rows
    }
    @available(iOS 26.0, macOS 26.0, *)
    static func inputs(records: [FrameRecord], directory: URL) throws -> [CapturePhotogrammetrySamples.Input] {
        for folder in ["images"] + (records.contains { $0.depthFile != nil } ? ["depth"] : []) {
            let url = directory.appendingPathComponent(folder, isDirectory: true)
            guard url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().appendingPathComponent(folder).path else {
                throw Failure.invalidInput("source folder is a symbolic link")
            }
        }
        return try records.map { record in
            try Task.checkCancellation()
            let image = try file(record.imageFile, under: directory.appendingPathComponent("images"))
            let size = try VideoPhotogrammetry.imageSize(image)
            guard size.x == record.intrinsics.width, size.y == record.intrinsics.height else {
                throw Failure.invalidInput("image dimensions differ from captured intrinsics")
            }
            let factor = min(1, Double(min(1600, PhotogrammetrySession.limits.maximumInputImageDimension))/Double(max(size.x,size.y)))
            let width = Int((Double(size.x)*factor).rounded()), height = Int((Double(size.y)*factor).rounded())
            let depth = try record.depthFile.map { try file($0, under: directory.appendingPathComponent("depth")) }
            let confidence = try record.confidenceFile.map { try file($0, under: directory.appendingPathComponent("depth")) }
            if depth == nil, confidence != nil { throw Failure.invalidInput("confidence without depth") }
            return CapturePhotogrammetrySamples.Input(record: record, image: image, depth: depth, confidence: confidence, width: width, height: height)
        }
    }
    /// Serialize sessions even across screens. The actor remains reentrant, so explicitly gate it.
    private actor Gate {
        var busy = false
        func acquire() -> Bool { guard !busy else { return false }; busy = true; return true }
        func release() { busy = false }
    }
    private static let gate = Gate()
    static func run(directory: URL, progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws -> Report {
        guard await gate.acquire() else { throw Failure.processing("another camera estimation is running") }
        do {
            // Explicitly leave the UI actor even with approachable concurrency enabled.
            // Keep the gate until cancellation has drained the underlying RealityKit session.
            let worker = Task.detached(priority: .userInitiated) {
                try await runExclusively(directory: directory, progress: progress)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            await gate.release(); return result
        } catch { await gate.release(); throw error }
    }
    private static func runExclusively(directory: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> Report {
        let start = Date()
        var report = Report()
        let reportURL = directory.appendingPathComponent(reportName)
        let fm = FileManager.default
        let token = UUID().uuidString
        let staging = directory.appendingPathComponent(".camera-estimation-\(token)")
        defer { try? fm.removeItem(at: staging) }
        do {
            try Task.checkCancellation()
            guard !fm.fileExists(atPath: directory.appendingPathComponent("video-import.json").path),
                  let metaData = CaptureMetadata.data(in: directory),
                  let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                  meta["cameraConvention"] as? String == "arkit_gl_c2w_row_major", meta["worldAlignment"] as? String == "gravity",
                  let stream = meta["streamCapture"] as? [String: Any],
                  stream["status"] as? String == "complete" else { throw Failure.invalidInput("requires completed original ARKit capture") }
            let source = try Data(contentsOf: file("poses.jsonl", under: directory))
            report.sourcePosesSHA256 = hash(source)
            let records = try records(source)
            report.inputFrameCount = records.count
            try write(report, to: reportURL)
            guard records.count >= 8 else { report.status = "insufficient_frames"; try write(report,to:reportURL); return report }
            guard #available(iOS 26.0, macOS 26.0, *), PhotogrammetrySession.isSupported else {
                report.status = "unsupported"; try write(report,to:reportURL); return report
            }
            guard records.count <= min(200, PhotogrammetrySession.limits.maximumNumberOfInputImages) else {
                report.status = "too_many_frames"; report.reason = "No frames silently subsampled; maximum \(min(200, PhotogrammetrySession.limits.maximumNumberOfInputImages))"
                try write(report,to:reportURL); return report
            }
            let inputs = try inputs(records: records, directory: directory)
            let samples = CapturePhotogrammetrySamples(inputs: inputs)
            let output = try await estimate(samples: samples, progress: progress)
            try Task.checkCancellation()
            report.depthFrameIDs = samples.suppliedDepthIDs
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            let raw = output.raw
            report.rawEstimatedFrameCount = raw.count
            try write(raw, to: staging.appendingPathComponent("cameras-realitykit.json"))
            try VideoPhotogrammetry.writePLY(output.points, to: staging.appendingPathComponent("points-realitykit.ply"))
            let destinationName = "camera-estimation/\(token)"
            report.rawCameraFile = destinationName + "/cameras-realitykit.json"
            report.rawPointCloudFile = destinationName + "/points-realitykit.ply"
            do {
                let built = try align(raw: raw, points: output.points, inputs: inputs)
                report.alignment = built.alignment
                report.projectionChecks = built.checks
                report.coordinateAdaptation = built.coordinateAdaptation
                report.estimatedFrameCount = built.cameras.count
                let ids = Set(built.cameras.map(\.id))
                report.missingCameraFrameIDs = records.filter { !ids.contains($0.id) }.map(\.id)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                var data = Data()
                for camera in built.cameras { data.append(try encoder.encode(camera)); data.append(10) }
                try data.write(to: staging.appendingPathComponent("cameras-arkit.jsonl"), options: .atomic)
                let points = output.points.map { p -> SparsePoint in
                    let q = built.alignment.point(SIMD3(Double(p.position.x), Double(p.position.y), Double(p.position.z)))
                    return SparsePoint(position: [q.x,q.y,q.z],rgb: [p.rgb.x,p.rgb.y,p.rgb.z])
                }
                try write(points, to: staging.appendingPathComponent("points-arkit.json"))
                report.cameraFile = destinationName + "/cameras-arkit.jsonl"
                report.pointCloudFile = destinationName + "/points-arkit.json"
                report.status = "estimated_aligned"
            } catch {
                report.status = "alignment_rejected"; report.reason = String(describing: error)
                report.missingCameraFrameIDs = records.map(\.id)
            }
            try Task.checkCancellation()
            guard hash(try Data(contentsOf: file("poses.jsonl", under: directory))) == report.sourcePosesSHA256 else {
                throw Failure.invalidInput("captured cameras changed during estimation")
            }
            try fm.createDirectory(at: directory.appendingPathComponent("camera-estimation"), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: directory.appendingPathComponent(destinationName))
            report.seconds = Date().timeIntervalSince(start)
            try write(report, to: reportURL)
            progress(1)
            return report
        } catch {
            report.status = error is CancellationError ? "cancelled" : "failed"
            report.reason = String(describing: error); report.seconds = Date().timeIntervalSince(start)
            report.cameraFile = nil; report.pointCloudFile = nil; report.rawCameraFile = nil; report.rawPointCloudFile = nil; report.estimatedFrameCount = 0
            try write(report, to: reportURL)
            if error is CancellationError { throw error }
            return report
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    private final class Control: @unchecked Sendable {
        let lock = NSLock()
        let session: PhotogrammetrySession
        let samples: CapturePhotogrammetrySamples
        var cancelled = false
        init(_ session: PhotogrammetrySession, _ samples: CapturePhotogrammetrySamples) { self.session = session; self.samples = samples }
        func start() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() }; try session.process(requests: [.poses,.pointCloud]) }
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; samples.cancel(); session.cancel() }
        func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
        func stop() { lock.lock(); defer { lock.unlock() }; session.cancel() }
    }
    @available(iOS 26.0, macOS 26.0, *)
    private static func estimate(samples: CapturePhotogrammetrySamples, progress: @Sendable @escaping (Double) -> Void) async throws
        -> (raw: [VideoPhotogrammetry.RawPose], points: [VideoPhotogrammetry.Point]) {
        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering = .sequential; config.isObjectMaskingEnabled = false
        let session = try PhotogrammetrySession(input: samples, configuration: config)
        let control = Control(session, samples)
        let center = NotificationCenter.default
        var observers = [center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            if ProcessInfo.processInfo.thermalState == .critical { control.cancel() }
        }]
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in control.cancel() })
        #endif
        defer { for observer in observers { center.removeObserver(observer) } }
        if ProcessInfo.processInfo.thermalState == .critical { control.cancel() }
        let worker = Task {
            defer { control.stop() }
            try control.start()
            var poses: PhotogrammetrySession.Poses?
            var cloud: PhotogrammetrySession.PointCloud?
            var completed = false
            var failure: String?
            var poseProgress = 0.0, cloudProgress = 0.0
            outputLoop: for try await output in session.outputs {
                switch output {
                case .requestProgress(let request, let value):
                    if value.isFinite {
                        if request == .poses { poseProgress = max(poseProgress,min(1,max(0,value))) }
                        if request == .pointCloud { cloudProgress = max(cloudProgress,min(1,max(0,value))) }
                        progress((poseProgress+cloudProgress)*0.45)
                    }
                case .requestComplete(_, let result):
                    if case .poses(let p) = result { poses = p }
                    if case .pointCloud(let p) = result { cloud = p }
                case .requestError(_, let error): failure = error.localizedDescription; control.stop()
                case .processingCancelled: try control.check(); throw Failure.processing(failure ?? "system cancelled estimation")
                case .processingComplete: completed = true; break outputLoop
                default: break
                }
            }
            try control.check()
            if let failure = samples.failure ?? failure { throw Failure.processing(failure) }
            guard completed, let poses, let cloud, !cloud.points.isEmpty else { throw Failure.processing("no camera/point-cloud result") }
            let inputs = Dictionary(uniqueKeysWithValues: samples.inputs.map { ($0.record.id,$0) })
            var raw: [VideoPhotogrammetry.RawPose] = []
            for (id, pose) in poses.posesBySample.sorted(by: { $0.key < $1.key }) {
                guard let input = inputs[id] else { throw Failure.processing("unknown RealityKit sample ID") }
                raw.append(VideoPhotogrammetry.RawPose(sampleID: id, imageFile: input.record.imageFile, timestamp: input.record.timestamp,
                    translation: [pose.translation.x,pose.translation.y,pose.translation.z],
                    rotationIXIYIZR: [pose.rotation.imag.x,pose.rotation.imag.y,pose.rotation.imag.z,pose.rotation.real],
                    transformColumnMajor: VideoPhotogrammetry.matrixColumnMajor(pose.transform.matrix),
                    intrinsicsColumnMajor: pose.intrinsics.map(VideoPhotogrammetry.matrixColumnMajor),
                    lensDistortion: pose.lensDistortionData.map { VideoPhotogrammetry.RawLensDistortion(center: [$0.center.x,$0.center.y],radialLookupTable: $0.radialLookupTable) }))
            }
            return (raw, cloud.points.map { VideoPhotogrammetry.Point(position: $0.position,rgb: SIMD3($0.color.x,$0.color.y,$0.color.z)) })
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { control.cancel() }
    }
    @available(iOS 26.0, macOS 26.0, *)
    static func align(raw: [VideoPhotogrammetry.RawPose], points: [VideoPhotogrammetry.Point], inputs: [CapturePhotogrammetrySamples.Input]) throws
        -> (cameras: [Camera], alignment: MetricCameraAlignment.Result, checks: [VideoPhotogrammetry.CandidateScore], coordinateAdaptation: String) {
        guard !points.isEmpty, points.allSatisfy({ VideoPhotogrammetry.isFinite($0.position) }),
              Set(raw.map(\.sampleID)).count == raw.count else { throw Failure.processing("invalid sparse output") }
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.record.id,$0) })
        var usable: [VideoPhotogrammetry.UsablePose] = []
        for pose in raw {
            guard let input = byID[pose.sampleID], pose.imageFile == input.record.imageFile,
                  pose.timestamp == input.record.timestamp, pose.transformColumnMajor.count == 16 else { throw Failure.processing("invalid output correspondence") }
            let v = pose.transformColumnMajor
            let matrix = simd_float4x4(columns: (SIMD4(v[0],v[1],v[2],v[3]),SIMD4(v[4],v[5],v[6],v[7]),SIMD4(v[8],v[9],v[10],v[11]),SIMD4(v[12],v[13],v[14],v[15])))
            guard MetricCameraAlignment.matrix(VideoPhotogrammetry.matrixRowMajor(matrix)) != nil else { throw Failure.processing("invalid estimated pose") }
            guard let k = pose.intrinsicsColumnMajor, k.count == 9 else { continue }
            let intr = simd_float3x3(columns: (SIMD3(k[0],k[1],k[2]),SIMD3(k[3],k[4],k[5]),SIMD3(k[6],k[7],k[8])))
            let size = SIMD2(input.width,input.height)
            guard VideoPhotogrammetry.intrinsics(intr,size: size) != nil else { continue }
            usable.append(VideoPhotogrammetry.UsablePose(sampleID: pose.sampleID,fileName:pose.imageFile,timestamp:pose.timestamp,matrix:matrix,intrinsics:intr,imageSize:size))
        }
        let checks = [false,true].map { flip in
            VideoPhotogrammetry.scoreCandidate(name: flip ? "local_yz_flip_to_gl_c2w" : "direct_pose_as_gl_c2w", poses: usable, points: points, flipLocalYZ: flip)
        }
        // A room may surround the camera, making aggregate point projection ambiguous.
        // Here we also have measured, corresponding ARKit cameras to resolve the basis.
        var candidates: [(flip: Bool, pairs: [MetricCameraAlignment.Pair], alignment: MetricCameraAlignment.Result)] = []
        for flip in [false,true] {
            let pairs = usable.map { p -> MetricCameraAlignment.Pair in
                let m = flip ? p.matrix * VideoPhotogrammetry.yzFlip() : p.matrix
                return MetricCameraAlignment.Pair(id:p.sampleID,estimated:MetricCameraAlignment.matrix(VideoPhotogrammetry.matrixRowMajor(m))!,reference:MetricCameraAlignment.matrix(byID[p.sampleID]!.record.transform)!)
            }
            let score = checks[flip ? 1 : 0]
            if score.evaluatedFrames >= 8, score.inBoundsPoints >= max(64,score.evaluatedFrames*5),
               let alignment = try? MetricCameraAlignment.solve(pairs) { candidates.append((flip,pairs,alignment)) }
        }
        if candidates.count == 2 {
            // A surrounding room can project in both directions. A varying 180°
            // local-axis error cannot be absorbed by one world rotation. Use that
            // distinction to resolve conventions, never to discard individual poses.
            let ordered = candidates.sorted { $0.alignment.medianRotationErrorDegrees < $1.alignment.medianRotationErrorDegrees }
            let preferred: Bool
            if ordered[1].alignment.medianRotationErrorDegrees - ordered[0].alignment.medianRotationErrorDegrees > 5 {
                preferred = ordered[0].flip
            } else {
                preferred = try VideoPhotogrammetry.chooseConvention(poses:usable,points:points).0
            }
            candidates.removeAll { $0.flip != preferred }
        }
        guard let selected = candidates.first else { throw Failure.processing("cannot establish camera convention and a nondegenerate global metric transform") }
        let pairs = selected.pairs, alignment = selected.alignment
        let rawByID = Dictionary(uniqueKeysWithValues:raw.map { ($0.sampleID,$0) })
        let pairByID = Dictionary(uniqueKeysWithValues:pairs.map { ($0.id,$0) })
        let cameras = usable.map { p -> Camera in
            let input = byID[p.sampleID]!, record = input.record
            let sx = Double(record.intrinsics.width)/Double(input.width), sy = Double(record.intrinsics.height)/Double(input.height)
            let k = CameraIntrinsics(fx:Double(p.intrinsics[0][0])*sx,fy:Double(p.intrinsics[1][1])*sy,
                                    cx:Double(p.intrinsics[2][0])*sx,cy:Double(p.intrinsics[2][1])*sy,width:record.intrinsics.width,height:record.intrinsics.height)
            let transform = alignment.camera(pairByID[p.sampleID]!.estimated), inverse = transform.inverse
            let flip = simd_double4x4(diagonal: SIMD4(1,-1,-1,1))
            return Camera(id:record.id,imageFile:record.imageFile,timestamp:record.timestamp,intrinsics:k,originalIntrinsics:record.intrinsics,
                          transform:MetricCameraAlignment.rowMajor(transform),worldToCamera:MetricCameraAlignment.rowMajor(inverse),
                          opencvWorldToCamera:MetricCameraAlignment.rowMajor(flip*inverse),estimationWidth:input.width,estimationHeight:input.height,
                          lensDistortionInEstimationPixels:rawByID[p.sampleID]?.lensDistortion)
        }
        return (cameras,alignment,checks,selected.flip ? "local_yz_flip_to_gl_c2w" : "direct_pose_as_gl_c2w")
    }
}
