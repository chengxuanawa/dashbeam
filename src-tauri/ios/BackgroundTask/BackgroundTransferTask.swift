import BackgroundTasks
import Foundation

private let backgroundTaskSuffix = ".bg-transfer"

private final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Bridges the Rust transfer lifecycle into a `BGContinuedProcessingTask`.
///
/// The task only keeps the process alive and mirrors progress into the system
/// UI. The transfer itself still runs in the Rust engine.
@available(iOS 26.0, *)
final class BackgroundTransferTask: @unchecked Sendable {
    static let shared = BackgroundTransferTask()

    private let lock = NSLock()
    private var registered = false
    private var active = false
    private var succeeded = false
    private var completed: Int64 = 0
    private var total: Int64 = 0
    private var task: BGContinuedProcessingTask?

    private var identifier: String {
        (Bundle.main.bundleIdentifier ?? "com.dashbeam.desktop") + backgroundTaskSuffix
    }

    func registerIfNeeded() {
        assert(Thread.isMainThread)
        guard !registered else { return }
        registered = true

        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {
            [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.run(task)
        }
        if !ok {
            NSLog("DashBeam: failed to register background task \(identifier)")
        }
    }

    func start(title: String, subtitle: String) {
        lock.lock()
        if active {
            lock.unlock()
            return
        }
        active = true
        succeeded = false
        completed = 0
        total = 0
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillActive = self.active
            self.lock.unlock()
            guard stillActive else { return }

            self.registerIfNeeded()

            let request = BGContinuedProcessingTaskRequest(
                identifier: self.identifier,
                title: title,
                subtitle: subtitle
            )
            request.strategy = .queue

            // A completed foreground transfer may have left a request pending.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.identifier)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                NSLog("DashBeam: failed to submit background transfer task: \(error)")
            }
        }
    }

    func update(completed: Int64, total: Int64) {
        lock.lock()
        self.completed = max(completed, 0)
        self.total = max(total, 0)
        let task = self.task
        let done = self.completed
        let all = self.total
        lock.unlock()

        guard let task else { return }
        let total = max(all, 1)
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = min(max(done, 0), total)
    }

    func finish(success: Bool) {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        succeeded = success
        let task = self.task
        lock.unlock()

        // No handler yet: this was a foreground-only transfer. Drop the request
        // instead of leaving it queued for the next backgrounding.
        if task == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.identifier)
            }
        }
    }

    private func run(_ task: BGContinuedProcessingTask) {
        lock.lock()
        self.task = task
        let total = max(self.total, 1)
        let completed = min(max(self.completed, 0), total)
        lock.unlock()

        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed

        let expired = ExpirationFlag()
        task.expirationHandler = {
            expired.set()
        }

        var lastPercent = -1
        while true {
            lock.lock()
            let isActive = active
            let done = self.completed
            let all = self.total
            lock.unlock()

            if !isActive || expired.get() {
                break
            }

            let total = max(all, 1)
            let completed = min(max(done, 0), total)
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = completed

            let percent = Int((Double(completed) / Double(total)) * 100)
            if percent != lastPercent {
                lastPercent = percent
                task.updateTitle(task.title, subtitle: "\(percent)%")
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        lock.lock()
        let success = !expired.get() && !active && succeeded
        self.task = nil
        lock.unlock()

        task.setTaskCompleted(success: success)
    }
}

@_cdecl("dashbeam_bg_register")
public func dashbeam_bg_register() {
    if #available(iOS 26.0, *) {
        if Thread.isMainThread {
            BackgroundTransferTask.shared.registerIfNeeded()
        } else {
            DispatchQueue.main.async {
                BackgroundTransferTask.shared.registerIfNeeded()
            }
        }
    }
}

@_cdecl("dashbeam_bg_start")
public func dashbeam_bg_start(_ title: UnsafePointer<CChar>?, _ subtitle: UnsafePointer<CChar>?) {
    if #available(iOS 26.0, *) {
        let title = title.map { String(cString: $0) } ?? "DashBeam"
        let subtitle = subtitle.map { String(cString: $0) } ?? "Transferring files…"
        BackgroundTransferTask.shared.start(title: title, subtitle: subtitle)
    }
}

@_cdecl("dashbeam_bg_update")
public func dashbeam_bg_update(_ completed: UInt64, _ total: UInt64) {
    if #available(iOS 26.0, *) {
        BackgroundTransferTask.shared.update(completed: Int64(completed), total: Int64(total))
    }
}

@_cdecl("dashbeam_bg_finish")
public func dashbeam_bg_finish(_ success: Bool) {
    if #available(iOS 26.0, *) {
        BackgroundTransferTask.shared.finish(success: success)
    }
}
