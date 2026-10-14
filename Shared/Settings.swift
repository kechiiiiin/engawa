import Foundation

// 普段使いの設定（端末が正本）。App Group の settings.json に置き、本体が書いて拡張が読む。
// 2026-10-14 本人判断で「アプリ内で枠を緩める」抜け道は許容しているので、変更はすぐ効く
// （本番設計 §2.4 の current／pending は作っていない）。

struct AppSettings: Codable, Equatable {
    /// 1日の枠（分）。初期 2時間30分
    var quotaMinutes: Int = 150
    /// リセット時刻（0:00 からの分）。初期 4:00
    var resetMinutes: Int = 240
    /// 数え方（差し替え点は Quota.swift）。2026-10-15 本人の要望で初期は差し引き（許可アプリを数えない）。
    /// 以前 inclusive で保存されていた端末は Store.migrateCountModeIfNeeded で1回だけ切り替える
    var countMode: CountMode = .excludeAllowed

    init() {}

    enum CodingKeys: String, CodingKey { case quotaMinutes, resetMinutes, countMode }

    // 項目が増えても古いファイルを読めるよう、無い項目は初期値
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        quotaMinutes = (try? c.decodeIfPresent(Int.self, forKey: .quotaMinutes)) ?? d.quotaMinutes
        resetMinutes = (try? c.decodeIfPresent(Int.self, forKey: .resetMinutes)) ?? d.resetMinutes
        countMode = (try? c.decodeIfPresent(CountMode.self, forKey: .countMode)) ?? d.countMode
    }

    /// 選べる枠（30分〜8時間・15分刻み。本番設計 §2.2 の案）
    static let quotaChoices = Array(stride(from: 30, through: 480, by: 15))
    /// 選べるリセット時刻（0:00〜6:00・30分刻み。同）
    static let resetChoices = Array(stride(from: 0, through: 360, by: 30))

    /// 150 → 「2時間30分」
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)分" }
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }

    /// 240 → 「4:00」
    static func clock(_ minutesOfDay: Int) -> String {
        let v = ((minutesOfDay % 1440) + 1440) % 1440
        return String(format: "%d:%02d", v / 60, v % 60)
    }
}

extension Store {
    static var settings: AppSettings {
        get { codable("settings.json", as: AppSettings.self) ?? AppSettings() }
        set { setCodable("settings.json", newValue) }
    }

    /// 数え方を差し引き（excludeAllowed）へ1回だけ切り替える（2026-10-15 の更新）。本体の起動時に呼ぶ。
    /// 済んだ印は countModeMigratedV1。切り替えたら監視 daily を新しい数え方のイベントで登録し直す。
    /// 以後、本人が設定でオフ（inclusive）にしたものは戻さない
    static func migrateCountModeIfNeeded() {
        guard string("countModeMigratedV1") == nil else { return }
        var s = settings
        let old = s.countMode
        if old != .excludeAllowed {
            s.countMode = .excludeAllowed
            settings = s
        }
        setString("countModeMigratedV1", ISO.now)
        Log.add(kind: "migrate", detail: "countMode \(old.rawValue) → excludeAllowed（1回だけ）")
        if old != .excludeAllowed { Quota.arm(reason: "migrateCountMode") }
    }
}
