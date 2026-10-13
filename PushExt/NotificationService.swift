import Foundation
import UserNotifications

// 経路 R3: alert プッシュ（mutable-content: 1）を受けたら、ペイロードの state を shield に反映する。
// 成否を通知本文に書き足す（「ロックを反映しました／失敗: 理由」）。
// この拡張が落ちたり時間切れになったりしても、システムは元の本文のまま通知を出す。
//
// ペイロードの形（tools/push.sh・サーバーが作る）:
//   {"aps":{"alert":{"title":"…","body":"…"},"mutable-content":1},
//    "state":{"version":3,"locked":true,"unlockUntil":null,"changedAt":"…"}}

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content

        let suffix: String
        if !Store.routes.alertPush {
            Log.add(kind: "wake", route: "R3", detail: "R3 はオフ。反映しない")
            suffix = "（R3 はオフのため反映しませんでした）"
        } else if let state = Self.state(from: request.content.userInfo) {
            Log.add(kind: "wake", route: "R3", detail: "version=\(state.version)")
            suffix = Shield.apply(state, route: "R3").message
        } else {
            Log.add(kind: "apply", route: "R3", ok: false, error: "ペイロードに state が無い")
            suffix = "失敗: ペイロードに state が無い"
        }
        content.body = content.body.isEmpty ? suffix : "\(content.body)\n\(suffix)"

        // 可能なら記録をサーバーへ（短めに待つ）
        Log.flush(timeout: 5)

        contentHandler(content)
        self.contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let h = contentHandler, let c = bestAttempt {
            c.body += "\n（時間切れ）"
            h(c)
        }
        contentHandler = nil
    }

    static func state(from userInfo: [AnyHashable: Any]) -> ServerState? {
        guard let raw = userInfo["state"],
              JSONSerialization.isValidJSONObject(raw),
              let d = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(ServerState.self, from: d)
    }
}
