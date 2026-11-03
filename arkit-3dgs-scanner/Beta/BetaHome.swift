// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import SwiftUI
import ARKit

struct ContentView: View {
    @State private var beta = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            ReconstructionHome(onFlip: flip)
                .rotation3DEffect(.degrees(beta ? -180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                .opacity(beta ? 0 : 1).allowsHitTesting(!beta).accessibilityHidden(beta)
            BetaHome(onFlip: flip)
                .rotation3DEffect(.degrees(beta ? 0 : 180), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                .opacity(beta ? 1 : 0).allowsHitTesting(beta).accessibilityHidden(!beta)
        }
    }
    private func flip() { withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.65)) { beta.toggle() } }
}

struct BetaHome: View {
    var onFlip: () -> Void
    @State private var entries: [ScanEntry] = []
    @State private var capture = false
    @State private var library = false
    @State private var revision = 0
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("CAPTURE / BETA 01", systemImage: "record.circle")
                        .font(.caption.monospaced().weight(.semibold)).foregroundStyle(.orange)
                    Text(L10n.text("把现场，\n完整带走。"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(L10n.text("视频、影像与相机轨迹。\n一个场景，一个数据包。"))
                        .font(.body).foregroundStyle(.secondary)
                    HStack {
                        Text(L10n.text("采集场景")).font(.headline)
                        Spacer()
                        Text(String(format: "%02d", entries.count)).font(.caption.monospaced()).foregroundStyle(.orange)
                    }
                    if entries.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "viewfinder").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.orange)
                            Text(L10n.text("等待你的第一个场景")).font(.headline)
                            Text(L10n.text("Beta 采集与 3DGS 重建分别保存"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).frame(minHeight: 215)
                        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.orange.opacity(0.18)))
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(entries) { entry in
                                    NavigationLink { BetaSceneView(directory: entry.directory) } label: {
                                        BetaSceneCard(entry: entry).frame(width: 270)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(24)
            }
            .dsCanvas()
            .toolbar {
                ToolbarItem(placement: .principal) { Text("YUNS / DATA").font(.caption.monospaced().weight(.semibold)).fixedSize() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onFlip) { Image(systemName: "arrow.triangle.2.circlepath") }
                        .accessibilityLabel(L10n.text("返回三维重建"))
                        .accessibilityIdentifier("returnToReconstruction")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button { capture = true } label: { Label(L10n.text("开始拍摄"), systemImage: "record.circle") }
                        .buttonStyle(DSPrimaryButtonStyle(tint: .orange)).accessibilityIdentifier("betaStartCapture")
                    Button { library = true } label: { Label(L10n.text("查看场景 / 使用已有视频"), systemImage: "square.stack") }
                        .buttonStyle(DSSecondaryButtonStyle()).accessibilityIdentifier("betaLibrary")
                    Text(L10n.text("端侧采集 · 独立场景库 · ZIP 保存")).font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.vertical, 12).background(DS.Palette.canvas)
            }
            .navigationDestination(isPresented: $library) { BetaLibraryView() }
            .fullScreenCover(isPresented: $capture, onDismiss: { revision += 1 }) {
                CaptureView(mode: .lidar, isBeta: true)
            }
            .task(id: revision) { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: .betaLibraryChanged)) { _ in revision += 1 }
            .onChange(of: library) { _, shown in if !shown { revision += 1 } }
        }.tint(.orange)
    }
    private func reload() async {
        do { entries = try await ScanLibrary.beta.entries(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct BetaSceneCard: View {
    let entry: ScanEntry
    @State private var cover: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color.orange.opacity(0.07)
                if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                else { Image(systemName: "viewfinder").font(.largeTitle).foregroundStyle(.orange) }
            }.frame(height: 165).clipped().contentShape(Rectangle()).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(entry.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(entry.date.formatted(date: .numeric, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            if let location = entry.location {
                Label(location.address ?? String(format: "%.4f, %.4f", location.latitude, location.longitude), systemImage: "mappin.and.ellipse")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(entry.frameCount) " + L10n.text("帧") + (entry.usedLiDAR == true ? " · LiDAR" : " · RGB"))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }.padding(14).background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .task(id: entry.id) {
                guard let url = entry.cover else { return }
                let data = await Task.detached { ScanLibrary.imageData(url, maxDimension: 700) }.value
                cover = data.flatMap(UIImage.init(data:))
            }
    }
}
