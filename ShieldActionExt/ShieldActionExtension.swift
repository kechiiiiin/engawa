import Foundation
import ManagedSettings

// ボタンは「閉じる」だけ。押された記録を残して .close を返す（ネットワークには出ない）。
// 厳格ロックの期限が過ぎていれば、ここで外す。

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
        // 厳格ロックの期限後に残った shield は、ここでも外す（縁側自身が止まっていて開けないときの最後の網）
        if Store.strictLockUntil != nil { Shield.reconcile(route: "shieldAction") }
    }
}
