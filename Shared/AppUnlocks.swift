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
    static let file = "app-unlocks.json"

    /// 保存されている全件（期限切れも含む。外すのは reconcile）
    static var all: [AppUnlock] {
        get { Store.codable(file, as: [AppUnlock].self) ?? [] }
        set { Store.setCodable(file, newValue.isEmpty ? nil : newValue) }
    }

    /// まだ期限の来ていないもの（画面用。書き込みはしない）。終わりの早い順
    static func active(_ now: Date = Date()) -> [AppUnlock] {
        all.filter { $0.untilDate > now }.sorted { $0.untilDate < $1.untilDate }
    }

    static func activeTokens(_ now: Date = Date()) -> Set<ApplicationToken> {
        Set(active(now).map(\.token))
    }

    /// 期限が now 以前のものを消す。消した件数
    @discardableResult
    static func prune(before now: Date) -> Int {
        let a = all
        let keep = a.filter { $0.untilDate > now }
        if keep.count != a.count { all = keep }
        return a.count - keep.count
    }

    static func clear() { all = [] }

    /// いちばん早い終わり
    static var earliestUntil: Date? { active().map(\.untilDate).min() }

    /// 選んだものを確かめる。対象（許可アプリを除いたアプリ）と、出す注意・断る理由
    struct Check {
        var targets: Set<ApplicationToken>
        var notes: [String]
        var error: String?
        var ok: Bool { error == nil && !targets.isEmpty }
    }

    static func check(_ pick: FamilyActivitySelection, allowed: FamilyActivitySelection = Shield.loadSelection(),
                      now: Date = Date()) -> Check {
        var notes: [String] = []
        if !pick.categoryTokens.isEmpty {
            notes.append("カテゴリで選んだもの（\(pick.categoryTokens.count)件）は個別の解除になりません。アプリを1つずつ選んでください。")
        }
        if !pick.webDomainTokens.isEmpty {
            notes.append("ウェブサイト（\(pick.webDomainTokens.count)件）は個別の解除の対象外です。")
        }
        let alreadyAllowed = pick.applicationTokens.intersection(allowed.applicationTokens)
        if !alreadyAllowed.isEmpty {
            notes.append("許可アプリ（\(alreadyAllowed.count)個）はロック中も使えるので数えません。")
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
            let total = allowed.applicationTokens.count + current.union(targets).count
            if total > limit {
                error = "ロックの例外にできるのは許可アプリと合わせて\(limit)個までです"
                    + "（許可アプリ \(allowed.applicationTokens.count)個・個別に解除中 \(current.count)個・今回 \(targets.subtracting(current).count)個で \(total)個）。"
                    + "選ぶアプリを減らしてください。"
            }
        }
        return Check(targets: targets, notes: notes, error: error)
    }

    /// 足す（同じアプリが解除中なら長い方の期限）
    static func add(_ tokens: Set<ApplicationToken>, until: Date, recordId: String) {
        var a = all
        for t in tokens {
            if let i = a.firstIndex(where: { $0.token == t }) {
                if a[i].untilDate < until { a[i].until = ISO.string(until); a[i].recordId = recordId }
            } else {
                a.append(AppUnlock(token: t, until: ISO.string(until), recordId: recordId))
            }
        }
        all = a
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
            case .untilReset: return "朝のリセットまで（\(AppSettings.clock(Quota.effectiveResetMinutes))）"
            }
        }
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
