import Foundation

// 本体と4つの拡張で共有するもの（Foundation だけに依存）。
// App Group のコンテナにファイルとして置く。UserDefaults(suiteName:) はプロセス間でキャッシュがずれるので使わない。
// ファイル保護は「最初のロック解除まで」（ロック中の拡張から読めるように）。

enum Engawa {
    static let appGroup = "group.jp.kechiiiiin.engawa"
    static let logLimit = 2000
}

// MARK: - 経路のオン・オフ

struct Routes: Codable, Equatable {
    var poll = false        // R4 予定の目覚まし
    var usageWake = false   // R5 使用量の目覚まし
    var silentPush = true   // R2 サイレントプッシュ
    var alertPush = true    // R3 alert プッシュ＋NSE
    var thresholdLock = false // 試験2: E-all のしきい値でロックを掛ける（既定はオフ・記録だけ）

    static let names = ["poll", "usageWake", "silentPush", "alertPush", "thresholdLock"]

    /// "poll,alertPush" のような並びで、書かれたものだけオンにする
    init(csv: String) {
        let on = Set(csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        poll = on.contains("poll")
        usageWake = on.contains("usageWake")
        silentPush = on.contains("silentPush")
        alertPush = on.contains("alertPush")
        thresholdLock = on.contains("thresholdLock")
    }
    init() {}

    var summary: String {
        var s: [String] = []
        if silentPush { s.append("R2") }
        if alertPush { s.append("R3") }
        if poll { s.append("R4") }
        if usageWake { s.append("R5") }
        if thresholdLock { s.append("しきい値ロック") }
        return s.isEmpty ? "R1 のみ" : "R1+" + s.joined(separator: "+")
    }
}

// MARK: - サーバーの状態

struct ServerState: Codable, Equatable {
    var version: Int
    var locked: Bool
    var unlockUntil: String?
    var changedAt: String
}

// MARK: - App Group のファイル置き場

enum Store {
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

    // --- 値 ---

    /// サーバーの Bearer トークン（試作なので App Group に置く。本実装では共有 Keychain へ）。値は画面・記録に出さない
    static var token: String? {
        get { string("token").flatMap { $0.isEmpty ? nil : $0 } }
        set { setString("token", newValue) }
    }

    static var serverURL: URL? {
        get {
            if let s = string("serverURL"), !s.isEmpty, let u = URL(string: s) { return u }
            if let s = Bundle.main.object(forInfoDictionaryKey: "EngawaServerURL") as? String, !s.isEmpty {
                return URL(string: s)
            }
            return nil
        }
        set { setString("serverURL", newValue?.absoluteString) }
    }

    static var appliedVersion: Int {
        get { Int(string("appliedVersion") ?? "") ?? 0 }
        set { setString("appliedVersion", String(newValue)) }
    }

    /// 最後に反映した時間解除の終わり（relock の判定に使う）
    static var unlockUntil: Date? {
        get { string("unlockUntil").flatMap(ISO.parse) }
        set { setString("unlockUntil", newValue.map(ISO.string)) }
    }

    /// relock 間隔を登録したときの対象の unlockUntil（古い relock が新しい解除を打ち消さないように）
    static var relockFor: Date? {
        get { string("relockFor").flatMap(ISO.parse) }
        set { setString("relockFor", newValue.map(ISO.string)) }
    }

    static var routes: Routes {
        get { codable("routes.json", as: Routes.self) ?? Routes() }
        set { setCodable("routes.json", newValue) }
    }

    static var usageN: Int {
        get { Int(string("usageN") ?? "") ?? 60 }
        set { setString("usageN", String(newValue)) }
    }

    /// R5 で登録できた最大のイベント数
    static var usageMaxRegistered: Int {
        get { Int(string("usageMaxRegistered") ?? "") ?? 0 }
        set { setString("usageMaxRegistered", String(newValue)) }
    }

