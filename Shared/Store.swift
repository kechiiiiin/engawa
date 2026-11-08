import Foundation

// 本体と4つの拡張で共有するもの（Foundation だけに依存）。
// App Group のコンテナにファイルとして置く。UserDefaults(suiteName:) はプロセス間でキャッシュがずれるので使わない。
// ファイル保護は「最初のロック解除まで」（ロック中の拡張から読めるように）。

enum Engawa {
    static let appGroup = "group.jp.kechiiiiin.engawa"
    static let logLimit = 2000
}

// MARK: - App Group のファイル置き場

enum Store {
    /// App Group のコンテナが取れているか（false なら dir は一時フォルダ）
    static var hasAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Engawa.appGroup) != nil
    }

    static var dir: URL {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: Engawa.appGroup)
            ?? fm.temporaryDirectory
        let d = base.appendingPathComponent("engawa", isDirectory: true)
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        return d
    }

    static func url(_ key: String) -> URL { dir.appendingPathComponent(key) }

    static func data(_ key: String) -> Data? { try? Data(contentsOf: url(key)) }

    static func setData(_ key: String, _ d: Data?) {
        let u = url(key)
        guard let d else { try? FileManager.default.removeItem(at: u); return }
        try? d.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func string(_ key: String) -> String? {
        data(key).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setString(_ key: String, _ s: String?) { setData(key, s.map { Data($0.utf8) }) }

    static func codable<T: Decodable>(_ key: String, as: T.Type) -> T? {
        data(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func setCodable<T: Encodable>(_ key: String, _ v: T?) {
        setData(key, v.flatMap { try? JSONEncoder().encode($0) })
    }
}

// MARK: - 時刻

enum ISO {
    static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func string(_ d: Date) -> String { fmt.string(from: d) }
    static func parse(_ s: String) -> Date? { fmt.date(from: s) ?? plain.date(from: s) }
    static var now: String { string(Date()) }
}

// MARK: - 記録（JSON Lines）

struct LogRecord: Codable, Identifiable {
    var id: String = UUID().uuidString
    var ts: String = ISO.now
    var proc: String = LogRecord.currentProc
    var kind: String
    var route: String? = nil
    var version: Int? = nil
    var locked: Bool? = nil
    var serverChangedAt: String? = nil
    var appliedAt: String? = nil
    var ok: Bool? = nil
    var error: String? = nil
    var detail: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, ts, proc, kind, route, version, locked, serverChangedAt, appliedAt, ok, error, detail
    }

    // 受け入れ条件25: kind/route/version/serverChangedAt/appliedAt/ok/error は値が無くても null で必ず出す
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ts, forKey: .ts)
        try c.encode(proc, forKey: .proc)
        try c.encode(kind, forKey: .kind)
        try c.encode(route, forKey: .route)
        try c.encode(version, forKey: .version)
        try c.encode(locked, forKey: .locked)
        try c.encode(serverChangedAt, forKey: .serverChangedAt)
        try c.encode(appliedAt, forKey: .appliedAt)
        try c.encode(ok, forKey: .ok)
        try c.encode(error, forKey: .error)
        try c.encodeIfPresent(detail, forKey: .detail)
    }

    static var currentProc: String {
        let id = Bundle.main.bundleIdentifier ?? "?"
        if id.hasSuffix(".monitor") { return "monitor" }
        if id.hasSuffix(".shieldconfig") { return "shieldConfig" }
        if id.hasSuffix(".shieldaction") { return "shieldAction" }
        if id.hasSuffix(".push") { return "push" }
        return "app"
    }
}

enum Log {
    // 端末の中だけの記録（2026-11-08 §9.8 C からサーバーへは送らない）。複数プロセス（本体・拡張）が同じ App Group に書くので:
    //   - 追記は O_APPEND の fd で1回の write（行が混ざらない）
    //   - log.jsonl の trim は本体だけが行う
    //   - 本体が開かれないあいだ増え続けないよう、拡張は localLogLimit を超えたら足さない（次の起動で本体が trim する）
    //   旧版の送信待ち（outbox-*.jsonl・pending-unlocks/）は読まない・増えない（消しもしない）
    static var logURL: URL { Store.url("log.jsonl") }
    static let queue = DispatchQueue(label: "engawa.log")
    static let localLogLimit = 2_000_000

    static func add(_ r: LogRecord) {
        guard let line = try? JSONEncoder().encode(r) else { return }
        var d = line
        d.append(0x0A)
        queue.sync {
            if r.proc == "app" || fileSize(logURL) < localLogLimit { appendLine(d, to: logURL) }
            if r.proc == "app" { trimIfNeeded(logURL, keep: Engawa.logLimit) }
        }
    }

    static func add(kind: String, route: String? = nil, ok: Bool? = nil, error: String? = nil, detail: String? = nil) {
        add(LogRecord(kind: kind, route: route, ok: ok, error: error, detail: detail))
    }

    /// O_APPEND で開いて1回で書く。新しく作ったときだけファイル保護を付ける
    private static func appendLine(_ d: Data, to u: URL) {
        let existed = FileManager.default.fileExists(atPath: u.path)
        let fd = open(u.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if !existed {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: u.path)
        }
        d.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(fd, base, buf.count)
        }
    }

    private static func fileSize(_ u: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
    }

    /// keep 行を超えたら古いものから捨てる。毎回数えると重いので、大きさで当たりを付けてから数える
    private static func trimIfNeeded(_ u: URL, keep: Int) {
        guard fileSize(u) > keep * 200, let d = try? Data(contentsOf: u) else { return }
        let lines = d.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > keep else { return }
        var out = Data()
        for l in lines.suffix(keep) { out.append(contentsOf: l); out.append(0x0A) }
        try? out.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 本体が起動・前面に来たときに呼ぶ
    static func trimLog() { queue.sync { trimIfNeeded(logURL, keep: Engawa.logLimit) } }
}
