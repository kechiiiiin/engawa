import Foundation

// 「代わりにやりたいこと」の一覧。App Group の ideas.json が正本（設定画面で編集）。
// ファイルが無ければ既定の10件。空の一覧（全部消した）なら固定文に落ちる。
// ShieldConfig 拡張はネットワークに出られない（公式）ので、ここを読むだけ。

struct Idea: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var subtitle: String

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    enum CodingKeys: String, CodingKey { case id, title, subtitle }

    // 試作の上書き JSON（id なし・[{title, subtitle}]）もそのまま読めるように
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? ""
    }

    var isUsable: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum Ideas {
    static let file = "ideas.json"

    static let defaults: [Idea] = [
        Idea(title: "本を10ページ読む", subtitle: "読みかけの本を開いてみませんか。10ページで止めてもいい。"),
        Idea(title: "腕立てを10回", subtitle: "その場でできます。終わったら水を一杯。"),
        Idea(title: "外を5分歩く", subtitle: "玄関を出て、角を一つ曲がって戻ってくるだけ。"),
        Idea(title: "子どもと遊ぶ", subtitle: "いま、隣に誰がいますか。"),
        Idea(title: "ストレッチを3分", subtitle: "首・肩・背中をゆっくり伸ばす。"),
        Idea(title: "ノートに一行書く", subtitle: "今日あったことを一行だけ。"),
        Idea(title: "部屋を一か所片づける", subtitle: "机の上だけ、棚一段だけ。"),
        Idea(title: "目を閉じて深呼吸", subtitle: "4秒吸って、7秒止めて、8秒吐く。3回。"),
        Idea(title: "お茶を淹れる", subtitle: "お湯が沸くまで、窓の外を見る。"),
        Idea(title: "寝る準備をする", subtitle: "歯を磨いて、明日の服を出しておく。もう今日は十分がんばりました。"),
    ]

    static let fallback = Idea(title: "いまはロック中", subtitle: "スマホの代わりに、何をしましょうか。")

    /// 保存されている一覧（無ければ既定）。読めないファイルも既定扱い
    static var list: [Idea] {
        get {
            guard let d = Store.data(file), let l = try? JSONDecoder().decode([Idea].self, from: d) else { return defaults }
            return l
        }
        set {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            Store.setData(file, try? enc.encode(newValue))
        }
    }

    static var isCustomized: Bool { Store.data(file) != nil }

    /// ランダムに1つ。使える項目が無ければ固定文。source は記録用
    static func pick() -> (idea: Idea, index: Int?, source: String) {
        let source = isCustomized ? "appGroup" : "defaults"
        let usable = list.enumerated().filter { $0.element.isUsable }
        guard let chosen = usable.randomElement() else { return (fallback, nil, "fallback") }
        return (chosen.element, chosen.offset, source)
    }
}
