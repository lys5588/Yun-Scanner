// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import CryptoKit
import ImageIO
import simd

/// Builds a fresh, allowlisted reconstruction package. Never mirrors a capture tree.
nonisolated enum BetaReconstructionExport {
    struct ExportError: LocalizedError {
        let detail: String
        var errorDescription: String? { L10n.text("无法保存筛选结果：\(detail)") }
    }
    private static func fail(_ text: String) -> ExportError { ExportError(detail: text) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func json(_ url: URL) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw fail("invalid JSON") }
        return result
    }
    private static func rows(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 10).map {
            guard let row = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else { throw fail("invalid JSONL") }
            return row
        }
    }
    /// Child paths must resolve inside the scan; none of their components may be symlinks.
    private static func file(_ path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { throw fail("unsafe path") }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw fail("symbolic link") }
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw fail("missing file") }
        return url
    }
    private static func basename(_ name: String) -> Bool { !name.isEmpty && (name as NSString).lastPathComponent == name && name != "." && name != ".." && !name.contains("\\") }
    private static func calibration(_ object: Any?) -> CameraIntrinsics? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let k = try? JSONDecoder().decode(CameraIntrinsics.self, from: data),
              k.width > 0, k.height > 0, [k.fx,k.fy,k.cx,k.cy].allSatisfy(\.isFinite), k.fx > 0, k.fy > 0 else { return nil }
        return k
    }
    private static func validCamera(_ row: [String: Any]) -> Bool {
        guard let values = row["transform"] as? [Double], MetricCameraAlignment.matrix(values) != nil,
              calibration(row["intrinsics"]) != nil else { return false }
        return true
    }
    private static func addExtrinsics(_ row: [String: Any]) -> [String: Any] {
        var result = row
        let inverse = MetricCameraAlignment.matrix(row["transform"] as! [Double])!.inverse
        result["worldToCamera"] = MetricCameraAlignment.rowMajor(inverse)
        result["opencvWorldToCamera"] = MetricCameraAlignment.rowMajor(simd_double4x4(diagonal: SIMD4(1,-1,-1,1))*inverse)
        return result
    }
    private static func imageValid(_ name: String, k: CameraIntrinsics, root: URL) -> Bool {
        autoreleasepool {
        guard basename(name), let url = try? file("images/"+name,in:root),
              let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any],
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              properties[kCGImagePropertyPixelWidth] as? Int == k.width,
              properties[kCGImagePropertyPixelHeight] as? Int == k.height,
              CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) != nil else { return false }
        return true
        }
    }
    private static func depthValid(_ row: [String: Any], k: CameraIntrinsics, root: URL) -> Bool {
        guard let name = row["depthFile"] as? String, basename(name),
              let confidenceName = row["confidenceFile"] as? String, basename(confidenceName),
              let w = row["depthWidth"] as? Int, let h = row["depthHeight"] as? Int,
              w > 0, h > 0, w <= min(k.width,8192), h <= min(k.height,8192),
              abs(Double(w)/Double(h) - Double(k.width)/Double(k.height)) < 0.01,
              let depthURL = try? file("depth/"+name,in:root), let confidenceURL = try? file("depth/"+confidenceName,in:root),
              let depth = try? Data(contentsOf:depthURL), let confidence = try? Data(contentsOf:confidenceURL),
              depth.count == w*h*4, confidence.count == w*h, confidence.allSatisfy({ $0 <= 2 }) else { return false }
        var valid = 0
        depth.withUnsafeBytes { bytes in
            for i in 0..<(w*h) {
                let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset:i*4,as:UInt32.self)))
                if value.isFinite, value > 0, confidence[i] >= 1 { valid += 1 }
            }
        }
        return valid >= max(1,w*h/100)
    }
    private static func depthMatches(_ row: [String: Any], frame: [String: Any], root: URL) -> Bool {
        guard row["depthWidth"] as? Int == frame["depthWidth"] as? Int,
              row["depthHeight"] as? Int == frame["depthHeight"] as? Int else { return false }
        for key in ["depthFile", "confidenceFile"] {
            guard let name = row[key] as? String, let path = frame[key] as? String,
                  let a = try? Data(contentsOf: file("depth/"+name,in:root)),
                  let b = try? Data(contentsOf: file(path,in:root)), a == b else { return false }
        }
        return true
    }
    private static func write(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    private static func writeRows(_ rows: [[String: Any]], to url: URL) throws {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject:row,options:.sortedKeys)); data.append(10) }
        try data.write(to:url,options:.atomic)
    }
    private static func copy(_ path: String, from source: URL, to destination: URL) throws {
        let input = try file(path,in:source), output = destination.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        do { try FileManager.default.linkItem(at: input, to: output) } catch { try FileManager.default.copyItem(at: input, to: output) }
    }

    /// Minimal downstream contract: every saved original ARKit image and its camera metadata.
    static func stageARKit(directory: URL, to destination: URL, includeLiDAR: Bool,
                           finishingCapture: Bool = false, sampleOnly: Bool = false,
                           progress: @Sendable (SceneExportProgress) -> Void = { _ in }) throws {
        let fm = FileManager.default
        let poseData = try Data(contentsOf: file("poses.jsonl", in: directory))
        let frameData = try Data(contentsOf: file("frames.jsonl", in: directory))
        guard let metadata = CaptureMetadata.data(in: directory),
              let meta = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              meta["cameraConvention"] as? String == "arkit_gl_c2w_row_major",
              meta["worldAlignment"] as? String == "gravity",
              (meta["streamCapture"] as? [String: Any])?["status"] as? String == "complete",
              (try (finishingCapture || json(file("capture-processing.json", in: directory))["status"] as? String == "completed")) else {
            throw fail(L10n.text("采集未完成，请保留原始数据并重试。"))
        }
        var stream: [Double: [String: Any]] = [:], frameIDs = Set<Int>()
        for frame in try rows(frameData) {
            guard let time = frame["timestamp"] as? Double, time.isFinite,
                  let id = frame["frameID"] as? Int, frameIDs.insert(id).inserted,
                  stream.updateValue(frame, forKey: time) == nil else { throw fail("invalid continuous frame index") }
        }
        var poses: [[String: Any]] = [], frames: [[String: Any]] = []
        var ids = Set<Int>(), names = Set<String>(), copies: [(String, String)] = []
        let originalRows = try rows(poseData)
        for (index, row) in originalRows.enumerated() {
            if index % 16 == 0 { progress(SceneExportProgress(fraction: 0.3 * Double(index) / Double(max(1, originalRows.count)), message: L10n.text("正在检查场景文件…"))) }
            try Task.checkCancellation()
            guard let id = row["id"] as? Int, ids.insert(id).inserted,
                  let name = row["imageFile"] as? String, basename(name), names.insert(name).inserted,
                  name.lowercased().hasSuffix(".jpg"),
                  let time = row["timestamp"] as? Double, time.isFinite else { throw fail("invalid keyframe correspondence") }
            guard validCamera(row), let k = calibration(row["intrinsics"]),
                  let frame = stream[time],
                  frame["transform"] as? [Double] == row["transform"] as? [Double],
                  let streamK = calibration(frame["intrinsics"]),
                  streamK.fx == k.fx, streamK.fy == k.fy, streamK.cx == k.cx, streamK.cy == k.cy,
                  streamK.width == k.width, streamK.height == k.height,
                  imageValid(name, k: k, root: directory) else { throw fail("missing or invalid original frame; full-frame export cannot silently exclude it") }
            var linked: [String: Any] = ["id": id, "sourceFrameID": frame["frameID"]!, "timestamp": time, "imageFile": name,
                "trackingState": frame["trackingState"] ?? "unknown", "videoWritten": frame["videoWritten"] ?? false]
            if let reason = frame["dropReason"] { linked["videoDropReason"] = reason }
            if includeLiDAR {
                if row["depthFile"] != nil || row["confidenceFile"] != nil {
                    guard let sourceDepth = row["depthFile"] as? String, basename(sourceDepth),
                          let sourceConfidence = row["confidenceFile"] as? String, basename(sourceConfidence),
                          let w = row["depthWidth"] as? Int, let h = row["depthHeight"] as? Int,
                          w > 0, h > 0, w <= 8192, h <= 8192,
                          try Data(contentsOf: file("depth/" + sourceDepth, in: directory)).count == w*h*4,
                          try Data(contentsOf: file("depth/" + sourceConfidence, in: directory)).count == w*h else {
                        throw fail("incomplete original depth pair; full-frame export cannot silently exclude it")
                    }
                    let depthName = "frame_\(id).f32", confidenceName = "frame_\(id).u8"
                    copies.append(("depth/" + sourceDepth, "depth/" + depthName))
                    copies.append(("depth/" + sourceConfidence, "depth/" + confidenceName))
                    linked["depthFile"] = "depth/" + depthName; linked["confidenceFile"] = "depth/" + confidenceName
                    linked["depthWidth"] = w; linked["depthHeight"] = h
                    linked["depthCalibrationPoseFile"] = "arkit/poses.jsonl"
                    linked["depthStatus"] = "present"
                } else { linked["depthStatus"] = "not_captured" }
            }
            var pose = addExtrinsics(row)
            for key in ["depthFile", "confidenceFile", "depthWidth", "depthHeight"] { pose.removeValue(forKey: key) }
            poses.append(pose); frames.append(linked); copies.append(("images/" + name, "images/" + name))
        }
        guard !poses.isEmpty else { throw fail(L10n.text("没有可导出的有效帧。")) }
        let sourceCount = poses.count
        if sampleOnly {
            let selected = halfSecondFrames(frames)
            let selectedIDs = Set(selected.map { $0["id"] as! Int })
            frames = selected
            poses = poses.filter { selectedIDs.contains($0["id"] as! Int) }
            var paths = Set(selected.map { "images/" + ($0["imageFile"] as! String) })
            for frame in selected {
                for key in ["depthFile", "confidenceFile"] { if let path = frame[key] as? String { paths.insert(path) } }
            }
            copies = copies.filter { paths.contains($0.1) }
        }
        try fm.createDirectory(at: destination.appendingPathComponent("arkit"), withIntermediateDirectories: true)
        for (index, pair) in copies.enumerated() {
            let (source, target) = pair
            if index % 16 == 0 { progress(SceneExportProgress(fraction: 0.3 + 0.18 * Double(index) / Double(max(1, copies.count)), message: L10n.text("正在整理导出文件…"))) }
            try Task.checkCancellation()
            let input = try file(source, in: directory), output = destination.appendingPathComponent(target)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.linkItem(at: input, to: output) } catch { try fm.copyItem(at: input, to: output) }
        }
        try writeRows(poses, to: destination.appendingPathComponent("arkit/poses.jsonl"))
        try writeRows(frames, to: destination.appendingPathComponent("arkit/frames.jsonl"))
        var manifest: [String: Any] = [
            "schemaVersion": 8, "kind": "beta-arkit-scene", "sceneID": directory.lastPathComponent,
            "sceneName": SceneInfo.read(in: directory)?.name ?? directory.lastPathComponent,
            "frameCount": poses.count, "imagesDirectory": "images", "poseFile": "arkit/poses.jsonl",
            "frameFile": "arkit/frames.jsonl", "includesLiDAR": includeLiDAR,
            "poseSource": "arkit_metric", "metricScale": true, "unit": "meters",
            "worldCoordinates": "original ARKit world, meters, gravity-aligned Y-up",
            "cameraConvention": "OpenGL c2w row-major; explicit GL/OpenCV w2c",
            "pathBase": "package_root; imageFile is relative to imagesDirectory; depthFile and confidenceFile are relative to package_root",
            "depthEncoding": "little-endian Float32, row-major, meters, axial camera Z; invalid samples may be nonfinite or nonpositive",
            "confidenceEncoding": "UInt8, row-major, 0=low 1=medium 2=high",
            "depthCalibration": "Use original ARKit K scaled to depth dimensions; no image rotation or reprojection applied",
            "selectionPolicy": "all saved original frames; no temporal, motion, tracking, blur or depth-quality subsampling; invalid or missing required files fail the export",
            "frameRetentionPolicy": "all_saved_frames", "sourceFrameCount": sourceCount,
            "sampledPackageDirectory": "sampled_0.5s",
            "sourcePosesSHA256": hash(poseData), "sourceFramesSHA256": hash(frameData),
            "exportedAt": ISO8601DateFormatter().string(from: Date())]
        if sampleOnly {
            manifest.removeValue(forKey: "sampledPackageDirectory")
            manifest["frameRetentionPolicy"] = "time_interval_0.5_seconds"
            manifest["samplingIntervalSeconds"] = 0.5
            manifest["selectionPolicy"] = "first saved frame, then first frame at least 0.5 seconds after last selected frame"
        }
        try write(manifest, to: destination.appendingPathComponent("scene-package.json"))
        if !sampleOnly {
            try stageHalfSecondSample(in: destination, poses: poses, frames: frames, manifest: manifest, source: directory)
        }
        guard try Data(contentsOf: file("poses.jsonl", in: directory)) == poseData,
              try Data(contentsOf: file("frames.jsonl", in: directory)) == frameData,
              CaptureMetadata.data(in: directory) == metadata else { throw fail("source changed during export") }
    }

    /// Called only for a newly finished capture, never while opening existing scenes.
    static func prepareCaptureSample(directory: URL, includeLiDAR: Bool) throws {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent("sampled_0.5s", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw fail("sample already exists; original output will not be overwritten") }
        let staging = directory.appendingPathComponent(".sampled-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try stageARKit(directory: directory, to: staging, includeLiDAR: includeLiDAR, finishingCapture: true, sampleOnly: true)
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
    }

    private static func halfSecondFrames(_ frames: [[String: Any]]) -> [[String: Any]] {
        let ordered = frames.sorted { ($0["timestamp"] as! Double) < ($1["timestamp"] as! Double) }
        var selected: [[String: Any]] = []
        var lastTime: Double?
        for frame in ordered {
            let time = frame["timestamp"] as! Double
            if let lastTime, time - lastTime < 0.5 { continue }
            selected.append(frame); lastTime = time
        }
        return selected
    }

    /// New captures reuse their completed sample; legacy scenes are sampled only in export staging.
    private static func stageHalfSecondSample(in full: URL, poses: [[String: Any]],
                                            frames: [[String: Any]], manifest: [String: Any], source: URL) throws {
        let posesByID = Dictionary(uniqueKeysWithValues: poses.map { ($0["id"] as! Int, $0) })
        let cache = source.appendingPathComponent("sampled_0.5s")
        var selected: [[String: Any]]
        if FileManager.default.fileExists(atPath: cache.path) {
            let cachedManifest = try json(file("scene-package.json", in: cache))
            guard cachedManifest["sourcePosesSHA256"] as? String == manifest["sourcePosesSHA256"] as? String,
                  cachedManifest["sourceFramesSHA256"] as? String == manifest["sourceFramesSHA256"] as? String,
                  cachedManifest["samplingIntervalSeconds"] as? Double == 0.5 else { throw fail("stale capture sample") }
            selected = try rows(Data(contentsOf: file("arkit/frames.jsonl", in: cache)))
            let byID = Dictionary(uniqueKeysWithValues: frames.map { ($0["id"] as! Int, $0) })
            let cachedIDs = selected.compactMap { $0["id"] as? Int }
            guard !cachedIDs.isEmpty, cachedIDs.count == selected.count, Set(cachedIDs).count == cachedIDs.count,
                  cachedIDs.allSatisfy({ byID[$0] != nil }), cachedManifest["frameCount"] as? Int == selected.count else { throw fail("invalid capture sample") }
            // Respect the current export depth toggle without changing the persisted sample.
            selected = cachedIDs.map { byID[$0]! }
        } else { selected = halfSecondFrames(frames) }
        let destination = full.appendingPathComponent("sampled_0.5s", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("arkit"), withIntermediateDirectories: true)
        let selectedPoses = selected.map { posesByID[$0["id"] as! Int]! }
        for frame in selected {
            try Task.checkCancellation()
            try copy("images/" + (frame["imageFile"] as! String), from: full, to: destination)
            for key in ["depthFile", "confidenceFile"] {
                if let path = frame[key] as? String { try copy(path, from: full, to: destination) }
            }
        }
        try writeRows(selectedPoses, to: destination.appendingPathComponent("arkit/poses.jsonl"))
        try writeRows(selected, to: destination.appendingPathComponent("arkit/frames.jsonl"))
        var sampledManifest = manifest
        sampledManifest.removeValue(forKey: "sampledPackageDirectory")
        sampledManifest["frameCount"] = selected.count
        sampledManifest["frameRetentionPolicy"] = "time_interval_0.5_seconds"
        sampledManifest["selectionPolicy"] = "first saved frame, then first frame at least 0.5 seconds after last selected frame; no additional quality filtering"
        sampledManifest["samplingIntervalSeconds"] = 0.5
        sampledManifest["samplingTimestampSource"] = "original ARFrame.timestamp, seconds since device boot"
        sampledManifest["sourcePackage"] = "parent full-frame package; this package is independently readable"
        try write(sampledManifest, to: destination.appendingPathComponent("scene-package.json"))
    }

    static func stage(directory: URL, to destination: URL, includeLiDAR: Bool) throws {
        let fm = FileManager.default
        let isVideo = fm.fileExists(atPath:directory.appendingPathComponent("video-import.json").path)
        let sourceData = try Data(contentsOf:file("poses.jsonl",in:directory))
        let originals = try rows(sourceData)
        guard !originals.isEmpty else { throw fail(L10n.text("没有可导出的有效帧。")) }
        var estimated: [Int: [String: Any]] = [:], stream: [Double: [String: Any]] = [:]
        var nativeEstimated: [Int: [String: Any]] = [:]
        var report: [String: Any] = [:]
        var rejectedIDs = Set<Int>(), droppedIDs: [Int] = []
        var sourceHashes: [String: String] = ["poses.jsonl":hash(sourceData)]
        if isVideo {
            let data = try Data(contentsOf:file("video-import.json",in:directory))
            guard let value = try JSONSerialization.jsonObject(with:data) as? [String: Any],
                  value["metricScale"] as? Bool == false,
                  value["unit"] as? String == "arbitrary_photogrammetry_unit_normalized" else { throw fail("invalid video import coordinates") }
            sourceHashes["video-import.json"] = hash(data)
        } else {
            guard let metaData = CaptureMetadata.data(in:directory),
                  let meta = try JSONSerialization.jsonObject(with:metaData) as? [String: Any],
                  meta["cameraConvention"] as? String == "arkit_gl_c2w_row_major", meta["worldAlignment"] as? String == "gravity",
                  (meta["streamCapture"] as? [String: Any])?["status"] as? String == "complete" else {
                throw fail(L10n.text("采集未完成，请保留原始数据并重试。"))
            }
            let state = try json(file("capture-processing.json",in:directory))
            guard state["status"] as? String == "completed" else { throw fail(L10n.text("采集未完成，请保留原始数据并重试。")) }
            guard let value = try? json(file("camera-estimation.json",in:directory)) else {
                throw fail(L10n.text("请先完成相机估计与米制配准，或选择原始归档。"))
            }
            if value["status"] as? String == "alignment_rejected" {
                throw fail(L10n.text("RealityKit 已返回结果，但坐标配准未完成。请重新估计相机参数；原始结果仍保留。"))
            }
            guard value["status"] as? String == "estimated_aligned",
                  value["sourcePosesSHA256"] as? String == hash(sourceData), let cameraFile = value["cameraFile"] as? String,
                  let rawCameraFile = value["rawCameraFile"] as? String else {
                throw fail(L10n.text("请先完成相机估计与米制配准，或选择原始归档。"))
            }
            report = value
            sourceHashes["camera-estimation.json"] = hash(try Data(contentsOf:file("camera-estimation.json",in:directory)))
            rejectedIDs = Set((report["alignment"] as? [String: Any])?["rejectedIDs"] as? [Int] ?? [])
            let camerasData = try Data(contentsOf:file(cameraFile,in:directory)); sourceHashes[cameraFile] = hash(camerasData)
            for row in try rows(camerasData) {
                guard let id = row["id"] as? Int, estimated.updateValue(row,forKey:id) == nil else { throw fail("duplicate estimated ID") }
            }
            guard report["estimatedFrameCount"] as? Int == estimated.count else { throw fail("estimated count mismatch") }
            guard let inliers = (report["alignment"] as? [String: Any])?["inlierIDs"] as? [Int],
                  inliers.count == Set(inliers).count, Set(inliers).isDisjoint(with:rejectedIDs),
                  report["worldCoordinates"] as? String == "original ARKit world, meters, gravity-aligned Y-up" else { throw fail("alignment membership or coordinates mismatch") }
            let fitOnly = report["alignmentPolicy"] as? String == "global_similarity_fit_outliers_retained"
            guard (fitOnly ? Set(inliers).union(rejectedIDs) : Set(inliers)) == Set(estimated.keys) else { throw fail("alignment membership mismatch") }
            let nativeData = try Data(contentsOf:file(rawCameraFile,in:directory)); sourceHashes[rawCameraFile] = hash(nativeData)
            guard let nativeRows = try JSONSerialization.jsonObject(with:nativeData) as? [[String: Any]] else { throw fail("invalid native cameras") }
            for row in nativeRows {
                guard let id = row["sampleID"] as? Int, nativeEstimated.updateValue(row,forKey:id) == nil else { throw fail("duplicate native camera ID") }
            }
            let data = try Data(contentsOf:file("frames.jsonl",in:directory)); sourceHashes["frames.jsonl"] = hash(data)
            var frameIDs = Set<Int>()
            for row in try rows(data) {
                guard let timestamp = row["timestamp"] as? Double, timestamp.isFinite,
                      let id = row["frameID"] as? Int, frameIDs.insert(id).inserted,
                      row["videoWritten"] as? Bool != nil, stream.updateValue(row,forKey:timestamp) == nil else { throw fail("invalid continuous frame index") }
                if row["videoWritten"] as? Bool != true || row["dropReason"] != nil { droppedIDs.append(id) }
            }
        }
        var ids = Set<Int>(), names = Set<String>(), accepted: [Int] = [], excluded: [[String: Any]] = []
        var arkitRows: [[String: Any]] = [], cameraRows: [[String: Any]] = [], frameRows: [[String: Any]] = []
        var copies: [String] = []
        for row in originals {
            try Task.checkCancellation()
            guard let id = row["id"] as? Int, ids.insert(id).inserted,
                  let name = row["imageFile"] as? String, names.insert(name).inserted,
                  let time = row["timestamp"] as? Double, time.isFinite else { throw fail("invalid source correspondence") }
            func reject(_ reason: String) { excluded.append(["id":id,"reason":reason]) }
            guard row["blurVerdict"] as? String == nil || row["blurVerdict"] as? String == "keep" else { reject("quality_rejected"); continue }
            guard validCamera(row), let k = calibration(row["intrinsics"]) else { reject("invalid_arkit_or_source_camera"); continue }
            var camera = row, linkedFrame: [String: Any] = ["id":id,"timestamp":time,"imageFile":name]
            if !isVideo {
                guard let frame = stream[time] else { reject("missing_continuous_frame"); continue }
                guard frame["videoWritten"] as? Bool == true, frame["dropReason"] == nil else { reject("video_frame_dropped"); continue }
                guard frame["trackingState"] as? String == "normal" else { reject("tracking_not_normal"); continue }
                guard let candidate = estimated[id] else { reject(rejectedIDs.contains(id) ? "alignment_rejected" : "photogrammetry_missing"); continue }
                guard candidate["imageFile"] as? String == name, candidate["timestamp"] as? Double == time,
                      validCamera(candidate), let targetK = calibration(candidate["intrinsics"]), targetK.width == k.width, targetK.height == k.height,
                      let originalK = calibration(candidate["originalIntrinsics"]), originalK.fx == k.fx, originalK.fy == k.fy, originalK.cx == k.cx, originalK.cy == k.cy, originalK.width == k.width, originalK.height == k.height,
                      let native = nativeEstimated[id], native["imageFile"] as? String == name, native["timestamp"] as? Double == time,
                      frame["transform"] as? [Double] == row["transform"] as? [Double],
                      let streamK = calibration(frame["intrinsics"]), streamK.fx == k.fx, streamK.fy == k.fy, streamK.cx == k.cx, streamK.cy == k.cy, streamK.width == k.width, streamK.height == k.height else { reject("camera_correspondence_invalid"); continue }
                camera = candidate; linkedFrame["sourceFrameID"] = frame["frameID"]
            }
            guard imageValid(name,k:k,root:directory) else { reject("image_missing_or_invalid"); continue }
            if includeLiDAR && !isVideo {
                guard depthValid(row,k:k,root:directory), depthMatches(row,frame:stream[time]!,root:directory) else { reject("depth_missing_or_invalid"); continue }
                for key in ["depthFile","confidenceFile"] {
                    let path = "depth/" + (row[key] as! String); linkedFrame[key] = path; copies.append(path)
                }
                linkedFrame["depthWidth"] = row["depthWidth"]; linkedFrame["depthHeight"] = row["depthHeight"]
                linkedFrame["depthCalibrationPoseFile"] = "arkit/poses.jsonl"
            }
            var original = addExtrinsics(row)
            // Depth references live only in frames.jsonl, with an explicit native calibration.
            for key in ["depthFile","confidenceFile","depthWidth","depthHeight"] { original.removeValue(forKey:key); camera.removeValue(forKey:key) }
            accepted.append(id); copies.append("images/"+name); frameRows.append(linkedFrame)
            if !isVideo { arkitRows.append(original) }
            cameraRows.append(addExtrinsics(camera))
        }
        guard !accepted.isEmpty else { throw fail(L10n.text("没有可导出的有效帧。")) }
        guard isVideo || Set(estimated.keys).isSubset(of:ids) else { throw fail("unknown estimated camera") }
        try fm.createDirectory(at:destination,withIntermediateDirectories:true)
        for path in Set(copies).sorted() { try Task.checkCancellation(); try copy(path,from:directory,to:destination) }
        let poseFile = isVideo ? "poses.jsonl" : "realitykit/poses.jsonl"
        if !isVideo {
            for folder in ["arkit","realitykit"] { try fm.createDirectory(at:destination.appendingPathComponent(folder),withIntermediateDirectories:true) }
            try writeRows(arkitRows,to:destination.appendingPathComponent("arkit/poses.jsonl"))
            try write(accepted.map { nativeEstimated[$0]! },to:destination.appendingPathComponent("realitykit/native-cameras.json"))
            let alignment: [String: Any] = ["schemaVersion":1,"method":"global_similarity","direction":"realitykit_native_world_to_arkit_world",
                "scaleReference":"original ARKit camera trajectory","worldCoordinates":report["worldCoordinates"]!,
                "coordinateAdaptation":report["coordinateAdaptation"] ?? NSNull(),
                "result":report["alignment"] ?? NSNull(),"appliedTo":"realitykit/poses.jsonl",
                "transformAlreadyApplied":true,"statisticsScope":"all source correspondences for v2 reports; robust fit subset for v1",
                "sourceReportSchemaVersion":report["schemaVersion"] ?? 1,
                "policy":report["alignmentPolicy"] ?? "legacy_inliers_only",
                "accuracy":"ARKit is a coordinate and scale reference, not ground truth; this is not a ranking of accuracy"]
            try write(alignment,to:destination.appendingPathComponent("alignment.json"))
        }
        try writeRows(cameraRows,to:destination.appendingPathComponent(poseFile))
        try writeRows(frameRows,to:destination.appendingPathComponent("frames.jsonl"))
        let selection: [String: Any] = ["schemaVersion":1,"acceptedFrameIDs":accepted,"excludedFrames":excluded,
            "droppedContinuousFrameIDs":droppedIDs,"sourceFileSHA256":sourceHashes,
            "inputFrameCount":originals.count,"outputFrameCount":accepted.count,"originalCapturePreserved":true,
            "usedDepthInEstimation":!(report["depthFrameIDs"] as? [Int] ?? []).isEmpty,
            "sourceAlignment":report["alignment"] ?? NSNull(),
            "policy":isVideo ? "valid prepared camera AND saved image AND keep quality" : "common valid cameras AND saved image AND videoWritten AND normal tracking AND keep quality; complete same-frame depth pair when requested; v2 registration fit exclusions are not frame exclusions"]
        try write(selection,to:destination.appendingPathComponent("selection.json"))
        for path in ["scene-info.json","scene-location.json"] where fm.fileExists(atPath:directory.appendingPathComponent(path).path) {
            try copy(path,from:directory,to:destination)
        }
        let manifest: [String: Any] = ["schemaVersion":5,"kind":"beta-reconstruction-scene","sceneID":directory.lastPathComponent,
            "frameCount":accepted.count,"imagesDirectory":"images","poseFile":poseFile,
            "arkitPoseFile":isVideo ? NSNull() : "arkit/poses.jsonl",
            "realitykitPoseFile":isVideo ? NSNull() : "realitykit/poses.jsonl",
            "realitykitNativeCameraFile":isVideo ? NSNull() : "realitykit/native-cameras.json",
            "alignmentFile":isVideo ? NSNull() : "alignment.json",
            "pathBase":"package_root; imageFile is relative to imagesDirectory",
            "frameFile":"frames.jsonl","selectionFile":"selection.json",
            "filteredFramesOnly":true,"includesLiDAR":includeLiDAR && !isVideo,"videos":[],"includesUnfilteredPointCloud":false,
            "metricScale":!isVideo,"worldCoordinates":isVideo ? "photogrammetry normalized, arbitrary scale" : "original ARKit world, meters, gravity-aligned Y-up",
            "cameraConvention":"OpenGL c2w row-major; explicit GL/OpenCV w2c",
            "poseSource":isVideo ? "photogrammetry_arbitrary_scale" : "realitykit_aligned_to_arkit_metric",
            "depthCalibration":"Use original ARKit K scaled to depth dimensions; never substitute estimated RGB K",
            "exportedAt":ISO8601DateFormatter().string(from:Date())]
        try write(manifest,to:destination.appendingPathComponent("scene-package.json"))
        for (path, expected) in sourceHashes {
            guard hash(try Data(contentsOf:file(path,in:directory))) == expected else { throw fail("source changed during export") }
        }
    }
}
