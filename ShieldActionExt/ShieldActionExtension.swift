import Foundation
import ManagedSettings

// ボタンは「閉じる」だけ。押された記録を残して .close を返す（ネットワークには出ない）。

class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        record(action, "app")
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        record(action, "web")
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        record(action, "category")
        completionHandler(.close)
    }

    private func record(_ action: ShieldAction, _ what: String) {
        let name: String
        switch action {
        case .primaryButtonPressed: name = "primary"
        case .secondaryButtonPressed: name = "secondary"
        default: name = String(describing: action)
        }
        Log.add(kind: "shieldAction", detail: "\(what) \(name)")
    }
}
