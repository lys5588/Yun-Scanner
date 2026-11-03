// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import CryptoKit

/// Serializes exports, stages every change, and never edits capture source files.
actor BetaSceneArchive {
    static let shared = BetaSceneArchive()
    enum Contents: String, Sendable { case reconstruction, original }
    struct ArchiveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func save(directory: URL, includeLiDAR: Bool, contents: Contents = .reconstruction) throws -> URL {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".beta-export-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let name = SceneInfo.read(in: directory)?.name
        let folder = name.map(Self.safeFolderName) ?? directory.lastPathComponent
        let mirror = staging.appendingPathComponent(folder, isDirectory: true)
        try stage(directory: directory, to: mirror, includeLiDAR: includeLiDAR, contents: contents)
        return try publish(mirror: mirror, parent: parent, name: folder + "-" + contents.rawValue)
    }

    /// One ZIP with one named folder per scene. No nested scene ZIPs and no partial success.
    func saveBatch(entries: [ScanEntry], includeLiDAR: Bool, contents: Contents = .reconstruction) throws -> URL {
        let fm = FileManager.default
        guard let first = entries.first else { throw ArchiveError(message: L10n.text("请先选择场景。")) }
        let parent = first.directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        var ids = Set<String>()
        for entry in entries {
            guard entry.directory.lastPathComponent.hasPrefix("scan_"), ids.insert(entry.id).inserted,
                  entry.directory.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == parent,
                  (try entry.directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ArchiveError(message: L10n.text("场景路径无效，请重新选择。"))
            }
        }
        let staging = parent.appendingPathComponent(".beta-export-" + UUID().uuidString, isDirectory: true)
        let batch = staging.appendingPathComponent("Scenes", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: batch, withIntermediateDirectories: true)
        var used: Set<String> = ["batch-manifest.json"]
        var index: [[String: Any]] = []
        for entry in entries {
            try Task.checkCancellation()
            let base = Self.safeFolderName(entry.displayName)
            var folder = base, suffix = 2
            while !used.insert(folder.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted {
                folder = base + " (\(suffix))"; suffix += 1
            }
            let depth = includeLiDAR && entry.usedLiDAR == true
            do { try stage(directory: entry.directory, to: batch.appendingPathComponent(folder), includeLiDAR: depth, contents: contents) }
            catch { throw ArchiveError(message: entry.displayName + ": " + error.localizedDescription) }
            index.append(["sceneID": entry.id, "sceneName": entry.displayName, "folder": folder, "includesLiDAR": depth])
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "kind": "beta-scene-batch", "contents": contents.rawValue, "scenes": index], options: [.prettyPrinted, .sortedKeys])
            .write(to: batch.appendingPathComponent("batch-manifest.json"), options: .atomic)
        return try publish(mirror: batch, parent: parent, name: "Scenes-" + contents.rawValue)
    }

    nonisolated static func safeFolderName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*<>|\"").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var shortened = ""
        for character in cleaned.prefix(60) {
            guard shortened.utf8.count + String(character).utf8.count <= 180 else { break }
            shortened.append(character)
        }
        return shortened.isEmpty ? "Scene" : shortened
    }

    private func publish(mirror: URL, parent: URL, name: String) throws -> URL {
        try Task.checkCancellation()
        let archive = try ExportManager.makeArchive(of: mirror)
        try markUTF8Names(in: archive)
        try Task.checkCancellation()
        let exports = parent.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let target = exports.appendingPathComponent(name + "-" + UUID().uuidString.prefix(8) + ".zip")
        try FileManager.default.moveItem(at: archive, to: target)
        return target
    }

    /// NSFileCoordinator writes UTF-8 name bytes but can omit ZIP's language flag.
    /// Mark both headers without recompressing or loading videos into memory. Handles ZIP64.
    func markUTF8Names(in archive: URL) throws {
        let file = try FileHandle(forUpdating: archive)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        func invalid() -> ArchiveError { ArchiveError(message: L10n.text("无法写入场景 ZIP。")) }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw invalid() }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { throw invalid() }
            return data
        }
        func number(_ bytes: Data, _ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, offset + count <= bytes.count else { throw invalid() }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        guard size >= 22 else { throw invalid() }
        let tailSize = Int(min(size, 65_557)), tailStart = size - UInt64(tailSize)
        let tail = try read(tailStart, tailSize)
        var end: Int?
        for index in stride(from: tailSize - 22, through: 0, by: -1) {
            if try number(tail, index, 4) == 0x06054b50,
               try UInt64(index + 22) + number(tail, index + 20, 2) == UInt64(tailSize) { end = index; break }
        }
        guard let end, try number(tail, end + 4, 2) == 0, try number(tail, end + 6, 2) == 0 else { throw invalid() }
        var count = try number(tail, end + 10, 2)
        var centralSize = try number(tail, end + 12, 4)
        var offset = try number(tail, end + 16, 4)
        if count == 0xffff || centralSize == 0xffffffff || offset == 0xffffffff {
            let endOffset = tailStart + UInt64(end)
            guard endOffset >= 20 else { throw invalid() }
            let locator = try read(endOffset - 20, 20)
            guard try number(locator, 0, 4) == 0x07064b50, try number(locator, 4, 4) == 0,
                  try number(locator, 16, 4) == 1 else { throw invalid() }
            let record = try read(try number(locator, 8, 8), 56)
            guard try number(record, 0, 4) == 0x06064b50,
                  try number(record, 16, 4) == 0, try number(record, 20, 4) == 0 else { throw invalid() }
            count = try number(record, 32, 8)
            centralSize = try number(record, 40, 8)
            offset = try number(record, 48, 8)
        }
        guard offset <= size, centralSize <= size - offset, count <= centralSize / 46 else { throw invalid() }
        let centralEnd = offset + centralSize
        for _ in 0..<count {
            let header = try read(offset, 46)
            guard try number(header, 0, 4) == 0x02014b50 else { throw invalid() }
            let nameCount = Int(try number(header, 28, 2)), extraCount = Int(try number(header, 30, 2))
            let commentCount = Int(try number(header, 32, 2))
            let name = try read(offset + 46, nameCount)
            guard String(data: name, encoding: .utf8) != nil else { throw invalid() }
            var localOffset = try number(header, 42, 4)
            if localOffset == 0xffffffff {
                let extra = try read(offset + 46 + UInt64(nameCount), extraCount)
                var cursor = 0, found = false
                while cursor + 4 <= extra.count {
                    let tag = try number(extra, cursor, 2), length = Int(try number(extra, cursor + 2, 2))
                    guard cursor + 4 + length <= extra.count else { throw invalid() }
                    if tag == 1 {
                        var field = cursor + 4
                        if try number(header, 24, 4) == 0xffffffff { field += 8 }
                        if try number(header, 20, 4) == 0xffffffff { field += 8 }
                        guard field + 8 <= cursor + 4 + length else { throw invalid() }
                        localOffset = try number(extra, field, 8); found = true; break
                    }
                    cursor += 4 + length
                }
                guard found else { throw invalid() }
            }
            let local = try read(localOffset, 30)
            guard try number(local, 0, 4) == 0x04034b50,
                  try number(local, 26, 2) == UInt64(nameCount),
                  try read(localOffset + 30, nameCount) == name else { throw invalid() }
            for (position, flags) in [(offset + 8, try number(header, 8, 2)), (localOffset + 6, try number(local, 6, 2))] {
                let marked = flags | 0x0800
                try file.seek(toOffset: position)
                try file.write(contentsOf: Data([UInt8(marked & 255), UInt8(marked >> 8)]))
            }
            offset += UInt64(46 + nameCount + extraCount + commentCount)
            guard offset <= centralEnd else { throw invalid() }
        }
        guard offset == centralEnd else { throw invalid() }
        try file.synchronize()
    }

    private func stage(directory: URL, to mirror: URL, includeLiDAR: Bool, contents: Contents) throws {
        if contents == .reconstruction {
            try BetaReconstructionExport.stage(directory: directory, to: mirror, includeLiDAR: includeLiDAR)
        } else {
            try stageOriginal(directory: directory, to: mirror, includeLiDAR: includeLiDAR)
        }
    }
    private func stageOriginal(directory: URL, to mirror: URL, includeLiDAR: Bool) throws {
        let fm = FileManager.default
        let records = ScanLibrary.savedRecords(in: directory).0
        guard !records.isEmpty, records.allSatisfy({ record in
            record.transform.count == 16 && record.transform.allSatisfy(\.isFinite) &&
            fm.fileExists(atPath: directory.appendingPathComponent("images").appendingPathComponent(record.imageFile).path)
        }) else { throw ArchiveError(message: L10n.text("缺少有效的影像或位姿，无法保存完整场景。")) }
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let videos = contents.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { throw ArchiveError(message: L10n.text("缺少原始视频，无法保存完整场景。")) }
        if let data = CaptureMetadata.data(in: directory) {
            let meta = try JSONDecoder().decode(SessionMeta.self, from: data)
            guard meta.streamCapture?.status == "complete" else {
                throw ArchiveError(message: L10n.text("采集未完成，请保留原始数据并重试。"))
            }
        }
        let processingURL = directory.appendingPathComponent("capture-processing.json")
        if fm.fileExists(atPath: processingURL.path) {
            let processing = try JSONSerialization.jsonObject(with: Data(contentsOf: processingURL)) as? [String: Any]
            guard processing?["status"] as? String == "completed" else {
                throw ArchiveError(message: L10n.text("采集未完成，请保留原始数据并重试。"))
            }
        }
        if includeLiDAR {
            let depth = directory.appendingPathComponent("depth")
            let files = fm.enumerator(at: depth, includingPropertiesForKeys: [.isRegularFileKey])
            guard files?.allObjects.contains(where: { ($0 as? URL)?.pathExtension == "f32" }) == true else {
                throw ArchiveError(message: L10n.text("此场景没有可用的 LiDAR 数据。"))
            }
        }
        var excluded: Set<String> = [ExportManager.gaussianTrainingFolder]
        excluded.formUnion(contents.filter { $0.lastPathComponent.hasPrefix(".camera-estimation-") }.map(\.lastPathComponent))
        if !includeLiDAR {
            excluded.formUnion(["depth", "worldmap.arexperience", "worldmap.bin"])
            // Photogrammetry points are RGB evidence; preserve their provenance references.
            if !fm.fileExists(atPath: directory.appendingPathComponent("video-import.json").path) {
                excluded.formUnion(["review.ply", "points.ply", "sparse"])
            }
        }
        try ExportManager.mirrorTree(directory, to: mirror, excluding: excluded)
        if !includeLiDAR {
            for name in ["poses.jsonl", "review-poses.jsonl", "frames.jsonl"] {
                let url = mirror.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { try stripDepthLines(at: url) }
            }
            // Rewrite the exported metadata only; the original remains untouched.
            if let url = CaptureMetadata.existingURL(in: mirror) {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                try JSONSerialization.data(withJSONObject: withoutDepth(json), options: [.sortedKeys])
                    .write(to: url, options: .atomic)
            }
        }
        var manifest: [String: Any] = [
            "schemaVersion": 3, "kind": "beta-capture-scene", "sceneID": directory.lastPathComponent,
            "sceneName": SceneInfo.read(in: directory)?.name ?? directory.lastPathComponent,
            "locationFile": SceneLocation.read(in: directory) == nil ? NSNull() : "scene-location.json",
            "includesLiDAR": includeLiDAR, "imagesDirectory": "images", "poseFile": "poses.jsonl",
            "videos": videos.map(\.lastPathComponent), "frameCount": records.count,
            "poseSource": fm.fileExists(atPath: directory.appendingPathComponent("video-import.json").path)
                ? "photogrammetry_arbitrary_scale" : "arkit_metric",
            "exportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? Data(contentsOf: mirror.appendingPathComponent("camera-estimation.json")),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Removing depth from an export does not undo its contribution to an estimate.
            // poses.jsonl is sanitized in that export, so retain both provenance hashes.
            let exported = try Data(contentsOf: mirror.appendingPathComponent("poses.jsonl"))
            manifest["cameraEstimation"] = [
                "reportFile": "camera-estimation.json", "status": report["status"] ?? "unknown",
                "cameraFile": report["cameraFile"] ?? NSNull(),
                "usedDepthInput": !(report["depthFrameIDs"] as? [Int] ?? []).isEmpty,
                "sourcePosesSHA256BeforeExport": report["sourcePosesSHA256"] ?? NSNull(),
                "exportedPosesSHA256": SHA256.hash(data: exported).map { String(format: "%02x", $0) }.joined(),
                "originalCameraFile": "poses.jsonl", "separateEstimates": true
            ]
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: mirror.appendingPathComponent("scene-package.json"), options: .atomic)
    }
    private func withoutDepth(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dict {
                if key.lowercased().contains("depth") || key.lowercased().contains("confidence") { continue }
                result[key] = key == "lidarEnabled" ? false : withoutDepth(value)
            }
            return result
        }
        if let array = value as? [Any] { return array.map(withoutDepth) }
        return value
    }
    private func stripDepthLines(at url: URL) throws {
        let temporary = url.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ArchiveError(message: L10n.text("无法写入场景 ZIP。"))
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var pending = Data()
        func writeLine(_ data: Data) throws {
            guard !data.isEmpty else { return }
            let object = try JSONSerialization.jsonObject(with: data)
            var encoded = try JSONSerialization.data(withJSONObject: withoutDepth(object), options: [.sortedKeys])
            encoded.append(10)
            try output.write(contentsOf: encoded)
        }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                try writeLine(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
        }
        try writeLine(pending)
        try output.synchronize()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
