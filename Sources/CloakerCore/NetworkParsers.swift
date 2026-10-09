import Foundation

/// Parsed `trac info` output from Check Point Endpoint Security VPN.
public struct CheckPointStatus: Equatable, Sendable {
    public struct Site: Equatable, Sendable {
        public var name: String
        public var status: String
        public var active: Bool
        public var gateway: String?
    }

    public var sites: [Site]

    public var connectedSite: Site? { sites.first { Self.isConnected($0.status) } }
    public var connectingSite: Site? { sites.first { Self.isConnecting($0.status) } }
    public var activeSite: Site? { sites.first(where: \.active) }
    public var isConnected: Bool { connectedSite != nil }

    static func isConnected(_ status: String) -> Bool {
        let s = status.lowercased()
        return s == "connected" || (s.contains("connected") && !s.contains("disconnect") && !s.contains("connecting"))
    }

    static func isConnecting(_ status: String) -> Bool {
        status.lowercased().contains("connecting")
    }

    public static func parse(_ text: String) -> CheckPointStatus {
        var sites: [Site] = []
        var current: Site?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Conn "), line.hasSuffix(":") {
                if let c = current { sites.append(c) }
                current = Site(name: String(line.dropFirst(5).dropLast()).trimmingCharacters(in: .whitespaces),
                               status: "", active: false)
            } else if line.hasPrefix("status:") {
                current?.status = line.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("active site:") {
                current?.active = line.hasSuffix("true")
            } else if line.hasPrefix("gw:") {
                current?.gateway = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            }
        }
        if let c = current { sites.append(c) }
        return CheckPointStatus(sites: sites)
    }
}

/// Result of loading http://ip.zscaler.com through the system proxy (PAC).
public enum ZscalerRouting: Equatable, Sendable {
    case routed(cloud: String)
    case notRouted
    case unknown

    public static func parse(html: String) -> ZscalerRouting {
        let text = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if text.range(of: "not going through the Zscaler", options: .caseInsensitive) != nil {
            return .notRouted
        }
        guard text.range(of: "accessing the Internet via Zscaler", options: .caseInsensitive) != nil else {
            return .unknown
        }
        // "You are accessing the Internet via Zscaler Cloud: Marseille I in the zscloud.net cloud."
        if let r = text.range(of: #"via Zscaler Cloud:\s*(.+?)\s+in the\s+\S+\s+cloud"#,
                              options: [.regularExpression, .caseInsensitive]) {
            let match = String(text[r])
            let cloud = match
                .replacingOccurrences(of: #"(?i)via Zscaler Cloud:\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\s+in the\s+\S+\s+cloud$"#, with: "", options: .regularExpression)
            return .routed(cloud: cloud)
        }
        return .routed(cloud: "Zscaler")
    }
}
