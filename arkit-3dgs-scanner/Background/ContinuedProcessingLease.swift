// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import BackgroundTasks
import UIKit

/// A foreground user action owns one request and one worker. A request is not a grant.
/// The worker acknowledges expiration by stopping/checkpointing before calling finish.
@MainActor
final class ContinuedProcessingLease {
    let title: String
    let requiresGPU: Bool
    private let onExpiration: () -> Void
    private let onChange: () -> Void
    private var identifier: String?
    private var task: AnyObject?
    private var expired = false
    private var fraction = 0.0
    private var subtitle = ""
    private(set) var isGranted = false
    private(set) var status = L10n.text("尚未申请后台处理")

    init(title: String, requiresGPU: Bool, onExpiration: @escaping () -> Void, onChange: @escaping () -> Void = {}) {
        self.title = title
        self.requiresGPU = requiresGPU
        self.onExpiration = onExpiration
        self.onChange = onChange
    }

    static var supportsGPU: Bool {
        if #available(iOS 26.0, *) { return BGTaskScheduler.supportedResources.contains(.gpu) }
        return false
    }

    func begin() {
        guard identifier == nil else { return }
        guard #available(iOS 26.0, *) else { unavailable("系统不支持持续后台处理，请保持 App 在前台。"); return }
        guard !requiresGPU || Self.supportsGPU else {
            unavailable("此设备未开放后台 GPU，计算需保持前台；训练切后台会保存进度并暂停。")
            return
        }
        guard UIApplication.shared.applicationState == .active, let bundle = Bundle.main.bundleIdentifier else {
            unavailable("请返回 App 后开始处理，以申请后台运行。"); return
        }
        let id = "\(bundle).reconstruction.\(UUID().uuidString)"
        identifier = id
        expired = false
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.identifier == id, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.task = task
                self.isGranted = true
                self.status = L10n.text("已获准后台处理，可以切换到其他 App。")
                task.progress.totalUnitCount = 1000
                task.progress.completedUnitCount = Int64(self.fraction * 1000)
                task.updateTitle(self.title, subtitle: self.subtitle.isEmpty ? self.status : self.subtitle)
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.identifier == id, !self.expired else { return }
                        self.expired = true
                        self.isGranted = false
                        self.status = L10n.text("后台任务已结束，正在保存进度或停止处理。")
                        BackgroundProcessingDiagnostics.record("expired", title: self.title)
                        self.onChange()
                        self.onExpiration()
                    }
                }
                BackgroundProcessingDiagnostics.record("granted", title: self.title)
                self.onChange()
            }
        }
        guard registered else {
            identifier = nil
            unavailable("无法申请后台任务，请保持 App 在前台。"); return
        }
        status = L10n.text("正在申请后台处理，请暂时保持前台。")
        onChange()
        // Create/configure while the user action is still foregrounded. The immutable
        // envelope transfers the request to the scheduler's non-main submission call.
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: status)
        request.strategy = .fail
        if requiresGPU { request.requiredResources = .gpu }
        let envelope = ProcessingRequestEnvelope(request)
        let title = title
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                #if compiler(>=6.4)
                if #available(iOS 27.0, *) { try await BGTaskScheduler.shared.submitTaskRequest(envelope.request) }
                else { try BGTaskScheduler.shared.submit(envelope.request) }
                #else
                try BGTaskScheduler.shared.submit(envelope.request)
                #endif
                await MainActor.run {
                    if self.identifier != id { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id) }
                }
            } catch {
                await MainActor.run {
                    guard self.identifier == id else { return }
                    self.identifier = nil
                    self.unavailable("系统未批准后台运行，请保持 App 在前台。")
                    BackgroundProcessingDiagnostics.record("submissionFailed", title: title, detail: String(describing: error))
                }
            }
        }
    }

    func report(fraction: Double, subtitle: String) {
        guard fraction.isFinite else { return }
        self.fraction = max(self.fraction, min(0.999, max(0, fraction)))
        self.subtitle = subtitle
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask, !expired {
            task.progress.completedUnitCount = Int64(self.fraction * 1000)
            task.updateTitle(title, subtitle: subtitle)
        }
        BackgroundProcessingDiagnostics.progress(title: title, fraction: self.fraction)
    }

    func finish(success: Bool) {
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            if success && !expired { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success && !expired)
        }
        BackgroundProcessingDiagnostics.record(success && !expired ? "completed" : "stopped", title: title)
        identifier = nil
        task = nil
        isGranted = false
        onChange()
    }

    private func unavailable(_ key: LocalizedMessage) {
        // Keys are declared literally at call sites and mirrored in the language resources.
        status = L10n.text(key)
        BackgroundProcessingDiagnostics.record("unavailable", title: title, detail: status)
        onChange()
    }
}

/// Small local diagnostics for physical-device validation; contains no images or account data.
@MainActor
enum BackgroundProcessingDiagnostics {
    private static var events: [[String: Any]] = []
    private static var lastProgress: [String: Double] = [:]
    static func record(_ event: String, title: String = "", detail: String = "") {
        events.append(["event": event, "title": title, "detail": detail,
                       "time": ISO8601DateFormatter().string(from: Date()),
                       "background": UIApplication.shared.applicationState == .background])
        if events.count > 100 { events.removeFirst(events.count - 100) }
        let value: [String: Any] = ["gpuSupported": ContinuedProcessingLease.supportsGPU,
                                   "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                   "events": events]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: documents.appendingPathComponent("background-processing.json"), options: .atomic)
    }
    static func progress(title: String, fraction: Double) {
        guard UIApplication.shared.applicationState == .background,
              fraction - (lastProgress[title] ?? -0.1) >= 0.05 else { return }
        lastProgress[title] = fraction
        record("backgroundProgress", title: title, detail: String(format: "%.3f", fraction))
    }
}

@available(iOS 26.0, *)
nonisolated private final class ProcessingRequestEnvelope: @unchecked Sendable {
    // Configured before transfer; never mutated by application code after initialization.
    let request: BGContinuedProcessingTaskRequest
    init(_ request: BGContinuedProcessingTaskRequest) { self.request = request }
}
