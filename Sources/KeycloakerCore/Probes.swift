import Foundation
import Network

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

public enum Probes {
    /// Plain TCP connect, bypassing proxies: the same path kubectl takes to its proxy-url.
    /// Returns the connect latency, or nil when unreachable.
    public static func tcp(host: String, port: Int, timeout: TimeInterval = 4) async -> TimeInterval? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let params = NWParameters.tcp
        params.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let start = Date()
        let once = OnceFlag()
        return await withCheckedContinuation { cont in
            let finish: @Sendable (TimeInterval?) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                cont.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Date().timeIntervalSince(start))
                case .failed, .waiting, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Loads the Zscaler check page through the system proxy settings (PAC included),
    /// i.e. the way browsers and other apps reach the internet.
    public static func zscaler(url: URL, timeout: TimeInterval = 8) async -> ZscalerRouting {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, _) = try? await session.data(from: url) else { return .unknown }
        return ZscalerRouting.parse(html: String(decoding: data, as: UTF8.self))
    }
}
