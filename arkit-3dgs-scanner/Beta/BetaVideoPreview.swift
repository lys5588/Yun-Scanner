// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import AVFoundation

/// Display orientation for our sensor capture. Source pixels and calibration stay unchanged.
@MainActor enum BetaVideoPreview {
    private static func quarterTurns(directory: URL, metadata: [String: Any]) -> Int {
        // Gravity in the first camera identifies how the phone was held, including landscape.
        // Near a straight-up/down view gravity cannot determine roll; use the portrait default.
        guard metadata["worldAlignment"] as? String == "gravity",
              let data = try? Data(contentsOf: directory.appendingPathComponent("poses.jsonl")),
              let line = data.split(separator: 10, maxSplits: 1).first,
              let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let m = row["transform"] as? [Double], m.count == 16,
              m[4].isFinite, m[5].isFinite, hypot(m[4], m[5]) >= 0.25 else { return 1 }
        let turns = Int((atan2(-m[4], m[5]) / (.pi / 2)).rounded())
        return (turns % 4 + 4) % 4
    }
    static func player(movie: URL, directory: URL, isVideoImport: Bool) async throws -> AVPlayer {
        let asset = AVURLAsset(url: movie)
        guard !isVideoImport,
              let data = CaptureMetadata.data(in: directory),
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["imageOrientation"] as? String == "sensor_landscape_right",
              let source = try await asset.loadTracks(withMediaType: .video).first else {
            return AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        // Imported or already oriented tracks must not receive a second rotation.
        let storedTransform = try await source.load(.preferredTransform)
        guard storedTransform.isIdentity else { return AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
        let turns = quarterTurns(directory: directory, metadata: metadata)
        guard turns != 0 else { return AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
        let size = try await source.load(.naturalSize)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // ARKit captures contain one silent video track. This composition exists only in memory.
        let range = try await source.load(.timeRange)
        try video.insertTimeRange(range, of: source, at: .zero)
        switch turns {
        case 1: video.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case 2: video.preferredTransform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        default: video.preferredTransform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        }
        try Task.checkCancellation()
        return AVPlayer(playerItem: AVPlayerItem(asset: composition))
    }
}
