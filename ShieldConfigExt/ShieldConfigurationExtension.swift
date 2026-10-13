import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

// ロック画面の文言。「やりたいこと」を一覧からランダムに1つ。
// 一覧は App Group の上書き（ideas.json）があればそれ、無ければバンドル内の ideas.json。
// ネットワークは使わない（この拡張はサンドボックスで出られない・公式）。返すのが遅いと既定表示に落ちるので軽く。

struct Idea: Codable {
    var title: String
    var subtitle: String
}

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

    private func loadIdeas() -> (ideas: [Idea], source: String) {
        if let d = Store.data("ideas.json"), let list = try? JSONDecoder().decode([Idea].self, from: d), !list.isEmpty {
            return (list, "override")
        }
        if let u = Bundle.main.url(forResource: "ideas", withExtension: "json"),
           let d = try? Data(contentsOf: u), let list = try? JSONDecoder().decode([Idea].self, from: d), !list.isEmpty {
            return (list, "bundle")
        }
        return ([Idea(title: "いまはロック中", subtitle: "スマホの代わりに、何をしましょうか。")], "fallback")
    }

    private func make(_ what: String) -> ShieldConfiguration {
        let (ideas, source) = loadIdeas()
        let i = Int.random(in: 0..<ideas.count)
        let idea = ideas[i]
        Log.add(kind: "shieldShown", detail: "\(what) source=\(source) idea=\(i) \(idea.title)")
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
