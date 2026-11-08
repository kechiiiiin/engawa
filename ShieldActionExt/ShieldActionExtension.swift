import Foundation
import ManagedSettings

// ボタンは「閉じる」（登録の確かめ中の許可一覧のアプリだけ「スーパーロックで使えるようにする」も）。
// 押された記録を残して .close を返す（ネットワークには出ない）。スーパーロック・通常ロックの期限が過ぎていれば、ここで外す。

class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        record(action, "app")
        // スーパーロックで使うアプリの登録の確かめ（§9.8 B・Shared/KeepApps.swift）。候補はアプリ単位で止めているので
        // ここ（app トークン版）に来る。2つ目のボタン（許可一覧のアプリにだけ出る）で登録、「閉じる」は登録せずに外す。
        // どちらもその候補の一時的な止めを外し、.close（開き直すと使える）
        // 通常ロックで止まっているアプリ（候補でない）は登録も外しもしない（KeepApps.treatAsCandidate・§9.9）
        if Store.strictLockUntil == nil, KeepApps.treatAsCandidate(application) {
            if action == .secondaryButtonPressed {
                KeepApps.register(application)
            } else {
                KeepApps.release(application)
            }
        }
        // 確かめの候補は通常ロックの例外に入れてある（Shield.normalExceptions）ので、止めを外したあとに決め直して、
        // 通常ロック中なら（残すアプリでなければ）通常ロックで止め直す。期限後の shield もここで外す（下の settle）
        settle()
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        record(action, "web")
        settle()
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        record(action, "category")
        settle()
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

    private func settle() {
        // スーパーロック・通常ロックの期限後や旧版から残った shield は、ここでも外す（拡張の終了処理が走らなかったときの最後の網。
        // 縁側自身は FamilyControls の認可アプリなので shield されない → Shield.lockNow のコメント）。
        // 期限内のロックは reconcile では外れない
        Shield.reconcile(route: "shieldAction")
    }
}
