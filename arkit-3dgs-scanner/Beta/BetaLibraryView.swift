// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import SwiftUI

extension Notification.Name { static let betaLibraryChanged = Notification.Name("betaLibraryChanged") }

struct BetaLibraryView: View {
    @State private var exportContents: BetaSceneArchive.Contents = .reconstruction
    @AppStorage("beta.library.list") private var listLayout = false
    @State private var entries: [ScanEntry] = []
    @State private var selected: Set<String> = []
    @State private var selecting = false
    @State private var busy = false
    @State private var includeLiDAR = true
    @State private var deletion: [ScanEntry] = []
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var archive: URL?
    private var selectedEntries: [ScanEntry] { entries.filter { selected.contains($0.id) } }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: listLayout ? 10 : 18) {
                if !selecting {
                    NavigationLink { VideoImportView(isBeta: true) } label: {
                        Label(L10n.text("使用已有影片"), systemImage: "film.stack")
                    }.buttonStyle(DSPrimaryButtonStyle(tint: .orange)).accessibilityIdentifier("betaImportVideo")
                }
                if entries.isEmpty { Text(L10n.text("等待你的第一个场景")).foregroundStyle(.secondary).padding(40) }
                ForEach(entries) { entry in
                    if selecting {
                        Button { if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.orange)
                                sceneLabel(entry)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("betaSelect_" + entry.id)
                            .accessibilityValue(selected.contains(entry.id) ? L10n.text("已选择") : L10n.text("未选择"))
                    } else {
                        NavigationLink { BetaSceneView(directory: entry.directory) } label: { sceneLabel(entry) }
                            .buttonStyle(.plain).accessibilityIdentifier("betaScene_" + entry.id)
                    }
                }
                if let error { Text(error).foregroundStyle(.orange).font(.callout).accessibilityIdentifier("betaLibraryError") }
                if let archive {
                    Label(L10n.text("批量 ZIP 已保存"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityIdentifier("betaBatchSavedInLibrary")
                    Text(archive.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Button { SystemShare.present([archive]) } label: {
                        Label(L10n.text("导出到文件 / 分享"), systemImage: "square.and.arrow.up")
                    }.buttonStyle(DSSecondaryButtonStyle())
                }
            }.padding(24)
        }.dsCanvas().navigationTitle(L10n.text("采集场景"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(busy)
            .disabled(busy)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { listLayout.toggle() } label: { Image(systemName: listLayout ? "rectangle.grid.1x2" : "list.bullet") }
                        .accessibilityLabel(listLayout ? L10n.text("切换卡片显示") : L10n.text("切换列表显示"))
                        .accessibilityIdentifier("betaLibraryLayout").disabled(busy)
                    Button(selecting ? L10n.text("完成") : L10n.text("选择")) {
                        selecting.toggle(); selected.removeAll()
                    }.accessibilityIdentifier("betaLibrarySelect").disabled(entries.isEmpty || busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    VStack(spacing: 12) {
                        HStack {
                            Text(L10n.text("已选择 \(selected.count) 个场景")).font(.subheadline)
                            Spacer()
                            Button(selected.count == entries.count ? L10n.text("取消全选") : L10n.text("全选")) {
                                selected = selected.count == entries.count ? [] : Set(entries.map(\.id))
                            }.accessibilityIdentifier("betaSelectAll")
                        }
                        Picker(L10n.text("保存内容"), selection: $exportContents) {
                            Text(L10n.text("重建结果")).tag(BetaSceneArchive.Contents.reconstruction)
                            Text(L10n.text("原始归档")).tag(BetaSceneArchive.Contents.original)
                        }.pickerStyle(.segmented)
                        Toggle(L10n.text("包含已采集的 LiDAR"), isOn: $includeLiDAR).font(.caption).tint(.orange)
                        HStack(spacing: 12) {
                            Button(role: .destructive) { deletion = selectedEntries; confirmDelete = true } label: {
                                Label(L10n.text("删除"), systemImage: "trash")
                            }.buttonStyle(DSSecondaryButtonStyle()).accessibilityIdentifier("betaBatchDelete")
                            Button { saveBatch() } label: {
                                if busy { ProgressView() }
                                else { Label(L10n.text("批量保存"), systemImage: "square.and.arrow.down") }
                            }.buttonStyle(DSPrimaryButtonStyle(tint: .orange)).accessibilityIdentifier("betaBatchSave")
                        }.disabled(selected.isEmpty || busy)
                        if busy { Text(L10n.text("正在打包所选场景，请保持 App 在前台。")) .font(.caption) }
                        if let archive {
                            Button { SystemShare.present([archive]) } label: {
                                Label(L10n.text("批量 ZIP 已保存"), systemImage: "square.and.arrow.up")
                            }.accessibilityIdentifier("betaBatchSaved")
                        }
                    }.padding(20).background(DS.Palette.canvas).disabled(busy)
                }
            }
            .alert(L10n.text("删除所选的 \(deletion.count) 个场景？"), isPresented: $confirmDelete) {
                Button(L10n.text("删除"), role: .destructive) { removeSelected() }
                Button(L10n.text("取消"), role: .cancel) { }
            } message: { Text(L10n.text("将删除场景及原始采集数据；此前导出的 ZIP 会保留。")) }
            .task { await reload() }
            .onChange(of: exportContents) { _, _ in archive = nil }
            .onReceive(NotificationCenter.default.publisher(for: .betaLibraryChanged)) { _ in Task { await reload() } }
    }
    @ViewBuilder private func sceneLabel(_ entry: ScanEntry) -> some View {
        if listLayout { BetaSceneRow(entry: entry) }
        else { BetaSceneCard(entry: entry) }
    }
    private func reload() async {
        do {
            entries = try await ScanLibrary.beta.entries()
            selected.formIntersection(Set(entries.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }
    private func saveBatch() {
        let snapshot = selectedEntries, depth = includeLiDAR, contents = exportContents
        busy = true; error = nil; archive = nil
        Task {
            defer { busy = false }
            do { archive = try await BetaSceneArchive.shared.saveBatch(entries: snapshot, includeLiDAR: depth, contents: contents) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func removeSelected() {
        let snapshot = deletion
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await ScanLibrary.beta.delete(snapshot) }
            catch { self.error = error.localizedDescription }
            await reload()
            NotificationCenter.default.post(name: .betaLibraryChanged, object: nil)
        }
    }
}

private struct BetaSceneRow: View {
    let entry: ScanEntry
    @State private var cover: UIImage?
    var body: some View {
        HStack(spacing: 14) {
            Text(entry.displayName).font(.subheadline.weight(.medium)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.1))
                if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                else { Image(systemName: "video").foregroundStyle(.orange) }
            }.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
        }.padding(12).background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
            .task(id: entry.id) {
                guard let url = entry.cover else { return }
                let data = await Task.detached { ScanLibrary.imageData(url, maxDimension: 160) }.value
                cover = data.flatMap(UIImage.init(data:))
            }
    }
}

struct BetaRenameSheet: View {
    let entry: ScanEntry
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.text("场景名称"), text: $name).focused($focused)
                    .submitLabel(.done).onSubmit { save() }.accessibilityIdentifier("betaSceneNameField")
                Text(L10n.text("名称用于场景列表和导出文件夹，不改变原始数据。"))
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle(L10n.text("编辑场景名称")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("保存")) { save() }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("betaRenameSave")
                    }
                }
                .onAppear { name = entry.displayName; focused = true }
        }.presentationDetents([.medium]).interactiveDismissDisabled(saving)
    }
    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await ScanLibrary.beta.rename(entry, to: name)
                NotificationCenter.default.post(name: .betaLibraryChanged, object: nil)
                onSaved(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
