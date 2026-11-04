// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import SwiftUI
import ARKit

struct BetaCaptureCloseButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button(L10n.text("完成")) { dismiss() } }
}

struct BetaCaptureHUD: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var locationRecorder: BetaLocationRecorder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .headline) private var qualityWidth = 72.0
    private var recording: Bool { controller.phase == .scanning }
    private var available: Bool { ARWorldTrackingConfiguration.isSupported }
    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(DSIconButtonStyle()).disabled(recording)
                    .accessibilityLabel(L10n.text("完成"))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Label(L10n.text("最远距离") + String(format: "  %.1f m", controller.farthestDistance), systemImage: "arrow.up.right")
                    Text(L10n.text("已扫描") + " \(controller.pointCount / 1000)k")
                    Label(String(format: "%.1f m", controller.travelDistance), systemImage: "figure.walk")
                }.font(.caption.monospacedDigit()).padding(12)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            }
            HStack {
                Button { controller.toggleVideoQuality() } label: {
                    Text(controller.videoLongEdge == 3840 ? "4K" : "1080p").font(.headline.monospaced())
                        .frame(width: qualityWidth, height: 44)
                        .contentShape(Rectangle())
                }.disabled(recording || !controller.supports4K).accessibilityIdentifier("betaQuality")
                Text(controller.captureFormatLabel).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                Button { controller.setLiDAREnabled(!controller.useLiDAR) } label: {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .foregroundStyle(controller.hasLiDAR ? .orange : .white.opacity(0.45))
                    Text(controller.hasLiDAR ? "LiDAR ON" : "LiDAR OFF").font(.caption2.monospaced())
                }.disabled(recording || !controller.supportsLiDAR)
                    .accessibilityLabel(L10n.text("使用 LiDAR"))
                    .accessibilityValue(controller.hasLiDAR ? "ON" : "OFF")
                    .accessibilityIdentifier("betaLiDAR")
            }.padding(16).background(.black.opacity(0.55), in: Capsule())
            Button(action: controller.toggleMotionBlurReduction) {
                Label(controller.reduceMotionBlur ? L10n.text("减少运动模糊：开 · 曝光上限 1/120 秒") : L10n.text("减少运动模糊：关 · 系统自动曝光"),
                      systemImage: "timer")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }.disabled(recording).accessibilityIdentifier("betaMotionBlur")
            Text(L10n.text("短曝光可能增加噪声；不会对画面裁切或变形。"))
                .font(.caption2).foregroundStyle(.secondary)
            Label(locationRecorder.message, systemImage: "location.fill")
                .font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("betaCaptureLocation")
            if !available {
                Text(L10n.text("模拟器用于界面预览，拍摄和 LiDAR 需在 iPhone 上测试。"))
                    .font(.subheadline).padding(16).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
            } else if !controller.trackingReady {
                VStack(spacing: 10) {
                    Text(controller.sessionState.message).font(.caption)
                        .accessibilityIdentifier("betaCameraStatus")
                    if controller.sessionState == .permissionDenied {
                        Button(L10n.text("開啟相機設定")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } else if controller.canRestartCamera {
                        Button(L10n.text("重新啟動相機")) { controller.restartCamera() }
                            .accessibilityIdentifier("betaRestartCamera")
                    }
                }.padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            } else if let notice = controller.statusText {
                Text(notice).font(.caption).padding(12).background(.black.opacity(0.6), in: Capsule())
            } else if recording, let issue = controller.assessment.worst {
                Label(issue.message, systemImage: issue.symbol).font(.caption)
                    .padding(12).background(.black.opacity(0.6), in: Capsule())
            }
            Spacer()
            HStack(spacing: 16) {
                Label(String(format: "%02d:%02d", Int(controller.captureSeconds) / 60, Int(controller.captureSeconds) % 60), systemImage: "record.circle")
                Divider().frame(height: 16).overlay(.black.opacity(0.3))
                Label(String(format: "%.1f m", controller.travelDistance), systemImage: "figure.walk")
            }.font(.subheadline.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 22).padding(.vertical, 13)
                .foregroundStyle(.black).background(.orange, in: Capsule())
            Button {
                if recording { controller.stopScan() } else { controller.startScan() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 82, height: 82)
                    if recording { RoundedRectangle(cornerRadius: 8).fill(.orange).frame(width: 32, height: 32) }
                    else { Circle().fill(.orange).frame(width: 66, height: 66) }
                }
            }.disabled(!recording && !controller.canStartScan)
                .opacity(recording || controller.canStartScan ? 1 : 0.45)
                .accessibilityLabel(recording ? L10n.text("停止拍摄") : L10n.text("开始拍摄"))
                .accessibilityIdentifier("betaRecord")
                .accessibilityHint(controller.sessionState.message)
            Text(recording ? L10n.text("停止后逐帧保存图像并估计相机参数") : L10n.text("原生视频 · 每个已录制帧均保存图像"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).padding(.bottom, 12)
            .background { if !available { DS.Palette.canvas.ignoresSafeArea() } }
    }
}
