// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Synthetic export-policy tests; these do not measure camera accuracy.
enum BetaFilteredExportTests {
    static func check(_ value: Bool, _ message: String) throws { try BetaSceneTests.expect(value,message) }
    static func json(_ value: Any, _ url: URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:url,options:.atomic)
    }
    static func rows(_ values: [[String: Any]], _ url: URL) throws {
        var data = Data()
        for value in values { data.append(try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)); data.append(10) }
        try data.write(to:url,options:.atomic)
    }
    static func read(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String: Any] }
    static func readRows(_ url: URL) throws -> [[String: Any]] {
        try Data(contentsOf:url).split(separator:10).map { try JSONSerialization.jsonObject(with:Data($0)) as! [String: Any] }
    }
    static func hash(_ url: URL) throws -> String { SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined() }
    static func hashes(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for case let url as URL in FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])! {
            if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { result[url.path] = try hash(url) }
        }
        return result
    }
    static func jpeg() throws -> Data {
        let context = CGContext(data:nil,width:16,height:12,bitsPerComponent:8,bytesPerRow:16*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:0.8,alpha:1)); context.fill(CGRect(x:0,y:0,width:16,height:12))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil)
        try check(CGImageDestinationFinalize(destination),"fixture JPEG encoding")
        return data as Data
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("filtered-export-"+UUID().uuidString)
        defer { try? fm.removeItem(at:root) }
        let scene = root.appendingPathComponent("scan_policy")
        for path in ["images","depth/continuous","camera-estimation/test"] {
            try fm.createDirectory(at:scene.appendingPathComponent(path),withIntermediateDirectories:true)
        }
        let pixels = try jpeg(), depth = Data((0..<12).flatMap { _ in [UInt8(0),0,128,63] }), confidence = Data(repeating:2,count:12)
        let k: [String: Any] = ["fx":12.0,"fy":12.0,"cx":8.0,"cy":6.0,"width":16,"height":12]
        var originals: [[String: Any]] = [], cameras: [[String: Any]] = [], frames: [[String: Any]] = []
        for id in 1...12 {
            let matrix: [Double] = [1,0,0,Double(id)/10,0,1,0,0,0,0,1,0,0,0,0,1]
            var row: [String: Any] = ["id":id,"timestamp":Double(id),"imageFile":"\(id).jpg","transform":matrix,"intrinsics":k,
                "depthFile":"\(id).f32","confidenceFile":"\(id).u8","depthWidth":4,"depthHeight":3,"blurVerdict":"keep"]
            var frame: [String: Any] = ["frameID":id*10,"timestamp":Double(id),"transform":matrix,"intrinsics":k,
                "videoWritten":true,"trackingState":"normal","depthFile":"depth/continuous/\(id).f32",
                "confidenceFile":"depth/continuous/\(id).u8","depthWidth":4,"depthHeight":3]
            var camera = row; camera["originalIntrinsics"] = k
            if id == 5 { var different = matrix; different[3] += 3; camera["transform"] = different }
            if id == 3 { frame["videoWritten"] = false; frame["dropReason"] = "media_backpressure" }
            if id == 6 { frame["trackingState"] = "limited" }
            if id == 10 { row["blurVerdict"] = "demote" }
            if id == 11 { camera["timestamp"] = 0.0 }
            if id == 12 { row["transform"] = [Double](repeating:0,count:16) }
            originals.append(row); frames.append(frame)
            if id != 4 { cameras.append(camera) }
            try (id == 7 ? Data("bad JPEG".utf8) : pixels).write(to:scene.appendingPathComponent("images/\(id).jpg"))
            for prefix in ["depth/","depth/continuous/"] {
                try depth.write(to:scene.appendingPathComponent(prefix+"\(id).f32"))
                try confidence.write(to:scene.appendingPathComponent(prefix+"\(id).u8"))
            }
        }
        try fm.removeItem(at:scene.appendingPathComponent("depth/8.f32"))
        try Data(repeating:3,count:12).write(to:scene.appendingPathComponent("depth/9.u8"))
        try rows(originals,scene.appendingPathComponent("poses.jsonl")); try rows(frames,scene.appendingPathComponent("frames.jsonl"))
        try rows(cameras,scene.appendingPathComponent("camera-estimation/test/cameras.jsonl"))
        try pixels.write(to:scene.appendingPathComponent("images/unselected.jpg"))
        for path in ["color.mov","points.ply"] {
            try Data("original-only payload".utf8).write(to:scene.appendingPathComponent(path))
        }
        let native: [[String: Any]] = cameras.map { camera in
            ["sampleID":camera["id"]!,"imageFile":camera["imageFile"]!,"timestamp":camera["timestamp"]!,
             "transformColumnMajor":(0..<4).flatMap { c in (0..<4).map { r in (camera["transform"] as! [Double])[r*4+c] } }]
        }
        try json(native,scene.appendingPathComponent("camera-estimation/test/raw-cameras.json"))
        var stream = StreamCaptureMeta(); stream.status = "complete"; stream.videoSegments = ["color.mov"]
        let meta = SessionMeta(device:"fixture",osVersion:"fixture",startedAt:"2026-11-03T00:00:00Z",mode:"scene",lidarAvailable:true,lidarEnabled:true,streamCapture:stream)
        try JSONEncoder().encode(meta).write(to:scene.appendingPathComponent("capture-meta.json"))
        try json(["status":"completed"],scene.appendingPathComponent("capture-processing.json"))
        let reportURL = scene.appendingPathComponent("camera-estimation.json")
        var report: [String: Any] = ["schemaVersion":2,"alignmentPolicy":"global_similarity_fit_outliers_retained",
            "status":"estimated_aligned","cameraFile":"camera-estimation/test/cameras.jsonl","rawCameraFile":"camera-estimation/test/raw-cameras.json",
            "estimatedFrameCount":cameras.count,"sourcePosesSHA256":try hash(scene.appendingPathComponent("poses.jsonl")),
            "worldCoordinates":"original ARKit world, meters, gravity-aligned Y-up",
            "alignment":["inlierIDs":cameras.map { $0["id"] as! Int }.filter { $0 != 5 },"rejectedIDs":[5]],"depthFrameIDs":Array(1...12)]
        try json(report,reportURL)
        let before = try hashes(scene)
        let zip = try await BetaSceneArchive.shared.save(directory:scene,includeLiDAR:true)
        try BetaSceneTests.unpack(zip,to:root.appendingPathComponent("unpacked"))
        let output = root.appendingPathComponent("unpacked/scan_policy")
        for path in ["arkit/poses.jsonl","arkit/frames.jsonl","frames.jsonl"] {
            try check(try readRows(output.appendingPathComponent(path)).map { $0["id"] as! Int } == [1,2,4,5,10,11],"complete valid ARKit images: "+path)
        }
        for path in ["realitykit/poses.jsonl","realitykit/frames.jsonl"] {
            try check(try readRows(output.appendingPathComponent(path)).map { $0["id"] as! Int } == [1,2,5,10],"actual RealityKit results: "+path)
        }
        let outputNative = try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("realitykit/native-cameras.json"))) as! [[String: Any]]
        try check(outputNative.map { $0["sampleID"] as! Int } == [1,2,5,10],"native cameras must match estimated IDs")
        let ark = try readRows(output.appendingPathComponent("arkit/poses.jsonl")).first { $0["id"] as? Int == 5 }!["transform"] as! [Double]
        let rk = try readRows(output.appendingPathComponent("realitykit/poses.jsonl")).first { $0["id"] as? Int == 5 }!["transform"] as! [Double]
        try check(abs(rk[3]-ark[3]-3) < 1e-8,"registration outlier retained without snapping to ARKit")
        let manifest = try read(output.appendingPathComponent("scene-package.json"))
        try check(manifest["schemaVersion"] as? Int == 6 && manifest["poseFile"] as? String == "realitykit/poses.jsonl" && manifest["frameCount"] as? Int == 6 && manifest["poseFrameCount"] as? Int == 4,"independent camera count manifest")
        try check(try read(output.appendingPathComponent("alignment.json"))["transformAlreadyApplied"] as? Bool == true,"prevent double transform")
        let selection = try read(output.appendingPathComponent("selection.json"))
        let excluded = selection["excludedFrames"] as! [[String: Any]]
        let reasons = Dictionary(uniqueKeysWithValues:excluded.map { ($0["id"] as! Int,$0["reason"] as! String) })
        try check(reasons == [3:"video_frame_dropped",6:"tracking_not_normal",
            7:"image_missing_or_invalid",8:"depth_missing_or_invalid",9:"depth_missing_or_invalid",
            12:"invalid_arkit_or_source_camera"],"only invalid data is excluded")
        let unavailable = selection["realitykitUnavailableFrames"] as! [[String: Any]]
        try check(unavailable.map { $0["id"] as! Int } == [4,11],"missing estimates are audited without deleting valid photos")
        try check(selection["pairedFrameIDs"] as? [Int] == [1,2,5,10],"comparison subset is explicit")
        try check(selection["droppedContinuousFrameIDs"] as? [Int] == [30],"drop audit")
        try check(Set(try fm.contentsOfDirectory(atPath:output.path)) == Set(["images","depth","arkit","realitykit","alignment.json","frames.jsonl","selection.json","scene-package.json"]),"allowlist excludes unfiltered data")
        try check(try fm.contentsOfDirectory(atPath:output.appendingPathComponent("images").path).count == 6,"valid image missing or invalid image leaked")
        try check(try fm.contentsOfDirectory(atPath:output.appendingPathComponent("depth").path).count == 12,"depth availability must match image set")
        try check(try hashes(scene) == before,"export modified original data")
        let rgb = try await BetaSceneArchive.shared.save(directory:scene,includeLiDAR:false)
        try BetaSceneTests.unpack(rgb,to:root.appendingPathComponent("rgb"))
        let rgbOutput = root.appendingPathComponent("rgb/scan_policy")
        try check(!fm.fileExists(atPath:rgbOutput.appendingPathComponent("depth").path),"depth leaked into RGB-only export")
        for path in ["arkit/poses.jsonl","realitykit/poses.jsonl","frames.jsonl"] {
            let text = try String(contentsOf:rgbOutput.appendingPathComponent(path),encoding:.utf8)
            try check(!text.contains("depthFile") && !text.contains("confidenceFile"),"dangling depth reference")
        }
        try check(try read(rgbOutput.appendingPathComponent("selection.json"))["usedDepthInEstimation"] as? Bool == true,"depth estimation provenance")

        // No valid RealityKit correspondence must never replace ARKit with invented poses.
        let invalidCameras = cameras.map { row -> [String: Any] in var r = row; r["timestamp"] = -1.0; return r }
        try rows(invalidCameras,scene.appendingPathComponent("camera-estimation/test/cameras.jsonl"))
        let arkOnly = try await BetaSceneArchive.shared.save(directory:scene,includeLiDAR:true)
        try BetaSceneTests.unpack(arkOnly,to:root.appendingPathComponent("ark-only"))
        let arkOutput = root.appendingPathComponent("ark-only/scan_policy")
        let arkManifest = try read(arkOutput.appendingPathComponent("scene-package.json"))
        try check(arkManifest["poseFile"] as? String == "arkit/poses.jsonl" && arkManifest["realitykitFrameCount"] as? Int == 0,"explicit ARKit default when no estimated cameras survive")
        try check(try readRows(arkOutput.appendingPathComponent("arkit/poses.jsonl")).count == 6 && readRows(arkOutput.appendingPathComponent("realitykit/poses.jsonl")).isEmpty,"no overwrite or fabricated RealityKit camera")
        try rows(cameras,scene.appendingPathComponent("camera-estimation/test/cameras.jsonl"))

        // Independent native worlds must carry the transform for the exact producing batch.
        var batched = report
        batched.removeValue(forKey: "alignment")
        batched["schemaVersion"] = 4
        batched["batches"] = (0...1).map { batch in
            ["id": batch, "status": "estimated_aligned", "alignment": ["inlierIDs": cameras.compactMap { $0["id"] as? Int }.filter { $0 % 2 == batch }, "rejectedIDs": []]] as [String: Any]
        }
        let batchCameras = cameras.map { row -> [String: Any] in var r = row; r["estimationBatchID"] = (r["id"] as! Int) % 2; return r }
        let batchNative = native.map { row -> [String: Any] in var r = row; r["estimationBatchID"] = (r["sampleID"] as! Int) % 2; return r }
        try rows(batchCameras, scene.appendingPathComponent("camera-estimation/test/cameras.jsonl"))
        try json(batchNative, scene.appendingPathComponent("camera-estimation/test/raw-cameras.json"))
        try json(batched, reportURL)
        let batchZIP = try await BetaSceneArchive.shared.save(directory:scene,includeLiDAR:true)
        try BetaSceneTests.unpack(batchZIP,to:root.appendingPathComponent("batches"))
        let batchOutput = root.appendingPathComponent("batches/scan_policy")
        try check((try read(batchOutput.appendingPathComponent("alignment.json"))["batches"] as? [[String: Any]])?.count == 2, "all independent batch transforms are exported")
        try check(try readRows(batchOutput.appendingPathComponent("realitykit/poses.jsonl")).map { $0["id"] as! Int } == [1,2,5,10], "batch camera correspondence")
        var mismatched = batchCameras; mismatched[0]["estimationBatchID"] = 100
        try rows(mismatched, scene.appendingPathComponent("camera-estimation/test/cameras.jsonl"))
        do { _ = try await BetaSceneArchive.shared.save(directory:scene,includeLiDAR:true); throw NSError(domain:"unknown batch accepted",code:1) }
        catch is BetaReconstructionExport.ExportError { }
        try rows(cameras, scene.appendingPathComponent("camera-estimation/test/cameras.jsonl"))
        try json(native, scene.appendingPathComponent("camera-estimation/test/raw-cameras.json"))
        try json(report, reportURL)

        let exports = root.appendingPathComponent("exports")
        let exportCount = try fm.contentsOfDirectory(atPath:exports.path).count
        for bad in ["missing","stale","unsafe","membership"] {
            var invalid = report
            switch bad {
            case "missing": try fm.removeItem(at:reportURL)
            case "stale": invalid["sourcePosesSHA256"] = "wrong"; try json(invalid,reportURL)
            case "unsafe": invalid["cameraFile"] = "../outside.jsonl"; try json(invalid,reportURL)
            default: invalid["alignment"] = ["inlierIDs":[1],"rejectedIDs":[5]]; try json(invalid,reportURL)
            }
            do { _ = try await BetaSceneArchive.shared.save(directory:scene,includeLiDAR:true); throw NSError(domain:"invalid report accepted: "+bad,code:1) }
            catch is BetaReconstructionExport.ExportError { }
            try json(report,reportURL)
        }
        let second = root.appendingPathComponent("scan_incomplete")
        try fm.copyItem(at:scene,to:second); try fm.removeItem(at:second.appendingPathComponent("camera-estimation.json"))
        let entries = try await ScanLibrary(root:root).entries()
        do { _ = try await BetaSceneArchive.shared.saveBatch(entries:entries,includeLiDAR:true); throw NSError(domain:"partial batch published",code:1) }
        catch is BetaSceneArchive.ArchiveError { }
        try check(try fm.contentsOfDirectory(atPath:exports.path).count == exportCount,"failure published archive")
        try check(try !fm.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".beta-export-") },"staging leaked")

        // Ordinary video remains explicitly non-metric and has one camera set.
        let video = root.appendingPathComponent("scan_video")
        try fm.createDirectory(at:video.appendingPathComponent("images"),withIntermediateDirectories:true)
        for id in 1...2 { try pixels.write(to:video.appendingPathComponent("images/\(id).jpg")) }
        try rows(Array(originals.prefix(2)),video.appendingPathComponent("poses.jsonl"))
        try json(["metricScale":false,"unit":"arbitrary_photogrammetry_unit_normalized"],video.appendingPathComponent("video-import.json"))
        let videoZIP = try await BetaSceneArchive.shared.save(directory:video,includeLiDAR:false)
        try BetaSceneTests.unpack(videoZIP,to:root.appendingPathComponent("video"))
        let videoOutput = root.appendingPathComponent("video/scan_video")
        let videoManifest = try read(videoOutput.appendingPathComponent("scene-package.json"))
        try check(videoManifest["metricScale"] as? Bool == false && videoManifest["poseFile"] as? String == "poses.jsonl","video scale/camera semantics")
        try check(!fm.fileExists(atPath:videoOutput.appendingPathComponent("arkit").path),"invented ARKit parameters")

        // Valid reports with no surviving frames cannot fall back to original capture.
        for i in originals.indices { originals[i]["transform"] = [Double](repeating:0,count:16) }
        try rows(originals,scene.appendingPathComponent("poses.jsonl"))
        report["sourcePosesSHA256"] = try hash(scene.appendingPathComponent("poses.jsonl")); try json(report,reportURL)
        do { _ = try await BetaSceneArchive.shared.save(directory:scene,includeLiDAR:true); throw NSError(domain:"zero frames exported",code:1) }
        catch is BetaReconstructionExport.ExportError { }
        print("PASS: independent ARKit/RealityKit frame lists, missing estimates and quality annotations preserve photos, invalid/drop/depth exclusions, membership, original hashes, RGB policy, atomicity, non-metric video")
    }
}
