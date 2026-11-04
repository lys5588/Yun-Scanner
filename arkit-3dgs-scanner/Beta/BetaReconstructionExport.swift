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
        try FileManager.default.copyItem(at:input,to:output)
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
            guard report["worldCoordinates"] as? String == "original ARKit world, meters, gravity-aligned Y-up" else { throw fail("coordinates mismatch") }
            if let batches = report["batches"] as? [[String: Any]], batches.count > 1 {
                var byID: [Int: Set<Int>] = [:]
                for batch in batches {
                    guard let id = batch["id"] as? Int, byID[id] == nil else { throw fail("duplicate estimation batch") }
                    let result = batch["alignment"] as? [String: Any]
                    let inliers = result?["inlierIDs"] as? [Int] ?? []
                    let rejected = result?["rejectedIDs"] as? [Int] ?? []
                    guard Set(inliers).isDisjoint(with: Set(rejected)) else { throw fail("batch alignment membership mismatch") }
                    byID[id] = Set(inliers + rejected)
                }
                for (id, row) in estimated {
                    guard let batchID = row["estimationBatchID"] as? Int, byID[batchID]?.contains(id) == true else { throw fail("missing batch registration") }
                }
            } else {
                guard let inliers = (report["alignment"] as? [String: Any])?["inlierIDs"] as? [Int],
                      inliers.count == Set(inliers).count, Set(inliers).isDisjoint(with:rejectedIDs) else { throw fail("alignment membership mismatch") }
                let fitOnly = report["alignmentPolicy"] as? String == "global_similarity_fit_outliers_retained"
                guard (fitOnly ? Set(inliers).union(rejectedIDs) : Set(inliers)) == Set(estimated.keys) else { throw fail("alignment membership mismatch") }
            }
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
            if isVideo, let verdict = row["blurVerdict"] as? String, verdict != "keep" { reject("quality_rejected"); continue }
            guard validCamera(row), let k = calibration(row["intrinsics"]) else { reject("invalid_arkit_or_source_camera"); continue }
            var camera: [String: Any]? = isVideo ? row : nil
            var linkedFrame: [String: Any] = ["id":id,"timestamp":time,"imageFile":name]
            if !isVideo {
                guard let frame = stream[time] else { reject("missing_continuous_frame"); continue }
                guard frame["videoWritten"] as? Bool == true, frame["dropReason"] == nil else { reject("video_frame_dropped"); continue }
                guard frame["trackingState"] as? String == "normal" else { reject("tracking_not_normal"); continue }
                guard frame["transform"] as? [Double] == row["transform"] as? [Double],
                      let streamK = calibration(frame["intrinsics"]), streamK.fx == k.fx, streamK.fy == k.fy, streamK.cx == k.cx, streamK.cy == k.cy, streamK.width == k.width, streamK.height == k.height else { reject("camera_correspondence_invalid"); continue }
                linkedFrame["sourceFrameID"] = frame["frameID"]
                linkedFrame["arkitPoseAvailable"] = true
                linkedFrame["qualityVerdict"] = row["blurVerdict"] ?? "unclassified"
                linkedFrame["realitykitStatus"] = rejectedIDs.contains(id) ? "legacy_alignment_rejected" : "photogrammetry_missing"
                linkedFrame["realitykitIssue"] = (report["sampleIssues"] as? [String: String])?[String(id)]
                if let candidate = estimated[id] {
                    linkedFrame["realitykitStatus"] = "camera_correspondence_invalid"
                    if candidate["imageFile"] as? String == name, candidate["timestamp"] as? Double == time,
                      validCamera(candidate), let targetK = calibration(candidate["intrinsics"]), targetK.width == k.width, targetK.height == k.height,
                      let originalK = calibration(candidate["originalIntrinsics"]), originalK.fx == k.fx, originalK.fy == k.fy, originalK.cx == k.cx, originalK.cy == k.cy, originalK.width == k.width, originalK.height == k.height,
                      let native = nativeEstimated[id], native["imageFile"] as? String == name, native["timestamp"] as? Double == time,
                      native["estimationBatchID"] as? Int == candidate["estimationBatchID"] as? Int {
                        camera = candidate; linkedFrame["realitykitStatus"] = "estimated"
                    }
                }
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
            for key in ["depthFile","confidenceFile","depthWidth","depthHeight"] { original.removeValue(forKey:key); camera?.removeValue(forKey:key) }
            accepted.append(id); copies.append("images/"+name); frameRows.append(linkedFrame)
            if !isVideo { arkitRows.append(original) }
            if let camera { cameraRows.append(addExtrinsics(camera)) }
        }
        guard !accepted.isEmpty else { throw fail(L10n.text("没有可导出的有效帧。")) }
        guard isVideo || Set(estimated.keys).isSubset(of:ids) else { throw fail("unknown estimated camera") }
        try fm.createDirectory(at:destination,withIntermediateDirectories:true)
        for path in Set(copies).sorted() { try Task.checkCancellation(); try copy(path,from:directory,to:destination) }
        let realitykitIDs = cameraRows.compactMap { $0["id"] as? Int }
        let poseFile = isVideo ? "poses.jsonl" : (cameraRows.isEmpty ? "arkit/poses.jsonl" : "realitykit/poses.jsonl")
        if !isVideo {
            for folder in ["arkit","realitykit"] { try fm.createDirectory(at:destination.appendingPathComponent(folder),withIntermediateDirectories:true) }
            try writeRows(arkitRows,to:destination.appendingPathComponent("arkit/poses.jsonl"))
            try writeRows(frameRows,to:destination.appendingPathComponent("arkit/frames.jsonl"))
            try writeRows(frameRows.filter { $0["realitykitStatus"] as? String == "estimated" },to:destination.appendingPathComponent("realitykit/frames.jsonl"))
            try write(realitykitIDs.map { nativeEstimated[$0]! },to:destination.appendingPathComponent("realitykit/native-cameras.json"))
            let alignment: [String: Any] = ["schemaVersion":2,"method":"global_similarity","direction":"realitykit_native_world_to_arkit_world",
                "scaleReference":"original ARKit camera trajectory","worldCoordinates":report["worldCoordinates"]!,
                "coordinateAdaptation":report["coordinateAdaptation"] ?? NSNull(),
                "result":report["alignment"] ?? NSNull(),
                "batches": (report["batches"] as? [[String: Any]])?.map { batch in
                    batch.filter { !["rawCameraFile", "rawPointCloudFile"].contains($0.key) }
                } ?? [], "batchPolicy": report["batchPolicy"] ?? NSNull(), "appliedTo":"realitykit/poses.jsonl",
                "transformAlreadyApplied":true,"statisticsScope":"each batch has its own native world and transform; statistics are per batch; v1 uses robust fit subset",
                "sourceReportSchemaVersion":report["schemaVersion"] ?? 1,
                "policy":report["alignmentPolicy"] ?? "legacy_inliers_only",
                "accuracy":"ARKit is a coordinate and scale reference, not ground truth; this is not a ranking of accuracy"]
            try write(alignment,to:destination.appendingPathComponent("alignment.json"))
        }
        try writeRows(cameraRows,to:destination.appendingPathComponent(isVideo ? "poses.jsonl" : "realitykit/poses.jsonl"))
        try writeRows(frameRows,to:destination.appendingPathComponent("frames.jsonl"))
        let selection: [String: Any] = ["schemaVersion":2,"acceptedFrameIDs":accepted,"excludedFrames":excluded,
            "arkitFrameIDs":isVideo ? [] : accepted,"realitykitFrameIDs":isVideo ? [] : realitykitIDs,
            "pairedFrameIDs":isVideo ? [] : realitykitIDs,
            "realitykitUnavailableFrames":isVideo ? [] : frameRows.filter { $0["realitykitStatus"] as? String != "estimated" }.map { ["id":$0["id"]!,"reason":$0["realitykitStatus"]!] },
            "droppedContinuousFrameIDs":droppedIDs,"sourceFileSHA256":sourceHashes,
            "inputFrameCount":originals.count,"outputFrameCount":accepted.count,"originalCapturePreserved":true,
            "usedDepthInEstimation":!(report["depthFrameIDs"] as? [Int] ?? []).isEmpty,
            "photogrammetryInputFrameIDs":report["inputFrameIDs"] ?? NSNull(),
            "photogrammetrySubmittedFrameIDs":report["submittedFrameIDs"] ?? NSNull(),
            "sourceAlignment":report["alignment"] ?? NSNull(),
            "policy":isVideo ? "valid prepared camera AND saved image AND keep quality" : "all valid saved ARKit images; videoWritten AND normal tracking; complete same-frame depth pair when requested; quality is annotation; RealityKit availability does not remove ARKit images"]
        try write(selection,to:destination.appendingPathComponent("selection.json"))
        for path in ["scene-info.json","scene-location.json"] where fm.fileExists(atPath:directory.appendingPathComponent(path).path) {
            try copy(path,from:directory,to:destination)
        }
        let manifest: [String: Any] = ["schemaVersion":6,"kind":"beta-reconstruction-scene","sceneID":directory.lastPathComponent,
            "frameCount":accepted.count,"imagesDirectory":"images","poseFile":poseFile,
            "poseFrameCount":cameraRows.isEmpty ? arkitRows.count : cameraRows.count,
            "arkitFrameCount":arkitRows.count,"realitykitFrameCount":isVideo ? 0 : cameraRows.count,
            "cameraFramePolicy":"independent_lists; join by id, never by row number",
            "arkitPoseFile":isVideo ? NSNull() : "arkit/poses.jsonl",
            "realitykitPoseFile":isVideo ? NSNull() : "realitykit/poses.jsonl",
            "arkitFrameFile":isVideo ? NSNull() : "arkit/frames.jsonl",
            "realitykitFrameFile":isVideo ? NSNull() : "realitykit/frames.jsonl",
            "realitykitNativeCameraFile":isVideo ? NSNull() : "realitykit/native-cameras.json",
            "alignmentFile":isVideo ? NSNull() : "alignment.json",
            "pathBase":"package_root; imageFile is relative to imagesDirectory",
            "frameFile":"frames.jsonl","selectionFile":"selection.json",
            "filteredFramesOnly":true,"includesLiDAR":includeLiDAR && !isVideo,"videos":[],"includesUnfilteredPointCloud":false,
            "metricScale":!isVideo,"worldCoordinates":isVideo ? "photogrammetry normalized, arbitrary scale" : "original ARKit world, meters, gravity-aligned Y-up",
            "cameraConvention":"OpenGL c2w row-major; explicit GL/OpenCV w2c",
            "poseSource":isVideo ? "photogrammetry_arbitrary_scale" : (cameraRows.isEmpty ? "arkit_no_usable_realitykit_frames" : "realitykit_aligned_to_arkit_metric"),
            "depthCalibration":"Use original ARKit K scaled to depth dimensions; never substitute estimated RGB K",
            "exportedAt":ISO8601DateFormatter().string(from:Date())]
        try write(manifest,to:destination.appendingPathComponent("scene-package.json"))
        for (path, expected) in sourceHashes {
            guard hash(try Data(contentsOf:file(path,in:directory))) == expected else { throw fail("source changed during export") }
        }
    }
}
