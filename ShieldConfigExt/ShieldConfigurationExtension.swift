import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

// ロック画面の文言。スーパーロック中・通常ロック中は終了時刻と「閉じる」だけ（§9.6・§9.9）。文言は2つで分ける（§9.10）。
// 画面上は通常ロックを「ロック」とだけ呼ぶ（§9.11）。
// 通常ロックは「残すアプリ」以外をカテゴリ（.all(except:)）で止めるので、多くは app/category 版で呼ばれる。スーパーロックで使うアプリの登録の確かめ中は、
// 許可一覧のアプリにだけ登録のボタンを出す（§9.8 B）。
// ネットワークは使わない（この拡張はサンドボックスで出られない・公式）。返すのが遅いと既定表示に落ちるので軽く。
// この拡張から App Group への書き込みは届かない（2026-11-08 試しで確認）。Log.add は届けば残る程度

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        if Store.strictLockUntil == nil, KeepApps.treatAsCandidate(application.token) { return verify(application) }
        return make("app")
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        if Store.strictLockUntil == nil, KeepApps.treatAsCandidate(application.token) { return verify(application) }
        return make("app/category")
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        make("web")
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        make("web/category")
    }

    private func make(_ what: String) -> ShieldConfiguration {
        if let until = Store.strictLockUntil { return strict(what, until: until) }
        if let until = Store.normalLockUntil { return normal(what, until: until) }
        // スーパーロックでも確かめでもないのに止まっている（旧版の止めが残っているなど）。縁側を開けば reconcile が外す
        Log.add(kind: "shieldShown", detail: "\(what) other")
        return styled(title: "縁側のロック",
                      subtitle: "縁側を開くと外れます。")
    }

    // 見た目: 火や封印の絵は置かず、紙の色の無地に字だけ（2026-11-08 本人「質素でよい」）。
    // 背景は外観で切り替わる単色（ぼかしなし）。ライトは縁側の紙、ダークは暗い茶。ボタンは縁側の板の色
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        func c(_ h: UInt32) -> UIColor {
            UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        }
        return UIColor { $0.userInterfaceStyle == .dark ? c(dark) : c(light) }
    }
    private static let paper = dyn(0xF4ECDF, 0x2A2420)
    private static let ink = dyn(0x3B2F25, 0xF4ECDF)
    private static let ink2 = dyn(0x7B6A57, 0xBFB09B)
    private static let wood = UIColor(red: 0x7A / 255, green: 0x4E / 255, blue: 0x2D / 255, alpha: 1)
    private static let onWood = UIColor(red: 0xFB / 255, green: 0xF4 / 255, blue: 0xE8 / 255, alpha: 1)

    private func styled(title: String, subtitle: String, secondary: String? = nil) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: Self.paper,
            icon: nil,
            title: ShieldConfiguration.Label(text: title, color: Self.ink),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: Self.ink2),
            primaryButtonLabel: ShieldConfiguration.Label(text: "閉じる", color: Self.onWood),
            primaryButtonBackgroundColor: Self.wood,
            secondaryButtonLabel: secondary.map { ShieldConfiguration.Label(text: $0, color: Self.ink2) }
        )
    }

    /// 厳格ロック（画面上の呼び方はスーパーロック・§9.6／§9.8）: 終了時刻と「閉じる」だけ
    private func strict(_ what: String, until: Date) -> ShieldConfiguration {
        let ended = until <= Date()
        Log.add(kind: "shieldShown", detail: "\(what) strict ended=\(ended)")
        return styled(title: ended ? "スーパーロックの時間が終わりました" : "\(StrictLock.clock(until)) までスーパーロック中",
                      subtitle: ended ? "「閉じる」で使えるようになります。" : "時間が来ると、自動で使えるようになります。")
    }

    /// 通常ロック（§9.9・§9.10）: 終了時刻と「閉じる」だけ。残すアプリはロック中も足せることを添える
    private func normal(_ what: String, until: Date) -> ShieldConfiguration {
        let ended = until <= Date()
        Log.add(kind: "shieldShown", detail: "\(what) normal ended=\(ended)")
        return styled(title: ended ? "ロックの時間が終わりました" : "\(StrictLock.clock(until)) までロック中",
                      subtitle: ended ? "「閉じる」で使えるようになります。"
                          : "使えるアプリだけが使えます。")
    }

    /// スーパーロックで使うアプリの登録の確かめ（§9.8 B・Shared/KeepApps.swift）。
    /// 許可一覧のアプリにだけ2つ目のボタンを出す。一覧外は「閉じる」だけ（押すと一時的な止めが外れる）
    private func verify(_ application: Application) -> ShieldConfiguration {
        if KeepApps.isAllowed(application.bundleIdentifier) {
            return styled(title: "使えるアプリに追加できます",
                          subtitle: "スーパーロック中も使えるようになります。",
                          secondary: "使えるアプリに追加する")
        }
        // 通常ロック中は、閉じたあとも通常ロックで止まる（残すアプリでなければ）
        return styled(title: "使えるアプリに追加できません",
                      subtitle: NormalLock.isActive()
                          ? "このアプリは追加できません。"
                          : "このアプリは追加できません。")
    }
}
