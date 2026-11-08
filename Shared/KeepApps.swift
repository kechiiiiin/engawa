import Foundation
import ManagedSettings

// スーパーロックで使うアプリ（本番設計 §9.8 B・2026-11-08 本人と決定）。
//
//   残せるのは、開発側が決めた許可一覧（allowList）にあるアプリだけ。bundle ID からトークンは作れないので、
//   「開いて確かめる」方式で登録する（試し: ブランチ claude/allow-verify・2026-11-08 実機で成功）:
//
//     1. 縁側の「追加する」でピッカーから候補を選ぶ
//     2. 候補だけを専用のストア（keepVerify）の shield.applications で一時的に止める（start）
//     3. 利用者が候補を開く → ShieldConfiguration 拡張が bundle ID を読み、許可一覧にあれば
//        「スーパーロックで使えるようにする」（2つ目のボタン）を出す。無ければ「閉じる」だけ
//     4. アプリ単位で止めているので、ShieldAction は app トークン版で呼ばれる。
//        2つ目のボタン → register（登録して、その候補の止めを外す）／「閉じる」→ dismiss（登録せずに外す）
//     5. 候補が無くなるか、縁側の「終える」（stop）で一時的な止めを全部外す。縁側を起動し直したときも外す
//
//   - スーパーロックの例外（.all(except:)）に使うのは registered だけ（Shield.exceptions）
//   - スーパーロック中は追加も削除もしない（start・register・remove が断る。画面にも入口を出さない）
//   - ShieldConfiguration 拡張から App Group への書き込みは届かない（試しで確認）ので、拡張は読むだけ
//   - 既定のストア（Shield.store）には触れない

enum KeepApps {
    /// 開発側の許可一覧（bundle ID と画面に出す名前）。iOS の標準アプリ（電話・メッセージなど）は
    /// 全部止めても止まらないので載せない（DTS「by design」）。中身は LINE だけから始める（他は未決）
    static let allowList: [(bundleID: String, name: String)] = [
        ("jp.naver.line", "LINE"),
    ]

    /// 残せるアプリの上限（ManagedSettings の例外は50個まで）
    static let limit = 50

    static let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("keepVerify"))
    /// 試し（claude/allow-verify）が使っていたストア。残っていても起動時に外す
    static let legacyVerifyStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("verify"))

    static let registeredFile = "keep-apps.json"
    static let verifyingFile = "keep-verifying"

    static func isAllowed(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return allowList.contains { $0.bundleID == bundleID }
    }

    // MARK: 登録済み

    static var registered: [ApplicationToken] {
        Store.codable(registeredFile, as: [ApplicationToken].self) ?? []
    }

    static var registeredSet: Set<ApplicationToken> { Set(registered) }

    /// 登録済みから外す（本体から）。スーパーロック中は断る（false）
    @discardableResult
    static func remove(_ token: ApplicationToken) -> Bool {
        guard !StrictLock.isActive(), !StrictLock.unreadable else { return false }
        Store.setCodable(registeredFile, registered.filter { $0 != token })
        Log.add(kind: "keepApps", detail: "削除 残り=\(registered.count)")
        return true
    }

    // MARK: 確かめ（一時的な止め）

    /// 確かめ中か（候補を一時的に止めている）
    static var isVerifying: Bool { Store.data(verifyingFile) != nil }

    /// 通常ロックとの見分け（§9.9）。通常ロック中は、止まっているアプリが確かめの候補か通常ロックの対象かを見分ける。
    /// 通常ロックでないときは今までどおり（確かめ中なら候補として扱う＝2026-11-08 実機で通った動きを変えない）。
    /// 候補の一覧が読めないとき（nil）も今までどおり候補として扱う
    static func treatAsCandidate(_ token: ApplicationToken?) -> Bool {
        guard isVerifying else { return false }
        guard Store.normalLockUntil.map({ $0 > Date() }) ?? false else { return true }
        guard let token, let pending = store.shield.applications else { return true }
        return pending.contains(token)
    }

    /// 一時的に止めている候補の数
    static var pendingCount: Int { store.shield.applications?.count ?? 0 }

    /// 候補を一時的に止めて、確かめを始める（本体から）。登録済みの候補は止めない。
    /// スーパーロック中・候補が無いときは断る（false）
    @discardableResult
    static func start(_ candidates: Set<ApplicationToken>) -> Bool {
        guard !StrictLock.isActive(), !StrictLock.unreadable else { return false }
        let apps = candidates.subtracting(registeredSet)
        guard !apps.isEmpty else { return false }
        Store.setString(verifyingFile, ISO.now)
        store.shield.applications = apps
        Log.add(kind: "keepVerify", detail: "始めた 候補=\(apps.count)")
        return true
    }

    /// 一時的な止めを全部外して、確かめを終える（本体の「終える」・起動時・候補が無くなったとき）
    static func stop(route: String = "app") {
        let had = isVerifying || store.shield.applications != nil
        store.clearAllSettings()
        Store.setData(verifyingFile, nil)
        if had { Log.add(kind: "keepVerify", route: route, detail: "終えた") }
    }

    /// ShieldAction の2つ目のボタン（許可一覧のアプリにだけ出る）。登録して、その候補の止めを外す。
    /// 確かめ中でない・スーパーロック中は登録しない（false）
    @discardableResult
    static func register(_ token: ApplicationToken) -> Bool {
        guard isVerifying, !StrictLock.isActive(), !StrictLock.unreadable else { return false }
        var list = registered
        if !list.contains(token) {
            guard list.count < limit else { release(token); return false }
            list.append(token)
            Store.setCodable(registeredFile, list)
        }
        release(token)
        let ok = registered.contains(token)
        Log.add(kind: "keepApps", route: "shieldAction", ok: ok, detail: "登録 計=\(registered.count)")
        return ok
    }

    /// その候補の一時的な止めを外す（登録せずに「閉じる」を押したときも）。候補が無くなったら確かめを終える
    static func release(_ token: ApplicationToken) {
        guard var apps = store.shield.applications else {
            stop(route: "shieldAction")
            return
        }
        apps.remove(token)
        if apps.isEmpty {
            stop(route: "shieldAction")
        } else {
            store.shield.applications = apps
        }
    }
}
