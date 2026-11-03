// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
// Add to a physical iPhone UI-test target. Requires a person to start/stop a
// 20–30 second moving capture when the camera is ready. Never deletes scenes.
import XCTest

final class MetricCaptureValidation: XCTestCase {
    @MainActor private func snapshot(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
        print("METRIC_CAPTURE \(name)\n\(app.debugDescription)")
    }

    @MainActor func testUserCaptureAndExport() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 20))
        app.buttons["openCaptureBeta"].tap()
        XCTAssertTrue(app.buttons["betaStartCapture"].waitForExistence(timeout: 10))
        app.buttons["betaStartCapture"].tap()
        let record = app.buttons["betaRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["betaLiDAR"].value as? String, "ON", "LiDAR must default on on this device")
        let ready = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: record)], timeout: 40)
        snapshot(app, "camera-ready-lidar-on")
        XCTAssertEqual(ready, .completed, "ARKit must be ready before recording")
        print("METRIC_CAPTURE_READY_FOR_USER")
        let started = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == %@", "停止拍摄"), evaluatedWith: record)], timeout: 180)
        XCTAssertEqual(started, .completed, "Waiting for user to start a real moving capture")
        print("METRIC_CAPTURE_RECORDING")
        snapshot(app, "user-recording")
        let preview = app.buttons["betaVisualize"]
        XCTAssertTrue(preview.waitForExistence(timeout: 240), "User stops capture, then RealityKit finishes")
        XCTAssertTrue(preview.isEnabled)
        XCTAssertTrue(app.staticTexts["摄影测量相机参数"].exists)
        snapshot(app, "camera-estimation-preview")
        preview.tap()
        let save = app.buttons["betaSaveZIP"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "betaSaved").firstMatch.waitForExistence(timeout: 120))
        snapshot(app, "metric-scene-zip-saved")
        print("METRIC_CAPTURE_ZIP_SAVED")
    }

    // Run after capture; update the fixture ID to the scan being validated.
    // Reopens only that scene and never records again or changes camera estimates.
    @MainActor func testSavedResultPage() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.activate()
        if app.buttons["openCaptureBeta"].exists { app.buttons["openCaptureBeta"].tap() }
        if app.buttons["betaLibrary"].exists {
            app.buttons["betaLibrary"].tap()
            let scene = app.buttons["betaScene_scan_20261103_173257_121DEF"]
            XCTAssertTrue(scene.waitForExistence(timeout: 15))
            scene.tap()
        }
        XCTAssertTrue(app.staticTexts["摄影测量相机参数"].waitForExistence(timeout: 15))
        let saved = app.descendants(matching: .any).matching(identifier: "betaSaved").firstMatch
        if !saved.exists {
            if app.buttons["betaVisualize"].exists { app.buttons["betaVisualize"].tap() }
            let save = app.buttons["betaSaveZIP"]
            if save.exists && (save.label.contains("保存场景 ZIP") || save.label.contains("保存重建结果 ZIP")) { save.tap() }
        }
        XCTAssertTrue(saved.waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["betaShareZIP"].exists || app.buttons["betaSaveZIP"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.84))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.25)))
        snapshot(app, "saved-camera-estimation-card")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "已估计并对齐")).firstMatch.exists)
    }

    /// Re-export the existing physical capture. Does not record or re-estimate it.
    @MainActor func testFilteredReconstructionExport() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.liyunshan.arkit3dgsscanner")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["openCaptureBeta"].waitForExistence(timeout: 15))
        app.buttons["openCaptureBeta"].tap()
        XCTAssertTrue(app.buttons["betaLibrary"].waitForExistence(timeout: 10))
        app.buttons["betaLibrary"].tap()
        let scene = app.buttons["betaScene_scan_20261103_173257_121DEF"]
        XCTAssertTrue(scene.waitForExistence(timeout: 15)); scene.tap()
        let visualize = app.buttons["betaVisualize"]
        XCTAssertTrue(visualize.waitForExistence(timeout: 15)); visualize.tap()
        let save = app.buttons["betaSaveZIP"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        XCTAssertTrue(save.label.contains("保存重建结果 ZIP"), "Default must be filtered reconstruction")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "betaSaved").firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "-reconstruction-")).firstMatch.exists)
        app.swipeUp()
        let picker = app.segmentedControls["betaExportContents"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons["原始归档"].tap()
        XCTAssertTrue(save.label.contains("保存原始归档 ZIP"))
        picker.buttons["重建结果"].tap()
        XCTAssertTrue(save.label.contains("保存重建结果 ZIP"))
        snapshot(app, "filtered-export-and-original-archive-choice")
    }
}
