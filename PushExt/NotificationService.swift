import Foundation
import UserNotifications

// 2026-11-08（本番設計 §9.8 C）からサーバー連携（プッシュでのロック・解除）は使わない。本体は APNs に登録しないので
// 通知は届かない見込み。届いても中身は変えず、ロックにも触れずにそのまま出す。
// ターゲットは署名・配布の構成（5ターゲット）を変えないため残している

class NotificationService: UNNotificationServiceExtension {

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(request.content)
    }
}
