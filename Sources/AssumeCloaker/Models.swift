import AppKit
import CloakerCore
import SwiftUI

/// Traffic light. Raw value is severity, so `max()` gives the worst.
enum Light: Int, Comparable {
    case green = 0, gray, yellow, red

    static func < (a: Light, b: Light) -> Bool { a.rawValue < b.rawValue }

    var nsColor: NSColor {
        switch self {
        case .green: .systemGreen
        case .yellow: .systemOrange
        case .red: .systemRed
        case .gray: .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// A network prerequisite as shown in the UI.
struct Check: Equatable {
    var light: Light = .gray
    var title: String = "Checking…"
    var detail: String?
}

/// Runtime state of one environment.
struct EnvSession: Equatable {
    /// Credentials for this env are present (Keycloak: profile holds this account; SSO: last probe succeeded).
    var valid = false
    var expiresAt: Date?
    var identity: String?
    /// SSO: the CLI holds a refresh token, so the access token renews itself.
    var autoRenewable = false
    var needsSignIn = false
    var operation: String?
    var error: String?
    var failures = 0
    var nextAttempt: Date?
    var lastProbe: Date?

    func remaining(at now: Date) -> TimeInterval? { expiresAt.map { $0.timeIntervalSince(now) } }

    func light(kind: EnvKind, now: Date, warn: TimeInterval, renewing: Bool) -> Light {
        if operation != nil { return .yellow }
        if needsSignIn { return .red }
        switch kind {
        case .keycloak:
            guard valid, let left = remaining(at: now) else { return error == nil ? .gray : .red }
            if left <= 0 { return .red }
            return left < warn && !renewing ? .yellow : .green
        case .sso:
            if valid { return .green }
            if let left = remaining(at: now), left > 0 { return .green }
            return error == nil ? .gray : .red
        }
    }

    func statusText(kind: EnvKind, now: Date) -> String {
        if let operation { return operation }
        if needsSignIn { return "Sign-in required" }
        if failures >= ConnectionManager.maxAutoFailures { return "Auto-renew paused" }
        switch kind {
        case .keycloak:
            guard valid, let left = remaining(at: now) else { return error.map { _ in "Failed" } ?? "Not connected" }
            return left <= 0 ? "Expired" : Fmt.remaining(left)
        case .sso:
            if valid { return autoRenewable ? "Active · auto-renews" : "Active" }
            if let left = remaining(at: now), left > 0 { return Fmt.remaining(left) }
            return error.map { _ in "Failed" } ?? "Signed out"
        }
    }
}

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
    let isError: Bool
}

enum Fmt {
    static func remaining(_ t: TimeInterval) -> String {
        if t <= 0 { return "expired" }
        let s = Int(t)
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    static func clock(_ d: Date) -> String {
        d.formatted(date: Calendar.current.isDateInToday(d) ? .omitted : .abbreviated, time: .shortened)
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .standard) }
}
