// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
//
//  CaptureView.swift
//  fable — AR 掃描主畫面（ARSCNView + HUD 疊層）
//

import SwiftUI
import SceneKit
import ARKit

struct CaptureView: View {
    /// Receives the saved scan when the user chooses to train it right after capture.
    var isBeta = false
    var onTrain: ((URL) -> Void)? = nil
    @StateObject private var controller: CaptureController
    @Environment(\.scenePhase) private var scenePhase
    @State private var reviewCameraReset = 0
    @StateObject private var locationRecorder = BetaLocationRecorder()

    init(mode: CaptureMode = .lidar, isBeta: Bool = false, onTrain: ((URL) -> Void)? = nil) {
        self.isBeta = isBeta
        self.onTrain = onTrain
        _controller = StateObject(wrappedValue: Self.makeController(mode: mode, isBeta: isBeta))
    }

    private static func makeController(mode: CaptureMode, isBeta: Bool) -> CaptureController {
        let controller = CaptureController()
        if isBeta { controller.configureBeta() }
        // Configure before ARViewContainer attaches: the first AR session already has
        // the correct depth/mesh semantics, and camera-only capture cannot inherit LiDAR.
        controller.setLiDAREnabled(mode == .lidar)
        return controller
    }

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller,
                            isActive: scenePhase != .background && (controller.phase == .idle || controller.phase == .scanning))
                .ignoresSafeArea()
            // review / exporting / done 期間以 3D 檢視器覆蓋 AR 畫面（AR view 保持存活以便續掃）
            if !isBeta && showReview && scenePhase == .active {
                ReviewPointCloudView(points: controller.reviewPoints,
                                     trajectory: controller.reviewTrajectory,
                                     resetCameraToken: reviewCameraReset)
                    .ignoresSafeArea()
                    .id(controller.reviewPoints.count)   // 續掃後重新處理 → 重建場景
            }
            if controller.phase == .processing && !isBeta {
                FusionProcessingView(progress: controller.exportProgress,
                                     stage: controller.processingStage,
                                     detail: controller.statusText,
                                     frameCount: controller.keyframeCount,
                                     startedAt: controller.processingStartedAt,
                                     backgroundStatus: controller.processingBackgroundStatus)
            } else if isBeta, controller.phase == .review, let directory = controller.capturedDirectory {
                NavigationStack {
                    BetaSceneView(directory: directory)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { BetaCaptureCloseButton() } }
                }
            } else if isBeta {
                BetaCaptureHUD(controller: controller, locationRecorder: locationRecorder)
                    .disabled(controller.phase == .processing)
            } else {
                HUDOverlay(controller: controller,
                           onResetView: showReview ? { reviewCameraReset += 1 } : nil,
                           onTrain: onTrain)
            }
        }
        .statusBarHidden()
        // 平面圖用獨立頁面而非疊層：它的資訊與操作跟點雲檢視完全不同一組，
        // 疊在 HUD 上兩邊會互相打架（標頭被統計面板夾住、圖例被底部按鈕壓掉）。
        // fullScreenCover 也順便讓 HUD 整個退場，不必逐項判斷該不該隱藏。
        .fullScreenCover(isPresented: $controller.showFloorPlan) {
            if let fp = controller.floorPlanData {
                FloorPlanView(data: fp,
                              onClose: { controller.showFloorPlan = false },
                              onRename: { i, name in controller.renameRoom(at: i, to: name) },
                              showFurniture: $controller.showPlanFurniture)
            }
        }
        // Capture needs the camera, AR tracking and the GPU: 3DGS training waits meanwhile.
        .onAppear {
            TrainingCenter.shared.setCapturing(true)
            if isBeta { locationRecorder.start() }
        }
        .onDisappear {
            TrainingCenter.shared.setCapturing(false)
            if isBeta { locationRecorder.finish() }
        }
        .onChange(of: controller.phase) { _, phase in
            guard isBeta else { return }
            if phase == .scanning, let directory = controller.capturedDirectory { locationRecorder.begin(directory: directory) }
            else if phase == .idle { locationRecorder.start() }
            else { locationRecorder.finish() }
        }
        .onChange(of: controller.useLiDAR) { _, enabled in
            guard !isBeta else { return }
            UserDefaults.standard.set((enabled ? CaptureMode.lidar : .camera).rawValue,
                                      forKey: CaptureMode.preferenceKey)
        }
        .onChange(of: scenePhase) { _, phase in
            // 系統權限提示的 inactive 不等於離開 App。
            if phase == .background { controller.sceneActivityChanged(isActive: false) }
            if phase == .active { controller.sceneActivityChanged(isActive: true) }
            if isBeta {
                if phase == .background { locationRecorder.stop() }
                if phase == .active, controller.phase == .idle || controller.phase == .scanning { locationRecorder.start() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            controller.prepareForBackgroundTransition()
        }
    }

    private var showReview: Bool {
        switch controller.phase {
        case .review, .exporting, .done: return !controller.reviewPoints.isEmpty
        default: return false
        }
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let controller: CaptureController
    let isActive: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.isHidden = !isActive
        view.isPlaying = isActive
        view.rendersContinuously = isActive
        view.autoenablesDefaultLighting = true
        view.automaticallyUpdatesLighting = true
        controller.sceneActivityChanged(isActive: isActive)
        controller.attach(arView: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // The view/session stays available for resume, but the covered camera must not keep
        // rendering beside fusion or a second review SCNView.
        uiView.isHidden = !isActive
        uiView.isPlaying = isActive
        uiView.rendersContinuously = isActive
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        // 開啟平面圖不應結束 session；只有 AR view 真正移除時釋放資源。
        coordinator.controller.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject {
        let controller: CaptureController
        init(controller: CaptureController) { self.controller = controller }
    }
}
