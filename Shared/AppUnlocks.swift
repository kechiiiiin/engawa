import Foundation
import CryptoKit
import FamilyControls
import ManagedSettings

// 2026-10-14 追加の本人判断（本番設計の冒頭）で足した2つ:
//
//   1. アプリ個別の解除（AppUnlocks）: 選んだアプリだけを期限つきで shield の例外に足す。
//      トークンは不透明（アプリ名はコードから読めない）なので、端末の app-unlocks.json にだけ置き、
//      サーバーへは件数と種別（UnlockRecord.kind = "apps"）だけ送る。
//   2. セルフロック（SelfLock）: 時間が来なくても自分でかけるロック。第4の層（手動・枠と同じく、
//      時間解除・個別解除で一時的に外せる）。端末だけで完結し、サーバーの state は変えない。
//
//   どちらも shield を書くのは Shield.reconcile だけ。期限切れはそこで外す（自己修復）。
//   期限の目覚ましは Wake.armExpiryWakes（.appRelock／.selfLockEnd）。

/// 個別解除の1件（アプリ1つ）
struct AppUnlock: Codable, Equatable {
    var token: ApplicationToken
    /// 解除の終わり
    var until: String
    /// どの解除の記録から来たか（UnlockRecord.id）
    var recordId: String

    var untilDate: Date { ISO.parse(until) ?? .distantPast }
}

enum AppUnlocks {
    /// shield の例外にできる上限（許可アプリと合わせて）
    static let limit = 50
    /// 1件1ファイルで置く（pending-unlocks/ と同じ。本体・MonitorExt・PushExt が同時に触っても、
    /// 読んで書き戻すことをしないので取りこぼさない）。add＝作る・prune＝期限切れを消す・clear＝全部消す
    static let dirName = "app-unlocks"
    /// 以前の1ファイル置き（あれば初回に移す）
    static let legacyFile = "app-unlocks.json"

