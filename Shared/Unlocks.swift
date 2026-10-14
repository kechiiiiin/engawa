import Foundation

// 縁側アプリからの時間解除の記録（理由つき）。サーバーの POST /unlocks へ送る。
// 届かなかったら App Group の pending-unlocks/ に1件1ファイルで残し、次に本体が Log.flush するときに送り直す。
// サーバーは id で重複を捨てるので、2つのプロセスが同じものを送っても害はない。

struct UnlockRecord: Codable, Equatable {
    var id: String
    /// 押した時刻
    var at: String
    var minutes: Int
    var until: String
    /// 理由（必須・2000字まで。コードポイントで数える）
    var reason: String
    /// そのときのロックの理由（none／manual／quota／manualAndQuota）
    var lockReason: String
    /// 今日の使用時間（推定・分）
    var usedMinutes: Int
    var quotaMinutes: Int
}

enum Unlocks {
    /// 理由の上限（Unicode のコードポイントで数える。サーバーの [...reason].length と同じ）
    static let reasonLimit = 2000

    static func reasonLength(_ s: String) -> Int { s.unicodeScalars.count }

    /// 前後の空白を除き、上限で切る（コードポイント単位）
    static func normalizeReason(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: t.unicodeScalars.prefix(reasonLimit))
        return String(out)
    }
    static let minuteChoices = [15, 30, 60]

    static var dir: URL {
        let d = Store.dir.appendingPathComponent("pending-unlocks", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(
                at: d, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        return d
    }

    static func enqueue(_ r: UnlockRecord) {
        guard let d = try? JSONEncoder().encode(r) else { return }
        try? d.write(to: dir.appendingPathComponent("\(r.id).json"),
                     options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static var pendingCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.count) ?? 0
    }

    /// 溜まっている解除の記録を送る。2xx か 400（直しようがない）なら消す。
    /// それ以外は次に持ち越し、最初の失敗で打ち切る（つながらないときに1件ごとに待たない）
    @discardableResult
    static func flush(timeout: TimeInterval = 4) -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".json") }).sorted(),
              !names.isEmpty else { return "送るものなし" }
        var sent = 0, kept = 0
        for n in names {
            let u = dir.appendingPathComponent(n)
            guard let body = try? Data(contentsOf: u) else { continue }
            switch Net.request("POST", "/unlocks", body: body, timeout: timeout) {
            case .success(let (code, _)) where (200..<300).contains(code):
                try? fm.removeItem(at: u)
                sent += 1
            case .success(let (code, _)) where code == 400:
                try? fm.removeItem(at: u)
                Log.add(kind: "unlockSend", ok: false, error: "HTTP 400（捨てた）", detail: n)
            case .success(let (code, _)):
                kept = names.count - sent
                Log.add(kind: "unlockSend", ok: false, error: "HTTP \(code)（以降 \(kept) 件を持ち越し）", detail: n)
            case .failure(let e):
                kept = names.count - sent
                Log.add(kind: "unlockSend", ok: false, error: "\(e.localizedDescription)（以降 \(kept) 件を持ち越し）", detail: n)
            }
            if kept > 0 { break }
        }
        return "\(sent) 件送った" + (kept > 0 ? "・\(kept) 件持ち越し" : "")
    }
}
