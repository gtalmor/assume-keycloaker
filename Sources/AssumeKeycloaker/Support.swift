import AppKit
import KeycloakerCore
import UserNotifications

/// macOS notifications. Clicking one runs its action (retry an env, sign in, connect the VPN).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let connectVPNAction = "connect-vpn"
    static let updateAction = "install-update"

    /// Called with the notification's action: an env id (retry / sign in) or `connectVPNAction`.
    var onAction: ((String) -> Void)?
    var enabled = true

    /// UNUserNotificationCenter crashes outside an .app bundle (e.g. `swift run`).
    private var available: Bool { enabled && Bundle.main.bundleURL.pathExtension == "app" }

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, action: String? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let action { content.userInfo = ["action": action] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let action = response.notification.request.content.userInfo["action"] as? String else { return }
        await MainActor.run { self.onAction?(action) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Appends the activity log to ~/Library/Logs/AssumeKeycloaker/assume-keycloaker.log (rotated at 2 MB).
final class LogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "assume-keycloaker.log")
    private var handle: FileHandle?
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    func write(_ line: LogLine) {
        let text = "\(stamp.string(from: line.date)) \(line.isError ? "ERROR " : "")\(line.text)\n"
        queue.async { [self] in
            if handle == nil { open() }
            handle?.write(Data(text.utf8))
            if let size = try? handle?.offset(), size > 2_000_000 { rotate() }
        }
    }

    func flush() { queue.sync { try? handle?.synchronize() } }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.logFile.path) { fm.createFile(atPath: Paths.logFile.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: Paths.logFile)
        _ = try? handle?.seekToEnd()
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = Paths.logDir.appending(path: "assume-keycloaker.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: Paths.logFile, to: old)
        open()
    }
}
