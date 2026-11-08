import Foundation
import ManagedSettings

// ボタンは「閉じる」（登録の確かめ中の許可一覧のアプリだけ「スーパーロックで使えるようにする」も）。
// 押された記録を残して .close を返す（ネットワークには出ない）。厳格ロックの期限が過ぎていれば、ここで外す。

class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        record(action, "app")
        // スーパーロックで使うアプリの登録の確かめ（§9.8 B・Shared/KeepApps.swift）。候補はアプリ単位で止めているので
        // ここ（app トークン版）に来る。2つ目のボタン（許可一覧のアプリにだけ出る）で登録、「閉じる」は登録せずに外す。
        // どちらもその候補の一時的な止めを外し、.close（開き直すと使える）
        if KeepApps.isVerifying, Store.strictLockUntil == nil {
            if action == .secondaryButtonPressed {
                KeepApps.register(application)
            } else {
                KeepApps.release(application)
            }
        }
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
        // 厳格ロックの期限後に残った shield は、ここでも外す（拡張の終了処理が走らなかったときの最後の網。
        // 縁側自身は FamilyControls の認可アプリなので shield されない見込み → Shield.lockNow のコメント）
        if Store.strictLockUntil != nil { Shield.reconcile(route: "shieldAction") }
    }
}