    static var dir: URL {
        let d = Store.dir.appendingPathComponent(dirName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(
                at: d, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        migrateLegacy(into: d)
        return d
    }

    private static func migrateLegacy(into d: URL) {
        guard let old = Store.codable(legacyFile, as: [AppUnlock].self) else {
            if Store.data(legacyFile) != nil { Store.setData(legacyFile, nil) }   // 読めないものは捨てる
            return
        }
        for u in old { write(u, in: d) }
        Store.setData(legacyFile, nil)
        Log.add(kind: "appUnlockMigrate", detail: "app-unlocks.json から \(old.count) 件を移した")
    }

    private static func write(_ u: AppUnlock, in d: URL) {
        guard let data = try? JSONEncoder().encode(u) else { return }
        try? data.write(to: d.appendingPathComponent("\(UUID().uuidString).json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func files() -> [URL] {
        let d = dir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { d.appendingPathComponent($0) }
    }

    private static func entries() -> [(url: URL, unlock: AppUnlock)] {
        files().compactMap { u in
            guard let d = try? Data(contentsOf: u), let v = try? JSONDecoder().decode(AppUnlock.self, from: d) else { return nil }
            return (u, v)
        }
    }

    /// 保存されている全件（期限切れも含む。同じアプリが複数あれば長い方だけ）
    static var all: [AppUnlock] {
        var best: [ApplicationToken: AppUnlock] = [:]
        for (_, u) in entries() where (best[u.token]?.untilDate ?? .distantPast) < u.untilDate {
            best[u.token] = u
        }
        return Array(best.values)
    }

    /// まだ期限の来ていないもの（画面用。書き込みはしない）。終わりの早い順
    static func active(_ now: Date = Date()) -> [AppUnlock] {
        all.filter { $0.untilDate > now }.sorted { $0.untilDate < $1.untilDate }
    }

    static func activeTokens(_ now: Date = Date()) -> Set<ApplicationToken> {
        Set(active(now).map(\.token))
    }

    /// 期限が now 以前のファイルを消す（壊れたファイルも消す）。消したアプリの数
    @discardableResult
    static func prune(before now: Date) -> Int {
        let fm = FileManager.default
        var removed = Set<Data>()
        for u in files() {
            // 読めない（データ保護がかかっている等）ものは消さずに飛ばす。読めて壊れているものだけ消す
            guard let d = try? Data(contentsOf: u) else { continue }
            guard let v = try? JSONDecoder().decode(AppUnlock.self, from: d) else {
                try? fm.removeItem(at: u)
                continue
            }
            if v.untilDate <= now {
                try? fm.removeItem(at: u)
                if let k = try? JSONEncoder().encode(v.token) { removed.insert(k) }
            }
        }
        guard !removed.isEmpty else { return 0 }
        // 同じアプリの長い方が残っていれば、そのアプリは外れていないので数えない
        let still = Set(entries().compactMap { try? JSONEncoder().encode($0.unlock.token) })
        return removed.subtracting(still).count
    }

    static func clear() {
        for u in files() { try? FileManager.default.removeItem(at: u) }
    }

    /// いちばん早い終わり
    static var earliestUntil: Date? { active().map(\.untilDate).min() }

    /// 選んだものを確かめる。対象（許可アプリを除いたアプリ）と、出す注意・断る理由
    struct Check {
        var targets: Set<ApplicationToken>
        var notes: [String]
        var error: String?
        var ok: Bool { error == nil && !targets.isEmpty }
    }

    /// allowed: ロック中も使える土台（スーパーロック中は残すアプリ。Shield.baseSelection）
    static func check(_ pick: FamilyActivitySelection, allowed given: FamilyActivitySelection? = nil,
                      now: Date = Date()) -> Check {
        let allowed = given ?? Shield.baseSelection(now)
        let allowedName = SuperLock.isActive(now) ? "スーパーロックで残すアプリ" : "許可アプリ"
        var notes: [String] = []
        if !pick.categoryTokens.isEmpty {
            notes.append("カテゴリで選んだもの（\(pick.categoryTokens.count)件）は個別の解除になりません。アプリを1つずつ選んでください。")
        }
        if !pick.webDomainTokens.isEmpty {
            notes.append("ウェブサイト（\(pick.webDomainTokens.count)件）は個別の解除の対象外です。")
        }
        let alreadyAllowed = pick.applicationTokens.intersection(allowed.applicationTokens)
        if !alreadyAllowed.isEmpty {
            notes.append("\(allowedName)（\(alreadyAllowed.count)個）はロック中も使えるので数えません。")
        }
        let targets = pick.applicationTokens.subtracting(allowed.applicationTokens)
        let current = activeTokens(now)
        let extended = targets.intersection(current)
        if !extended.isEmpty {
            notes.append("すでに個別に解除中のアプリ（\(extended.count)個）は、長い方の期限に延びます。")
        }
        var error: String?
        if targets.isEmpty {
            error = "ロックされているアプリを1つ以上選んでください。"
        } else {
            // 許可アプリに入っているものは二重に数えない
            let extra = current.union(targets).subtracting(allowed.applicationTokens)
            let total = allowed.applicationTokens.count + extra.count
            if total > limit {
                let curOnly = current.subtracting(allowed.applicationTokens)
                error = "ロックの例外にできるのは許可アプリと合わせて\(limit)個までです"
                    + "（許可アプリ \(allowed.applicationTokens.count)個・個別に解除中 \(curOnly.count)個・今回 \(extra.subtracting(curOnly).count)個で \(total)個）。"
                    + "選ぶアプリを減らしてください。"
            }
        }
        return Check(targets: targets, notes: notes, error: error)
    }

    /// 足す（同じアプリが解除中なら長い方の期限）
    static func add(_ tokens: Set<ApplicationToken>, until: Date, recordId: String) {
        // 1アプリ1ファイルを作るだけ（同じアプリの古いファイルは all が長い方を取り、期限で prune が消す）
        let d = dir
        for t in tokens { write(AppUnlock(token: t, until: ISO.string(until), recordId: recordId), in: d) }
    }
}

// MARK: - セルフロック

enum SelfLock {
    enum Choice: String, CaseIterable, Identifiable {
        case oneHour, twoHours, untilReset
        var id: String { rawValue }

        func until(_ now: Date = Date()) -> Date {
            switch self {
            case .oneHour: return now.addingTimeInterval(3600)
            case .twoHours: return now.addingTimeInterval(7200)
            case .untilReset: return Quota.nextReset(now)
            }
        }

        var label: String {
            switch self {
            case .oneHour: return "1時間"
            case .twoHours: return "2時間"
            case .untilReset: return "朝のリセットまで"
            }
        }
    }

    // MARK: 時間を指定（2026-10-15 本人の要望）

    /// 指定の刻み・最短（分）
    static let customStep = 5
    static let customMinimum = 5

    /// いまからリセットまで（分・切り捨て）
    static func minutesToReset(_ now: Date = Date()) -> Int {
        max(0, Int(Quota.nextReset(now).timeIntervalSince(now) / 60))
    }

    /// 指定した長さの終わり。リセットを越える指定はリセットまでに丸める（clamped=true）。
    /// 最短より短い・リセットまで最短も無いときは nil
    static func customUntil(minutes: Int, now: Date = Date()) -> (until: Date, clamped: Bool)? {
        guard minutes >= customMinimum else { return nil }
        let reset = Quota.nextReset(now)
        let want = now.addingTimeInterval(TimeInterval(minutes * 60))
        if want > reset {
            guard reset.timeIntervalSince(now) >= TimeInterval(customMinimum * 60) else { return nil }
            return (reset, true)
        }
        return (want, false)
    }
}

extension Store {
    /// セルフロックの終わり（無ければセルフロックなし）
    static var selfLockUntil: Date? {
        get { string("selfLockUntil").flatMap(ISO.parse) }
        set { setString("selfLockUntil", newValue.map(ISO.string)) }
    }

    /// .appRelock を登録したときの対象（いちばん早い個別解除の終わり）
    static var appRelockFor: Date? {
        get { string("appRelockFor").flatMap(ISO.parse) }
        set { setString("appRelockFor", newValue.map(ISO.string)) }
    }

    /// .selfLockEnd を登録したときの対象（セルフロックの終わり）
    static var selfLockEndFor: Date? {
        get { string("selfLockEndFor").flatMap(ISO.parse) }
        set { setString("selfLockEndFor", newValue.map(ISO.string)) }
    }

    /// 今 shield に書いてある例外の指紋（例外が変わったときだけ書き直す）
    static var shieldKey: String? {
        get { string("shieldKey") }
        set { setString("shieldKey", newValue) }
    }
}

enum ShieldKey {
    /// トークンの集まりの指紋。トークンは並べられないので、1つずつ JSON にして文字列で並べる
    static func make(apps: Set<ApplicationToken>, domains: Set<WebDomainToken>) -> String {
        let enc = JSONEncoder()
        func strs<T: Encodable>(_ s: Set<T>) -> [String] {
            s.compactMap { (try? enc.encode($0)).map { $0.base64EncodedString() } }.sorted()
        }
        let joined = (["apps"] + strs(apps) + ["domains"] + strs(domains)).joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
