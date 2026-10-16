import Foundation
import FamilyControls
import ManagedSettings

// スーパーロック（2026-10-16 本人と決定・本番設計 §10）。
//
//   ふだんの許可アプリも止め、「スーパーロックで残すアプリ」（別の一覧・super-selection.json）だけを残すロック。
//   セルフロックと同じく端末だけで完結する第5の層で、期限で終わる。サーバーの state は変えない。
//
//   ロックする = (手動 || 枠 || セルフ || スーパー) && !時間解除中
//   ロック中の例外 = (スーパー中なら 残すアプリ、そうでなければ 許可アプリ) ∪ 個別解除（期限 > いま）
//
//   - かける・延ばすのは startSuperLock（セルフロックと同じ規則: 短くはしない・時間解除と個別解除を打ち消す）
//   - 途中の解除は「ランダムな1文の書き写し（完全一致）→ 理由 → 10分固定」。全体の解除はふだんの時間解除
//     （unlockUntil・.relock の目覚まし）を10分で入れるだけなので、10分たてば既存の再ロック経路でスーパーロックに戻る。
//     アプリ個別の解除も同じ手間で10分（.appRelock）
//   - 終わりの目覚ましは .superLockEnd（Wake.armExpiryWakes）。期限切れは reconcile が外す（自己修復）
//   - サーバーの期限なしの解除（ヘスティアからの解除）はセルフロックと同じく外す。新しいロックの指示（/lock）では外さない

enum SuperLock {
    /// 途中解除の長さ（分・選べない）
    static let unlockMinutes = 10

    /// 書き写す文（本番設計 §10.2。毎回ランダムに1つ）
    static let sentences: [String] = [
        "本当に必要か考えました。用事だけ済ませて戻ります。",
        "いま開かないと困ることがあるので、十分だけ使います。",
        "用が済んだら、すぐに縁側へ戻ってきます。",
        "なんとなくではなく、必要があって開きます。",
        "十分たったら、またスマホを置いて過ごします。",
        "開く前に一度深呼吸をして、用事を確かめました。",
        "ほかの手段では済まないので、少しだけ使います。",
        "済ませることは一つだけ。終わったら閉じます。",
        "この十分を、だらだら使わないと約束します。",
        "急ぎの用事を片づけたら、本の続きに戻ります。",
        "いまでなくてもよいことなら、ここで引き返します。",
        "必要なことを確かめたら、画面を伏せて置きます。",
        "自分で決めたロックを、理由があって外します。",
        "寄り道はしません。目的のアプリだけを開きます。",
        "少しだけ立って、用が済んだらまた座ります。",
        "開いたついでに、ほかのものは見ないでおきます。",
        "十分のうちに済ませて、残りの時間は家族と過ごします。",
        "いま必要なのはこれだけ、と口に出して確かめました。",
        "外す理由を書いて、記録に残してから開きます。",
        "この用事が済んだら、今夜はもう触りません。",
        "やりたいことを思い出したら、そちらを先にします。",
        "通知を追いかけるためではなく、用事のために開きます。",
        "十分で戻れなかったら、その理由も書き残します。",
        "急ぐ用事なので開きますが、長居はしません。",
        "画面の向こうより、目の前のことを大事にします。",
        "決めた時間は守ります。十分で縁側に戻ります。",
        "待てる用事ではないと考えたうえで、外します。",
        "開くのは一度だけ。済んだらまたロックに任せます。",
        "本当に要るものだけを見て、すぐに閉じます。",
        "少し使ったら、また日の当たる縁側に戻ります。",
    ]

    static func pick() -> String { sentences.randomElement() ?? sentences[0] }

    /// 完全一致（前後の空白・改行だけ除く。Swift の == は正準等価で比べる）
    static func matches(_ typed: String, _ target: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == target
    }

    /// 打った分が手本の頭と食い違っているか（画面で「ちがう字があります」を出す用。前の空白だけ除く）
    static func diverges(_ typed: String, _ target: String) -> Bool {
        let t = String(typed.drop(while: { $0.isWhitespace || $0.isNewline }))
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return !target.hasPrefix(trimmed)
    }

    /// いまスーパーロック中か（期限 > いま）
    static func isActive(_ now: Date = Date()) -> Bool {
        Store.superLockUntil.map { $0 > now } ?? false
    }

    /// 残すアプリ（スーパーロック用の一覧）
    static func loadSelection() -> FamilyActivitySelection { Shield.loadSelection("super-selection.json") }
    static func saveSelection(_ s: FamilyActivitySelection) { Shield.saveSelection(s, "super-selection.json") }
}

extension Store {
    /// スーパーロックの終わり（無ければスーパーロックなし）
    static var superLockUntil: Date? {
        get { string("superLockUntil").flatMap(ISO.parse) }
        set { setString("superLockUntil", newValue.map(ISO.string)) }
    }

    /// .superLockEnd を登録したときの対象（スーパーロックの終わり）
    static var superLockEndFor: Date? {
        get { string("superLockEndFor").flatMap(ISO.parse) }
        set { setString("superLockEndFor", newValue.map(ISO.string)) }
    }
}
