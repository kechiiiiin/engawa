import Foundation

// ロック中の使用を数えない（2026-10-15 本人の要望）。
//
// ロックが効いているあいだ（手動・枠・セルフのどれかが効いていて、時間解除も個別解除もしていない）にも、
// iOS が止めないアプリ（電話・メッセージなど）や許可アプリの使用は段階イベントで増えていく。
// その分を枠の使用時間から差し引くために、ロックが効き始めた／外れたときの段階イベントの値（allMin・allowedMin）を
// 「印」として残し、期間ごとに「ロック中に増えた分」を出す（Quota.usedMinutes が差し引く）。
//
//   - 印を書くのは Shield.reconcile だけ（状態の変化を見ているところ。本体・MonitorExt・PushExt のどれでも）
//   - App Group には1件1ファイル（AppUnlocks と同じ。読んで書き戻すことをしないので、同時に書いても取りこぼさない）。
//     同じ向きの印が重なっても（競合で二重に書いても）、数えるときは「最初の始まり〜次の終わり」だけを使う
//   - リセット時刻で0に戻る: 今の期間（periodStart）の印だけを数える。期間の頭でロックが効いていたかは
//     前の期間の最後の印から決め、効いていれば 0 分から数え始める
//   - 段階イベント（5分刻み）の値で測るので、境目で最大1刻みぶんずれる。区間ごとに下限0

/// ロックの効き始め（locked=true）・外れ（false）の印
struct LockMark: Codable, Equatable {
    var at: String
    /// 書いたときの期間の始まり（UsageState.periodStart）
    var periodStart: String
    var locked: Bool
    var allMin: Int
    var allowedMin: Int
    var route: String?

    var atDate: Date { ISO.parse(at) ?? .distantPast }
}

enum LockSpans {
    static let dirName = "lock-spans"

    static var dir: URL {
        let d = Store.dir.appendingPathComponent(dirName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(
                at: d, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        return d
    }

    private static func entries() -> [(url: URL, mark: LockMark)] {
        let d = dir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { n in
            let u = d.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: u), let m = try? JSONDecoder().decode(LockMark.self, from: data) else {
                try? FileManager.default.removeItem(at: u)   // 読めないものは捨てる
                return nil
            }
            return (u, m)
        }
        .sorted { $0.mark.atDate < $1.mark.atDate }
    }

    /// 全部の印（古い順）
    static var marks: [LockMark] { entries().map(\.mark) }

    /// reconcile から呼ぶ。effective（ロックが効いていて、時間解除も個別解除もない）が最後の印と違えば印を書く
    static func note(effective: Bool, usage u: UsageState, now: Date = Date(), route: String) {
        let es = entries()
        let last = es.last?.mark.locked ?? false
        guard last != effective else { return }
        let m = LockMark(at: ISO.string(now), periodStart: u.periodStart, locked: effective,
                         allMin: u.allMin, allowedMin: u.allowedMin, route: route)
        guard let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: dir.appendingPathComponent("\(UUID().uuidString).json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune(es, current: u.periodStart)
        Log.add(kind: "lockSpan", route: route,
                detail: "\(effective ? "始まり" : "終わり") all=\(u.allMin) allowed=\(u.allowedMin) periodStart=\(u.periodStart)")
    }

    /// 今の期間より前の印は、いちばん新しい1件（期間の頭の状態を決める用）だけ残して消す
    private static func prune(_ es: [(url: URL, mark: LockMark)], current: String) {
        let old = es.filter { $0.mark.periodStart != current }
        for e in old.dropLast() { try? FileManager.default.removeItem(at: e.url) }
    }

    static func clear() {
        for e in entries() { try? FileManager.default.removeItem(at: e.url) }
    }

    /// 今の期間に、ロックが効いているあいだに増えた使用時間（分・数え方ごと）。今も効いていれば今の値まで
    static func lockedMinutes(_ u: UsageState, mode: CountMode, marks ms: [LockMark]? = nil) -> Int {
        let all = ms ?? marks
        let cur = u.periodStart
        // 期間の頭の状態: 前の期間の最後の印（効いていれば、この期間は 0 分から数え始める）
        var state = all.last(where: { $0.periodStart != cur })?.locked ?? false
        var from = (all: 0, allowed: 0)
        var total = 0
        for m in all where m.periodStart == cur {
            if m.locked && !state {
                state = true
                from = (m.allMin, m.allowedMin)
            } else if !m.locked && state {
                state = false
                total += delta(from: from, to: (m.allMin, m.allowedMin), mode: mode)
            }
        }
        if state { total += delta(from: from, to: (u.allMin, u.allowedMin), mode: mode) }
        return max(0, total)
    }

    private static func delta(from a: (all: Int, allowed: Int), to b: (all: Int, allowed: Int), mode: CountMode) -> Int {
        switch mode {
        case .inclusive: return max(0, b.all - a.all)
        case .excludeAllowed: return max(0, (b.all - b.allowed) - (a.all - a.allowed))
        }
    }
}
