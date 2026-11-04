// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import SwiftUI
import AVKit

struct BetaSceneView: View {
    let directory: URL
    @State private var entry: ScanEntry?
    @State private var preview: ScanPreview?
    @State private var includeLiDAR = false
    @State private var display = false
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var saving = false
    @State private var archive: URL?
    @State private var reset = 0
    @State private var renaming = false
    @State private var showMap = false
    @State private var confirmDelete = false
    @State private var cameraReport: CapturePhotogrammetry.Report?
    @State private var estimationTask: Task<Void, Never>?
    @State private var estimating = false
    @State private var estimationProgress = 0.0
    @State private var exportContents: BetaSceneArchive.Contents = .reconstruction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(display ? "02 / VISUALIZATION" : "01 / PREVIEW", systemImage: display ? "point.3.connected.trianglepath.dotted" : "play.rectangle")
                    .font(.caption.monospaced().weight(.semibold)).foregroundStyle(.orange)
                if let entry {
                    Button { renaming = true } label: {
                        HStack {
                            Text(entry.displayName).font(.title2.bold()).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "pencil").font(.body)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(saving).accessibilityIdentifier("betaRenameScene")
                    Text(entry.date.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if let location = entry.location {
                        Button { showMap = true } label: {
                            HStack {
                                Image(systemName: "mappin.and.ellipse")
                                Text(location.address ?? String(format: "%.5f, %.5f", location.latitude, location.longitude)).lineLimit(2)
                                Spacer()
                                Image(systemName: "map")
                            }.font(.subheadline).padding(16)
                                .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityIdentifier("betaOpenMap")
                    } else {
                        Label(L10n.text("此场景未记录拍摄位置。"), systemImage: "location.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let preview {
                    if display {
                        ReviewPointCloudView(points: includeLiDAR || entry?.isVideoImport == true ? preview.points : [],
                                             trajectory: preview.trajectory, resetCameraToken: reset)
                            .id(includeLiDAR).frame(height: 340).clipShape(RoundedRectangle(cornerRadius: 22))
                        HStack {
                            Text(L10n.text("拖动旋转 · 双指缩放")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { reset += 1 } label: { Image(systemName: "scope") }
                                .accessibilityLabel(L10n.text("顯示完整點雲"))
                        }
                    } else if let player {
                        VideoPlayer(player: player).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityIdentifier("betaSceneVideo")
                    }
                    HStack(spacing: 22) {
                        metric("\(preview.images.count)", L10n.text("帧"))
                        metric("\(preview.trajectory.count)", L10n.text("相机位姿"))
                        metric(entry?.isVideoImport == true ? "SfM" : "ARKit", L10n.text("轨迹来源"))
                    }.frame(maxWidth: .infinity).padding(18)
                        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
                    Toggle(isOn: $includeLiDAR) {
                        Label(L10n.text("使用 LiDAR"), systemImage: "sensor.tag.radiowaves.forward")
                    }.disabled(entry?.usedLiDAR != true || saving).tint(.orange)
                        .accessibilityIdentifier("betaPreviewLiDAR")
                    Text(entry?.usedLiDAR == true
                         ? L10n.text("开启后显示点云，并将采集深度一起保存。")
                         : L10n.text("此场景未采集 LiDAR，保存视频、影像和位姿。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if entry?.isVideoImport == true {
                        Text(L10n.text("普通视频的估计轨迹为相对尺度，不提供米制距离。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice = preview.processingNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    if entry?.isVideoImport == false {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text("摄影测量相机参数")).font(.headline)
                            Text(cameraEstimationNotice).font(.caption).foregroundStyle(.secondary)
                            if let alignment = cameraReport?.alignment {
                                Text(L10n.text("配准后位置差中位数：\(String(format: "%.2f", alignment.medianPositionErrorMeters * 100)) cm"))
                                    .font(.caption.monospacedDigit())
                                Text(L10n.text("差值用于比较两套估计，不代表真实误差或拍摄抖动。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if estimating {
                                ProgressView(value: estimationProgress)
                                Text(L10n.text("RealityKit 相机估计需要保持 App 在前台。"))
                                    .font(.caption).foregroundStyle(.orange)
                                Button(L10n.text("取消")) { estimationTask?.cancel() }
                            } else {
                                Button(L10n.text("重新估计相机参数"), action: estimateCameras)
                                    .disabled(saving).accessibilityIdentifier("betaEstimateCameras")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                            .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("场景数据包")).font(.headline)
                        Picker(L10n.text("保存内容"), selection: $exportContents) {
                            Text(L10n.text("重建结果")).tag(BetaSceneArchive.Contents.reconstruction)
                            Text(L10n.text("原始归档")).tag(BetaSceneArchive.Contents.original)
                        }.pickerStyle(.segmented).disabled(saving || estimating)
                            .accessibilityIdentifier("betaExportContents")
                        if exportContents == .original {
                            Label(L10n.text("原始视频"), systemImage: "film")
                            Label(L10n.text("逐帧图像与相机位姿"), systemImage: "photo.stack")
                        } else {
                            Label(L10n.text("仅通过筛选的图像与相机参数"), systemImage: "checkmark.circle")
                            Text(entry?.isVideoImport == true
                                 ? L10n.text("仅包含有效图像与对应相机参数；原视频与未筛选点云保留在原始归档中。")
                                 : L10n.text("保留全部有效图像和 ARKit 参数；RealityKit 单独保存成功结果，并列出缺失帧。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if includeLiDAR { Label(L10n.text("LiDAR 深度与置信度"), systemImage: "square.3.layers.3d") }
                        Text("ZIP · JPEG · JSONL" + (includeLiDAR ? " · F32 / U8" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
                } else if error == nil { ProgressView(L10n.text("正在载入场景…")).frame(maxWidth: .infinity).padding(80) }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.subheadline) }
                if let archive {
                    Text(archive.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Button { SystemShare.present([archive]) } label: { Label(L10n.text("导出到文件 / 分享"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(DSSecondaryButtonStyle()).accessibilityIdentifier("betaShareZIP")
                }
                if entry != nil {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(L10n.text("删除场景"), systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.disabled(saving || estimating).accessibilityIdentifier("betaDeleteScene")
                }
            }.padding(24)
        }.dsCanvas().navigationTitle(display ? "Visualization" : L10n.text("场景预览"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(saving || estimating)
            .sheet(isPresented: $renaming) {
                if let entry { BetaRenameSheet(entry: entry) { Task { await refreshEntry(); archive = nil } } }
            }
            .sheet(isPresented: $showMap) {
                if let entry, let location = entry.location { BetaSceneMap(location: location, name: entry.displayName) }
            }
            .alert(L10n.text("删除这个场景？"), isPresented: $confirmDelete) {
                Button(L10n.text("删除"), role: .destructive) { deleteScene() }
                Button(L10n.text("取消"), role: .cancel) { }
            } message: { Text(L10n.text("将删除场景及原始采集数据；此前导出的 ZIP 会保留。")) }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if archive != nil {
                        Label(L10n.text("场景 ZIP 已保存"), systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green).accessibilityIdentifier("betaSaved")
                    }
                    Button {
                        if let archive { SystemShare.present([archive]) }
                        else if display { save() }
                        else { player?.pause(); display = true }
                    } label: {
                        if saving { ProgressView().tint(.white) }
                        else if archive != nil { Label(L10n.text("导出到文件 / 分享"), systemImage: "square.and.arrow.up") }
                        else { Label(display ? (exportContents == .reconstruction ? L10n.text("保存重建结果 ZIP") : L10n.text("保存原始归档 ZIP")) : L10n.text("进入 Visualization"), systemImage: display ? "square.and.arrow.down" : "cube.transparent") }
                    }.buttonStyle(DSPrimaryButtonStyle(tint: .orange)).disabled(preview == nil || saving || estimating)
                        .accessibilityIdentifier(display ? "betaSaveZIP" : "betaVisualize")
                }.padding(.horizontal, 24).padding(.vertical, 12).background(DS.Palette.canvas)
            }
            .onChange(of: includeLiDAR) { _, _ in archive = nil }
            .onChange(of: exportContents) { _, _ in archive = nil }
            .task(id: directory) { await load() }
            .onDisappear { player?.pause(); estimationTask?.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { player?.pause() }
                if phase == .background { estimationTask?.cancel() }
            }
    }
    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func load() async {
        do {
            let found = try await ScanLibrary.beta.entry(at: directory)
            entry = found
            cameraReport = CapturePhotogrammetry.readReport(in: directory)
            includeLiDAR = found.usedLiDAR == true
            preview = try await ScanLibrary.beta.preview(found)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if let movie = files.first(where: { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }) {
                player = try await BetaVideoPreview.player(movie: movie, directory: directory, isVideoImport: found.isVideoImport)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        saving = true; error = nil
        let useDepth = includeLiDAR
        let contents = exportContents
        Task {
            defer { saving = false }
            do { archive = try await BetaSceneArchive.shared.save(directory: directory, includeLiDAR: useDepth, contents: contents) }
            catch { self.error = error.localizedDescription }
        }
    }
    private var cameraEstimationNotice: String {
        guard let report = cameraReport else { return L10n.text("尚未估计，当前保存的是原始 ARKit 参数。") }
        switch report.status {
        case "estimated_aligned":
            return L10n.text("已估计并对齐 \(report.estimatedFrameCount) / \(report.inputFrameCount) 张图像；原始参数已保留。")
                + "\n" + L10n.text("逐图请求相机估计；未返回位姿的图像仍保留 ARKit 参数，实际提交和缺失情况见报告。")
                + "\n" + L10n.text("重建包分文件夹保存两套参数，默认使用 RealityKit；当前预览和训练仍使用 ARKit。")
                + (report.batches?.count ?? 0 > 1 ? "\n" + L10n.text("图像分组估计后分别对齐到 ARKit 世界；各组不是一次联合优化。") : "")
                + (report.reason != nil ? "\n" + L10n.text("部分分组未完成估计或配准，请查看原始报告中的缺失记录。") : "")
                + "\n" + L10n.text("这些结果尚未通过独立精度验证。")
        case "alignment_rejected": return L10n.text("RealityKit 已返回结果，但坐标配准未完成。请重新估计相机参数；原始结果仍保留。")
        case "unsupported": return L10n.text("设备不支持摄影测量，保留原始 ARKit 参数。")
        case "insufficient_frames": return L10n.text("关键帧不足，摄影测量至少需要 8 张图像。")
        case "too_many_frames": return L10n.text("关键帧超出当前设备处理上限，原始参数已保留。")
        case "processing", "cancelled": return L10n.text("摄影测量尚未完成，原始采集已保留。")
        default: return L10n.text("这次未生成可用的摄影测量参数，已保留原始 ARKit 参数。")
        }
    }
    private func estimateCameras() {
        guard !estimating, !saving, scenePhase == .active else { return }
        estimating = true; estimationProgress = 0; archive = nil; player?.pause()
        estimationTask = Task {
            let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
                estimating = false; estimationTask = nil
            }
            do {
                let report = try await CapturePhotogrammetry.run(directory: directory) { value in
                    Task { @MainActor in estimationProgress = value }
                }
                // A Beta capture may have been interrupted only during this additional
                // camera stage. Restore its export state after the stage has finished.
                let infoURL = directory.appendingPathComponent("beta-capture.json")
                let stateURL = directory.appendingPathComponent("capture-processing.json")
                if let info = try? JSONSerialization.jsonObject(with: Data(contentsOf: infoURL)) as? [String: Any],
                   info["rawCaptureCompleted"] as? Bool == true, report.inputFrameCount > 0,
                   let source = try? Data(contentsOf: directory.appendingPathComponent("poses.jsonl")),
                   CapturePhotogrammetry.hash(source) == report.sourcePosesSHA256,
                   var state = try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any] {
                    state["status"] = "completed"; state["progress"] = 1
                    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            cameraReport = CapturePhotogrammetry.readReport(in: directory)
            await load()
        }
    }
    private func refreshEntry() async {
        do { entry = try await ScanLibrary.beta.entry(at: directory) }
        catch { self.error = error.localizedDescription }
    }
    private func deleteScene() {
        guard let entry else { return }
        saving = true; player?.pause()
        Task {
            defer { saving = false }
            do {
                try await ScanLibrary.beta.delete(entry)
                NotificationCenter.default.post(name: .betaLibraryChanged, object: nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
