import Foundation

/// A value asked for when a snippet is copied: `{name}` in the text, with a default.
public struct SnippetVariable: Codable, Hashable, Sendable {
    public var name: String
    public var defaultValue: String
    /// Values entered before, newest first (a few).
    public var recent: [String]

    public init(name: String, defaultValue: String = "", recent: [String] = []) {
        self.name = name
        self.defaultValue = defaultValue
        self.recent = recent
    }

    enum CodingKeys: String, CodingKey { case name, defaultValue = "default", recent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? []
    }

    /// What the prompt starts with: the last value used, else the default.
    public var initialValue: String { recent.first ?? defaultValue }
}

/// A pinned piece of text the panel copies to the clipboard: a command, a k9s filter, a URL.
/// `{profile}`-style fill-ins come from the active environment; its own `{variables}` are asked for.
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String?
    public var text: String
    public var variables: [SnippetVariable]

    public init(id: String = UUID().uuidString, title: String? = nil, text: String, variables: [SnippetVariable] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.variables = variables
    }

    enum CodingKeys: String, CodingKey { case id, title, text, variables }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        variables = try c.decodeIfPresent([SnippetVariable].self, forKey: .variables) ?? []
    }

    public var hasTitle: Bool { !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// The title, or else the text's first line.
    public var label: String {
        if hasTitle, let title { return title }
        return firstLine
    }

    public var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    public var lineCount: Int { text.split(whereSeparator: \.isNewline).count }

    /// Fill-ins replaced with the active environment's values when copying.
    public static let fields = ["env", "profile", "region", "cluster", "account", "context"]

    public static func token(_ name: String) -> String { "{\(name)}" }

    /// The variables that appear in the text (the ones the prompt asks for).
    public var activeVariables: [SnippetVariable] { variables.filter { text.contains(Self.token($0.name)) } }

    /// The text with variables (from `values`, else their defaults) and then `{profile}`, `{region}`, …
    /// filled in. Unknown braces (jsonpath, templates) stay.
    public func filled(env: EnvConfig?, account: String?, context: String?, values: [String: String] = [:]) -> String {
        var out = text
        for v in variables {
            out = out.replacingOccurrences(of: Self.token(v.name), with: values[v.name] ?? v.defaultValue)
        }
        guard let env else { return out }
        let fills: [String: String?] = ["env": env.id, "profile": env.profile, "region": env.region,
                                        "cluster": env.cluster, "account": account ?? env.account, "context": context]
        for (name, value) in fills {
            if let value { out = out.replacingOccurrences(of: Self.token(name), with: value) }
        }
        return out
    }

    // MARK: Editing

    /// `{word}` tokens in the text that are neither fill-ins nor variables yet.
    public var undeclaredTokens: [String] {
        let declared = Set(variables.map(\.name))
        var out: [String] = []
        for (name, _) in Self.tokens(in: text) where !Self.fields.contains(name) && !declared.contains(name) && !out.contains(name) {
            out.append(name)
        }
        return out
    }

    /// Why `range` can't become a variable, or nil if it can.
    public func problem(selecting range: Range<String.Index>) -> String? {
        let value = text[range]
        if value.trimmingCharacters(in: .whitespaces).isEmpty { return "Select some text first" }
        if value.contains(where: \.isNewline) { return "Select within one line" }
        if Self.tokens(in: text).contains(where: { $0.range.overlaps(range) }) { return "That overlaps a {variable}" }
        return nil
    }

    /// Why `name` can't be a new variable's name, or nil if it can.
    public func problem(naming name: String) -> String? {
        if !Self.isValidName(name) { return "Use letters, digits, - or _ (starting with a letter)" }
        if Self.fields.contains(name) { return "{\(name)} comes from the active environment" }
        if variables.contains(where: { $0.name == name }) { return "There's already a {\(name)}" }
        return nil
    }

    /// Turns the selected text into `{name}`, with the selected text as its default.
    @discardableResult
    public mutating func makeVariable(_ range: Range<String.Index>, name: String) -> Bool {
        guard problem(selecting: range) == nil, problem(naming: name) == nil else { return false }
        let value = String(text[range])
        text.replaceSubrange(range, with: Self.token(name))
        variables.append(SnippetVariable(name: name, defaultValue: value))
        return true
    }

    /// Declares a `{name}` already typed in the text.
    @discardableResult
    public mutating func declareVariable(_ name: String, defaultValue: String = "") -> Bool {
        guard problem(naming: name) == nil else { return false }
        variables.append(SnippetVariable(name: name, defaultValue: defaultValue))
        return true
    }

    /// Puts a fill-in such as `{region}` in place of `range`.
    public mutating func insertField(_ name: String, at range: Range<String.Index>) {
        text.replaceSubrange(range, with: Self.token(name))
    }

    /// Back to plain text: `{name}` becomes its default again.
    public mutating func removeVariable(_ name: String) {
        guard let v = variables.first(where: { $0.name == name }) else { return }
        text = text.replacingOccurrences(of: Self.token(name), with: v.defaultValue)
        variables.removeAll { $0.name == name }
    }

    public mutating func setDefault(_ value: String, for name: String) {
        guard let i = variables.firstIndex(where: { $0.name == name }) else { return }
        variables[i].defaultValue = value
    }

    /// Keeps the values just used at the top of each variable's recent list.
    public mutating func remember(_ values: [String: String]) {
        for i in variables.indices {
            guard let value = values[variables[i].name] else { continue }
            variables[i].recent = Array(([value] + variables[i].recent.filter { $0 != value }).prefix(5))
        }
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter, name.count <= 32 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// A name for the variable made from `range`: from the flag before it (`-n web` → namespace,
    /// `--tail 100` → tail) or the key (`app=api` → app). `field` is set when that name is one of the
    /// environment fill-ins (`--region us-east-1`), which may be what's wanted instead.
    public func suggestion(for range: Range<String.Index>) -> (name: String, field: String?) {
        let before = text[..<range.lowerBound]
        var base = ""
        if before.last == "=" {
            base = String(before.dropLast().reversed().prefix { !$0.isWhitespace }.reversed())
        } else if before.last == " " || before.last == "\t",
                  let flag = before.split(whereSeparator: { $0 == " " || $0 == "\t" }).last, flag.hasPrefix("-") {
            base = String(flag)
        }
        base = String(base.drop { $0 == "-" }).lowercased()
        let short = ["n": "namespace", "c": "container", "l": "selector", "o": "output", "f": "file", "p": "port"]
        base = short[base] ?? base
        base = String(base.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "-" })
        if !Self.isValidName(base) { base = "value" }
        let field = Self.fields.contains(base) ? base : nil
        var name = base, n = 2
        while problem(naming: name) != nil {
            name = "\(base)\(n)"
            n += 1
        }
        return (name, field)
    }

    /// Every `{word}` in `text`, with where it is.
    public static func tokens(in text: String) -> [(name: String, range: Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        var i = text.startIndex
        while let open = text[i...].firstIndex(of: "{") {
            let afterOpen = text.index(after: open)
            guard let close = text[afterOpen...].firstIndex(where: { $0 == "}" || $0 == "{" }) else { break }
            if text[close] == "}" {
                let name = String(text[afterOpen..<close])
                if isValidName(name) { out.append((name, open..<text.index(after: close))) }
                i = text.index(after: close)
            } else {
                i = close
            }
        }
        return out
    }
}

/// Personal snippets, on this Mac only: `snippets.json`, readable by the owner only.
public enum SnippetStore {
    struct File: Codable { var snippets: [Snippet] }

    public static var file: URL { Paths.configDir.appending(path: "snippets.json") }

    public static func load(_ url: URL = file) -> [Snippet] {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return f.snippets
    }

    public static func save(_ snippets: [Snippet], to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(snippets: snippets)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
