import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Last meaningful line, for one-line error messages.
    public var summary: String {
        let text = (stderr.isEmpty ? stdout : stderr)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if timedOut { return "timed out" }
        return lines.last(where: { $0.lowercased().contains("error") }) ?? lines.last ?? "exit \(exitCode)"
    }
}

public struct ToolError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs CLI tools without a TTY, with a sane PATH (GUI apps don't inherit the shell's).
public struct ProcessRunner: Sendable {
    public var searchPaths: [String]
    public var log: @Sendable (String) -> Void

    public init(extraPaths: [String] = [], log: @escaping @Sendable (String) -> Void = { _ in }) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.searchPaths = extraPaths + [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        self.log = log
    }

    public func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        return searchPaths.lazy.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var environment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        // Deliberately no AWS_* passthrough: profiles are always passed explicitly.
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SSH_AUTH_SOCK", "KUBECONFIG"] {
            if let v = inherited[key] { env[key] = v }
        }
        env["PATH"] = searchPaths.joined(separator: ":")
        env["AWS_PAGER"] = ""
        return env
    }

    /// - Parameter redact: argument values never written to the log (e.g. the MFA code).
    public func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60,
                    extraEnv: [String: String] = [:], redact: Set<String> = [],
                    quiet: Bool = false) async throws -> ProcessResult {
        guard let path = which(tool) else { throw ToolError("\(tool) not found in \(searchPaths.joined(separator: ":"))") }
        if !quiet {
            let shown = args.map { redact.contains($0) ? "******" : ($0.contains(" ") ? "\"\($0)\"" : $0) }
            log("$ \(URL(filePath: path).lastPathComponent) \(shown.joined(separator: " "))")
        }
        let env = environment.merging(extraEnv) { _, new in new }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try Self.runSync(path: path, args: args, env: env, timeout: timeout) })
            }
        }
    }

    private static func runSync(path: String, args: [String], env: [String: String],
                                timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = args
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // Drain both pipes concurrently so a chatty tool can't block on a full buffer.
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        // A grandchild (e.g. `open` launched by aws sso login) may hold the pipes; don't wait forever.
        _ = group.wait(timeout: .now() + 5)
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}