    static var lastSync: String? {
        get { string("lastSync") }
        set { setString("lastSync", newValue) }
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
    // 複数プロセス（本体・4拡張）が同じ App Group に書くので:
    //   - 追記は O_APPEND の fd で1回の write（行が混ざらない）
    //   - log.jsonl（画面用）の trim は本体だけが行う
    //   - 未送信分（outbox）はプロセス別のファイル。各プロセスは自分の分だけ消費する
    //     ただし ShieldConfig（ネットワーク不可）と ShieldAction は自分で送らないので、本体が代わりに送る
    static var logURL: URL { Store.url("log.jsonl") }
    static func outboxURL(_ proc: String = LogRecord.currentProc) -> URL { Store.url("outbox-\(proc).jsonl") }
    static func sendingURL(_ proc: String) -> URL { Store.url("outbox-\(proc).sending.jsonl") }
    static let queue = DispatchQueue(label: "engawa.log")
    static let outboxLimit = 5000

    static func add(_ r: LogRecord) {
        guard let line = try? JSONEncoder().encode(r) else { return }
        var d = line
        d.append(0x0A)
        queue.sync {
            appendLine(d, to: logURL)
            let ob = outboxURL(r.proc)
            appendLine(d, to: ob)
            if r.proc == "app" { trimIfNeeded(logURL, keep: Engawa.logLimit) }
            trimIfNeeded(ob, keep: outboxLimit)   // 自分のファイルだけ
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

    /// keep 行を超えたら古いものから捨てる。毎回数えると重いので、大きさで当たりを付けてから数える
    private static func trimIfNeeded(_ u: URL, keep: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        guard size > keep * 200, let d = try? Data(contentsOf: u) else { return }
        let lines = d.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > keep else { return }
        var out = Data()
        for l in lines.suffix(keep) { out.append(contentsOf: l); out.append(0x0A) }
        try? out.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 本体が起動・前面に来たときに呼ぶ
    static func trimLog() { queue.sync { trimIfNeeded(logURL, keep: Engawa.logLimit) } }

    /// 画面に出す用（新しい順）
    static func recent(_ n: Int = 300) -> [LogRecord] {
        guard let d = try? Data(contentsOf: logURL) else { return [] }
        let lines = d.split(separator: 0x0A, omittingEmptySubsequences: true).suffix(n)
        let dec = JSONDecoder()
        return lines.reversed().compactMap { try? dec.decode(LogRecord.self, from: Data($0)) }
    }

    /// 未送信の記録をサーバーへ送る。自分の outbox を rename で取り出して送信待ちに足し、失敗したら次に持ち越す。
    /// 本体からは ShieldConfig／ShieldAction の分も送る
    @discardableResult
    static func flush(timeout: TimeInterval = 4) -> String {
        let me = LogRecord.currentProc
        let procs = me == "app" ? ["app", "shieldConfig", "shieldAction"] : [me]
        return procs.map { p in "\(p): \(flush(proc: p, timeout: timeout))" }.joined(separator: " / ")
    }

    private static func flush(proc: String, timeout: TimeInterval) -> String {
        let fm = FileManager.default
        let sending = sendingURL(proc)
        var payload = Data()
        queue.sync {
            if let old = try? Data(contentsOf: sending) { payload.append(old) }   // 前回の送り残し
            // rename は不可分。追記中の相手は、開いた fd のまま取り出した側のファイルに書く
            let taking = Store.url("outbox-\(proc).taking-\(UUID().uuidString).jsonl")
            if (try? fm.moveItem(at: outboxURL(proc), to: taking)) != nil {
                if let d = try? Data(contentsOf: taking) { payload.append(d) }
                try? payload.write(to: sending, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try? fm.removeItem(at: taking)
            }
        }
        let lines = payload.split(separator: 0x0A, omittingEmptySubsequences: true)
        if lines.isEmpty { try? fm.removeItem(at: sending); return "送るものなし" }
        var body = Data("{\"events\":[".utf8)
        for (i, l) in lines.enumerated() {
            if i > 0 { body.append(0x2C) }
            body.append(contentsOf: l)
        }
        body.append(contentsOf: Data("]}".utf8))
        switch Net.request("POST", "/events", body: body, timeout: timeout) {
        case .success(let (code, _)) where (200..<300).contains(code):
            try? fm.removeItem(at: sending)
            return "\(lines.count) 件送った"
        case .success(let (code, _)):
            return "送信失敗 HTTP \(code)（次に持ち越し）"
        case .failure(let e):
            return "送信失敗 \(e.localizedDescription)（次に持ち越し）"
        }
    }
}

// MARK: - ネットワーク（同期待ち）
// 拡張は同期の処理が返った時点で終了させられる（二次情報）ので、セマフォで待つ形にしている（既定5秒）。
// 本体からはメインスレッド以外で呼ぶこと。

enum NetError: LocalizedError {
    case noServer, noToken, timeout, badResponse
    var errorDescription: String? {
        switch self {
        case .noServer: return "サーバー URL が無い"
        case .noToken: return "トークンが無い"
        case .timeout: return "タイムアウト"
        case .badResponse: return "応答が読めない"
        }
    }
}

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // 拡張の持ち時間に合わせて短めに（Net 5秒・Log.flush 4秒）
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func request(_ method: String, _ path: String, body: Data? = nil,
                        timeout: TimeInterval = 5) -> Result<(Int, Data), Error> {
        guard let base = Store.serverURL else { return .failure(NetError.noServer) }
        guard let token = Store.token else { return .failure(NetError.noToken) }
        guard let url = URL(string: path, relativeTo: base) else { return .failure(NetError.noServer) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(NetError.timeout)
        let task = session.dataTask(with: req) { data, resp, err in
            if let err { result = .failure(err) }
            else if let http = resp as? HTTPURLResponse { result = .success((http.statusCode, data ?? Data())) }
            else { result = .failure(NetError.badResponse) }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure(NetError.timeout)
        }
        return result
    }

    /// GET /state。失敗は記録に残して nil
    static func fetchState(route: String) -> ServerState? {
        switch request("GET", "/state") {
        case .success(let (code, data)) where code == 200:
            if let s = try? JSONDecoder().decode(ServerState.self, from: data) {
                Store.lastSync = ISO.now
                return s
            }
            Log.add(kind: "fetch", route: route, ok: false, error: "state が読めない")
        case .success(let (code, _)):
            Log.add(kind: "fetch", route: route, ok: false, error: "HTTP \(code)")
        case .failure(let e):
            Log.add(kind: "fetch", route: route, ok: false, error: e.localizedDescription)
        }
        return nil
    }
}
