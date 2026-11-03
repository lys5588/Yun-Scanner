// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import CryptoKit

/// Metadata-only fixtures exercise packaging, never camera/pose accuracy or video decoding.
@main struct BetaSceneTests {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func unpack(_ zip: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, "ZIP must unpack")
        let portable = Process()
        portable.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        portable.arguments = ["-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; assert all(i.flag_bits & 0x800 for i in z.infolist())", zip.path]
        try portable.run(); portable.waitUntilExit()
        try expect(portable.terminationStatus == 0, "portable UTF-8 ZIP headers and CRC")
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--reconstruction" {
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            print(try await BetaSceneArchive.shared.save(directory: source, includeLiDAR: true).path)
            return
        }
        try await BetaFilteredExportTests.run()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("beta-scene-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let scene = root.appendingPathComponent("beta-scenes/scan_test")
        try fm.createDirectory(at: scene.appendingPathComponent("images"), withIntermediateDirectories: true)
        try fm.createDirectory(at: scene.appendingPathComponent("depth/continuous"), withIntermediateDirectories: true)
        let pose = FrameRecord(id: 1, timestamp: 4,
            transform: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
            intrinsics: CameraIntrinsics(fx: 12, fy: 12, cx: 8, cy: 8, width: 16, height: 16),
            exposureDuration: 0.01, exposureOffsetEV: 0, estimatedBlurPx: 0,
            imageFile: "frame.jpg", depthFile: "frame.f32", confidenceFile: "frame.u8", depthWidth: 1, depthHeight: 1)
        let poses = try JSONEncoder().encode(pose) + Data([10])
        try poses.write(to: scene.appendingPathComponent("poses.jsonl"))
        try poses.write(to: scene.appendingPathComponent("review-poses.jsonl"))
        try poses.write(to: scene.appendingPathComponent("frames.jsonl"))
        try Data("test image bytes".utf8).write(to: scene.appendingPathComponent("images/frame.jpg"))
        try Data("test movie bytes".utf8).write(to: scene.appendingPathComponent("color.mov"))
        try Data([0,0,128,63]).write(to: scene.appendingPathComponent("depth/frame.f32"))
        try Data([2]).write(to: scene.appendingPathComponent("depth/frame.u8"))
        var stream = StreamCaptureMeta(); stream.status = "complete"; stream.videoSegments = ["color.mov"]
        var metadata = SessionMeta(device: "test", osVersion: "test", startedAt: "2026-10-27T00:00:00Z", mode: "scene", lidarAvailable: true, lidarEnabled: true, streamCapture: stream)
        let meta = try JSONEncoder().encode(metadata)
        try meta.write(to: scene.appendingPathComponent("capture-meta.json"))
        let estimated = Data("separate estimated cameras".utf8)
        try fm.createDirectory(at: scene.appendingPathComponent("camera-estimation/test"), withIntermediateDirectories: true)
        try estimated.write(to: scene.appendingPathComponent("camera-estimation/test/cameras-arkit.jsonl"))
        try fm.createDirectory(at: scene.appendingPathComponent(".camera-estimation-unfinished"), withIntermediateDirectories: false)
        let sourceHash = SHA256.hash(data: poses).map { String(format: "%02x", $0) }.joined()
        let estimateReport: [String: Any] = ["status": "estimated_aligned", "cameraFile": "camera-estimation/test/cameras-arkit.jsonl",
                                           "depthFrameIDs": [1], "sourcePosesSHA256": sourceHash]
        try JSONSerialization.data(withJSONObject: estimateReport).write(to: scene.appendingPathComponent("camera-estimation.json"))
        let library = ScanLibrary(root: root.appendingPathComponent("beta-scenes"))
        let other = ScanLibrary(root: root.appendingPathComponent("scans"))
        try expect(try await library.entries().count == 1, "beta entry missing")
        try expect(try await other.entries().isEmpty, "beta leaked into reconstruction library")
        let alias = root.appendingPathComponent("library-alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: scene.deletingLastPathComponent())
        let aliasScene = alias.appendingPathComponent("scan_test", isDirectory: true)
        try expect(try await library.entry(at: aliasScene).id == "scan_test", "directory alias must open the saved scene")
        do { _ = try await other.entry(at: aliasScene); throw NSError(domain: "accepted other library scene", code: 1) }
        catch ScanLibrary.LibraryError.invalidDirectory { }
        let rgb = try await BetaSceneArchive.shared.save(directory: scene, includeLiDAR: false, contents: .original)
        try unpack(rgb, to: root.appendingPathComponent("rgb"))
        let unpacked = root.appendingPathComponent("rgb/scan_test")
        try expect(fm.fileExists(atPath: unpacked.appendingPathComponent("color.mov").path), "movie missing")
        try expect(!fm.fileExists(atPath: unpacked.appendingPathComponent("depth").path), "depth leaked")
        let stripped = try String(contentsOf: unpacked.appendingPathComponent("poses.jsonl"), encoding: .utf8)
        try expect(!stripped.contains("depthFile") && !stripped.contains("confidenceFile"), "dangling depth reference")
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: unpacked.appendingPathComponent("scene-package.json"))) as! [String: Any]
        let estimate = package["cameraEstimation"] as! [String: Any]
        try expect(estimate["usedDepthInput"] as? Bool == true, "depth influence provenance lost on RGB export")
        try expect(estimate["sourcePosesSHA256BeforeExport"] as? String == sourceHash && estimate["exportedPosesSHA256"] as? String != sourceHash, "original and sanitized hashes")
        try expect(try Data(contentsOf: unpacked.appendingPathComponent("camera-estimation/test/cameras-arkit.jsonl")) == estimated, "separate estimate missing")
        try expect(!fm.fileExists(atPath: unpacked.appendingPathComponent(".camera-estimation-unfinished").path), "partial estimate leaked")
        try expect(try Data(contentsOf: scene.appendingPathComponent("poses.jsonl")) == poses, "original poses changed through hard links")
        try expect(try Data(contentsOf: scene.appendingPathComponent("capture-meta.json")) == meta, "original metadata changed")
        let lidar = try await BetaSceneArchive.shared.save(directory: scene, includeLiDAR: true, contents: .original)
        try unpack(lidar, to: root.appendingPathComponent("lidar"))
        try expect(fm.fileExists(atPath: root.appendingPathComponent("lidar/scan_test/depth/frame.f32").path), "LiDAR omitted")
        try expect(try Data(contentsOf: root.appendingPathComponent("lidar/scan_test/poses.jsonl")) == poses, "LiDAR poses changed")
        // Display names do not move source directories; locations are independent metadata.
        let location = SceneLocation(latitude: 31.2, longitude: 121.4, horizontalAccuracyMeters: 12,
                                     timestamp: Date(timeIntervalSince1970: 1_790_000_000), address: "TEST fixture location")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let locationData = try encoder.encode(location)
        try locationData.write(to: scene.appendingPathComponent("scene-location.json"))
        let firstEntry = try await library.entry(at: scene)
        try await library.rename(firstEntry, to: "  桌面/实验  ")
        let renamed = try await library.entry(at: scene)
        try expect(renamed.displayName == "桌面/实验" && renamed.id == firstEntry.id && renamed.location == location, "rename/location persistence")
        do { try await library.rename(renamed, to: "   "); throw NSError(domain: "blank name accepted", code: 1) }
        catch let e as NSError where e.domain == "SceneName" { }
        do { try await other.rename(renamed, to: "wrong library"); throw NSError(domain: "cross library rename accepted", code: 1) }
        catch ScanLibrary.LibraryError.invalidDirectory { }
        let second = scene.deletingLastPathComponent().appendingPathComponent("scan_second")
        try fm.copyItem(at: scene, to: second)
        var cameraOnly = metadata; cameraOnly.lidarEnabled = false
        try JSONEncoder().encode(cameraOnly).write(to: second.appendingPathComponent("capture-meta.json"), options: .atomic)
        try fm.removeItem(at: second.appendingPathComponent("depth"))
        let entries = try await library.entries()
        let batch = try await BetaSceneArchive.shared.saveBatch(entries: entries, includeLiDAR: true, contents: .original)
        try unpack(batch, to: root.appendingPathComponent("batch"))
        let batchRoot = root.appendingPathComponent("batch/Scenes")
        let batchIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: batchRoot.appendingPathComponent("batch-manifest.json"))) as! [String: Any]
        let sceneIndex = batchIndex["scenes"] as! [[String: Any]]
        try expect(Set(sceneIndex.compactMap { $0["folder"] as? String }) == Set(["桌面_实验", "桌面_实验 (2)"]), "safe unique folders")
        for item in sceneIndex {
            let folder = batchRoot.appendingPathComponent(item["folder"] as! String)
            try expect(try Data(contentsOf: folder.appendingPathComponent("color.mov")) == Data("test movie bytes".utf8), "batch video preserved")
            try expect(try Data(contentsOf: folder.appendingPathComponent("scene-location.json")) == locationData, "location not exported")
            try expect(fm.fileExists(atPath: folder.appendingPathComponent("depth").path) == (item["sceneID"] as? String == "scan_test"), "per-scene LiDAR policy")
        }
        let noDepth = try await BetaSceneArchive.shared.saveBatch(entries: entries, includeLiDAR: false, contents: .original)
        try unpack(noDepth, to: root.appendingPathComponent("batch-rgb"))
        try expect(!(fm.enumerator(atPath: root.appendingPathComponent("batch-rgb").path)?.allObjects as? [String] ?? []).contains { $0.hasSuffix(".f32") }, "RGB batch leaked depth")
        try expect(BetaSceneArchive.safeFolderName("../") == "_", "unsafe filename")
        try expect(BetaSceneArchive.safeFolderName(String(repeating: "🏳️‍🌈", count: 80)).utf8.count <= 180, "UTF8 filename limit")
        let exportsBefore = try fm.contentsOfDirectory(atPath: scene.deletingLastPathComponent().appendingPathComponent("exports").path).count
        try fm.removeItem(at: second.appendingPathComponent("color.mov"))
        do { _ = try await BetaSceneArchive.shared.saveBatch(entries: entries, includeLiDAR: true, contents: .original); throw NSError(domain: "partial batch published", code: 1) }
        catch is BetaSceneArchive.ArchiveError { }
        try expect(try fm.contentsOfDirectory(atPath: scene.deletingLastPathComponent().appendingPathComponent("exports").path).count == exportsBefore, "failed batch published a ZIP")
        let secondEntry = try await library.entry(at: second)
        try await library.delete([secondEntry])
        try expect(try await library.entries().count == 1 && fm.fileExists(atPath: batch.path), "batch deletion or export preservation")
        try expect(try Data(contentsOf: scene.appendingPathComponent("poses.jsonl")) == poses, "rename/batch changed source poses")
        metadata.streamCapture?.status = "failed"
        try JSONEncoder().encode(metadata).write(to: scene.appendingPathComponent("capture-meta.json"), options: .atomic)
        do { _ = try await BetaSceneArchive.shared.save(directory: scene, includeLiDAR: false, contents: .original); throw NSError(domain: "accepted failed recording", code: 1) }
        catch is BetaSceneArchive.ArchiveError { }
        try meta.write(to: scene.appendingPathComponent("capture-meta.json"), options: .atomic)
        try fm.removeItem(at: scene.appendingPathComponent("images/frame.jpg"))
        do { _ = try await BetaSceneArchive.shared.save(directory: scene, includeLiDAR: false, contents: .original); throw NSError(domain: "accepted missing frame", code: 1) }
        catch is BetaSceneArchive.ArchiveError { }
        try expect(!fm.contentsOfDirectory(atPath: scene.deletingLastPathComponent().path).contains(where: { $0.hasPrefix(".beta-export-") }), "staging leak")
        // Exercise ZIP64 end records and the ZIP64 local-offset extra without multi-GB fixtures.
        let zip64 = root.appendingPathComponent("zip64.zip")
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-c", #"""
import struct as s,zlib,sys,zipfile
name='中文场景/记录.txt'.encode(); data=b'ZIP64 test'; crc=zlib.crc32(data)
local=s.pack('<IHHHHHIIIHH',0x04034b50,45,0,0,0,33,crc,len(data),len(data),len(name),0)+name+data
extra=s.pack('<HHQ',1,8,0)
central=s.pack('<IHHHHHHIIIHHHHHII',0x02014b50,45,45,0,0,0,33,crc,len(data),len(data),len(name),len(extra),0,0,0,0,0xffffffff)+name+extra
end64=s.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,1,1,len(central),len(local))
locator=s.pack('<IIQI',0x07064b50,0,len(local)+len(central),1)
end=s.pack('<IHHHHIIH',0x06054b50,0,0,0xffff,0xffff,0xffffffff,0xffffffff,0)
open(sys.argv[1],'wb').write(local+central+end64+locator+end)
assert zipfile.ZipFile(sys.argv[1]).testzip() is None
"""#, zip64.path]
        try fixture.run(); fixture.waitUntilExit(); try expect(fixture.terminationStatus == 0, "ZIP64 fixture")
        try await BetaSceneArchive.shared.markUTF8Names(in: zip64)
        try unpack(zip64, to: root.appendingPathComponent("zip64-output"))
        try expect(try String(contentsOf: root.appendingPathComponent("zip64-output/中文场景/记录.txt"), encoding: .utf8) == "ZIP64 test", "ZIP64 names and payload")
        let damaged = root.appendingPathComponent("damaged.zip")
        try Data([1,2,3]).write(to: damaged)
        do { try await BetaSceneArchive.shared.markUTF8Names(in: damaged); throw NSError(domain: "accepted damaged zip", code: 1) }
        catch is BetaSceneArchive.ArchiveError { }
        print("PASS: separate libraries, rename validation/persistence, WGS84 metadata, named batch folders, mixed LiDAR policy, atomic batch failure, deletion, source preservation, failed recording/missing frame rejection, staging cleanup")
    }
}
