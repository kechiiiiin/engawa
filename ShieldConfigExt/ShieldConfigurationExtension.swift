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
}
