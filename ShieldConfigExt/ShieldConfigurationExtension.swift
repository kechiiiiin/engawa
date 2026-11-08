import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

// ロック画面の文言。「代わりにやりたいこと」を一覧からランダムに1つ（Shared/Ideas.swift）。
// 一覧は App Group の ideas.json（設定画面で編集）、無ければ既定の10件、空なら固定文。
// ネットワークは使わない（この拡張はサンドボックスで出られない・公式）。返すのが遅いと既定表示に落ちるので軽く。

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        if Store.strictLockUntil == nil, KeepApps.isVerifying { return verify(application) }
        return make("app")
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        if Store.strictLockUntil == nil, KeepApps.isVerifying { return verify(application) }
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
        let (idea, i, source) = Ideas.pick()
        Log.add(kind: "shieldShown", detail: "\(what) source=\(source) idea=\(i.map(String.init) ?? "-") \(idea.title)")
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            backgroundColor: nil,
            icon: UIImage(systemName: "flame"),
            title: ShieldConfiguration.Label(text: idea.title, color: .label),
            subtitle: ShieldConfiguration.Label(text: idea.subtitle, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "閉じる", color: .white),
            primaryButtonBackgroundColor: .systemOrange,
            secondaryButtonLabel: nil
        )
    }

    // 色: 見出しが暗い背景に暗い文字で読めなかった（2026-11-08 試しの実機）。背景色の指定（生成り）が効かず、
    // 暗い外観の素材の上に固定の濃い字を置いていたと見ている（推測）。背景は外観に合わせて変わる素材にし、
    // 字は外観に合わせて変わるシステムの色（label／secondaryLabel）にする（ふだんの shield と同じ組み方）。
    // アイコンとボタンは縁側の板の色（どちらの外観でも読める組み合わせ）
    private static let wood = UIColor(red: 0x9A / 255, green: 0x63 / 255, blue: 0x3A / 255, alpha: 1)
    private static let onWood = UIColor(red: 0xFB / 255, green: 0xF4 / 255, blue: 0xE8 / 255, alpha: 1)

    private func styled(icon: String, title: String, subtitle: String, secondary: String? = nil) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            backgroundColor: nil,
            icon: UIImage(systemName: icon)?.withTintColor(Self.wood, renderingMode: .alwaysOriginal),
            title: ShieldConfiguration.Label(text: title, color: .label),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "閉じる", color: Self.onWood),
            primaryButtonBackgroundColor: Self.wood,
            secondaryButtonLabel: secondary.map { ShieldConfiguration.Label(text: $0, color: .label) }
        )
    }

    /// 厳格ロック（画面上の呼び方はスーパーロック・§9.6／§9.8）: 終了時刻と「閉じる」だけ
    private func strict(_ what: String, until: Date) -> ShieldConfiguration {
        let ended = until <= Date()
        Log.add(kind: "shieldShown", detail: "\(what) strict ended=\(ended)")
        return styled(icon: "flame",
                      title: ended ? "スーパーロックの時間が終わりました" : "\(StrictLock.clock(until)) までスーパーロック中",
                      subtitle: ended ? "「閉じる」を押すと、使えるようになります。" : "時間が来ると、自動で使えるようになります。")
    }

    /// スーパーロックで使うアプリの登録の確かめ（§9.8 B・Shared/KeepApps.swift）。
    /// 許可一覧のアプリにだけ2つ目のボタンを出す。一覧外は「閉じる」だけ（押すと一時的な止めが外れる）
    private func verify(_ application: Application) -> ShieldConfiguration {
        if KeepApps.isAllowed(application.bundleIdentifier) {
            return styled(icon: "checkmark.seal",
                          title: "スーパーロックで使えるアプリです",
                          subtitle: "下のボタンを押すと、スーパーロック中も使えるアプリとして登録します。",
                          secondary: "スーパーロックで使えるようにする")
        }
        return styled(icon: "xmark.seal",
                      title: "スーパーロックでは使えません",
                      subtitle: "このアプリは登録できません。「閉じる」を押すと、ふだんどおり使えるようになります。")
    }
}
