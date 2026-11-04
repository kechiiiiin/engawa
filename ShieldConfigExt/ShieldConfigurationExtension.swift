import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

// ロック画面の文言。「代わりにやりたいこと」を一覧からランダムに1つ（Shared/Ideas.swift）。
// 一覧は App Group の ideas.json（設定画面で編集）、無ければ既定の10件、空なら固定文。
// ネットワークは使わない（この拡張はサンドボックスで出られない・公式）。返すのが遅いと既定表示に落ちるので軽く。

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        make("app")
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        make("app/category")
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

    /// 厳格ロック（§9.6）: 終了時刻と「閉じる」だけ。色は縁側の生成りと板（Theme と同じ値）
    private func strict(_ what: String, until: Date) -> ShieldConfiguration {
        let ink = UIColor(red: 0x3B / 255, green: 0x2F / 255, blue: 0x25 / 255, alpha: 1)
        let ink2 = UIColor(red: 0x7B / 255, green: 0x6A / 255, blue: 0x57 / 255, alpha: 1)
        let wood = UIColor(red: 0x7A / 255, green: 0x4E / 255, blue: 0x2D / 255, alpha: 1)
        let paper = UIColor(red: 0xF4 / 255, green: 0xEC / 255, blue: 0xDF / 255, alpha: 1)
        let onWood = UIColor(red: 0xFB / 255, green: 0xF4 / 255, blue: 0xE8 / 255, alpha: 1)
        let ended = until <= Date()
        Log.add(kind: "shieldShown", detail: "\(what) strict ended=\(ended)")
        return ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: paper,
            icon: UIImage(systemName: "flame")?.withTintColor(wood, renderingMode: .alwaysOriginal),
            title: ShieldConfiguration.Label(text: ended ? "ロックの時間が終わりました" : "\(StrictLock.clock(until)) までロック中", color: ink),
            subtitle: ShieldConfiguration.Label(text: ended ? "「閉じる」を押すと、使えるようになります。" : "時間が来ると、自動で使えるようになります。", color: ink2),
            primaryButtonLabel: ShieldConfiguration.Label(text: "閉じる", color: onWood),
            primaryButtonBackgroundColor: wood,
            secondaryButtonLabel: nil
        )
    }
}
