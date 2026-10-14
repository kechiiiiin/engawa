# engawa（縁側） — スマホ制限アプリの試作（スパイク）

縁側: 自分の iPhone の使用時間を縛るアプリ。いまは試作（スパイク）段階。

自分の iPhone を「外（サーバー）から」ロックできるか、許可アプリを除いて使用時間を数えられるかを、実機で決着させるための捨てる前提の試作。
設計書（正）: jinsei vault `hestia/projects/スマホ制限アプリ試作設計.md`。名前・Bundle ID は仮。

## 普段使いの形（2026-10-14〜）

本番設計（たたき台）: jinsei vault `hestia/projects/縁側本番設計.md`。冒頭の「2026-10-14 本人判断」が本文より優先（解除はアプリ内・理由＋時間。ブラウザの解除ページは作らない）。

- ホーム（`App/HomeView.swift`）: ロック中か・理由（枠切れ／手動／時間解除の残り）・今日の使用時間と残りの枠・「解除する」（理由必須＋15／30／60分）・代わりにやりたいこと
- 設定（`App/SettingsView.swift`）: 許可アプリ・1日の枠（初期 2時間30分）・リセット時刻（初期 4:00）・やりたいこと一覧の編集。奥に「開発者向け」（`App/DeveloperView.swift` = 試作の計測用画面）
- ロックの決め方は三層: `ロックする = (手動ロック || 枠ロック) && !時間解除中`（`Shared/Shield.swift` の `reconcile`）。手動ロックはサーバー（`make lock`）、枠ロックは端末、時間解除はサーバー（`make unlock M=`）か縁側アプリ
- 枠（`Shared/Quota.swift`）: 監視 `daily`（リセット時刻〜翌日の1分前）に段階イベント `all-k`＋`quota`。**数え方の差し替え点はこのファイルだけ**（試験2 待ち。初期は許可アプリ込み）
- やりたいこと一覧は App Group の `ideas.json`（`Shared/Ideas.swift`。無ければ既定の10件）。Shield はここからランダム
- アプリからの解除は `POST /unlocks` に理由つきで記録（届かなければ App Group に溜めて次に送る）。履歴は `make unlocks`

## 構成

| ディレクトリ | 中身 |
|---|---|
| `App/` | 本体 `Engawa`（認可・許可アプリの選択・前面で同期 R1・サイレントプッシュ R2・経路の切り替え・試験2 の登録・記録の表示と送信） |
| `MonitorExt/` | DeviceActivityMonitor 拡張（全コールバックで目覚めを記録・R4／R5 でサーバーを見に行く・時間解除の再ロック） |
| `ShieldConfigExt/` | ロック画面の文言（`ideas.json` か App Group の上書きからランダム） |
| `ShieldActionExt/` | 「閉じる」ボタン（記録して `.close`） |
| `PushExt/` | Notification Service 拡張（R3: alert プッシュのペイロードの state を shield に反映し、成否を本文に足す） |
| `Shared/` | 全ターゲット共通（App Group のファイル置き場・記録・同期待ちの通信・shield の掛け外し・監視の登録） |
| `server/` | Cloudflare Workers + D1（`/state` `/lock` `/unlock` `/device` `/events` `/unlocks` `/`） |
| `tools/` | `push.sh`（Mac から APNs sandbox へ）・`latency.py`（経路別の遅れの表） |

経路: R1 アプリを開いて同期／R2 サイレントプッシュ／R3 alert プッシュ＋NSE／R4 予定の目覚まし（15分×2本）／R5 使用量の目覚まし（使用1分ごと）。

`~/.config/engawa/` に置くもの（リポジトリには入れない）:

| ファイル | 中身 |
|---|---|
| `token` | サーバーの Bearer トークン（`openssl rand -hex 32` で作る） |
| `server-url` | `https://engawa.<サブドメイン>.workers.dev` |
| `team-id` | 有料チームの Team ID（10桁） |
| `AuthKey_<KEYID>.p8` | APNs の鍵（`key-id` は無くてもファイル名から読む） |

## 準備

【啓輔・ブラウザ】（初回1回だけ）
1. developer.apple.com → Membership details で **Team ID** を見る → ヘスティアに伝える
2. developer.apple.com → Certificates, Identifiers & Profiles → Keys → ＋ → 「Apple Push Notifications service (APNs)」にチェック → 作成 → **.p8 をダウンロード**（1回しか落とせない）→ `~/.config/engawa/` に置く

【ヘスティア・コマンド】
```sh
mkdir -p ~/.config/engawa && chmod 700 ~/.config/engawa
echo XXXXXXXXXX > ~/.config/engawa/team-id          # 有料チームの Team ID
openssl rand -hex 32 > ~/.config/engawa/token && chmod 600 ~/.config/engawa/token

# サーバー（初回）
cd server && npm install
npx wrangler d1 create engawa                        # 出た database_id を wrangler.jsonc に入れる
npx wrangler d1 migrations apply engawa --remote
npx wrangler secret put API_TOKEN < ~/.config/engawa/token
npx wrangler deploy                                        # 出た URL を ~/.config/engawa/server-url へ
cd ..

# iOS（iPhone を繋ぐか同じ Wi-Fi で）
make resign            # generate → build（-allowProvisioningUpdates）→ install
make import-token      # トークンとサーバー URL を実機へ。次に開いたとき取り込まれる
make state; make events
```

【啓輔・実機】試作アプリを開く → Face ID でスクリーンタイムを認可 → 通知を許可 → 「許可アプリを選ぶ」で試験用に2つ（例: 時計・天気）。試験2 用に「すべてのカテゴリ」も選ぶ。

ローカルでサーバーだけ試す: `cd server && echo API_TOKEN=local > .dev.vars && npm run dev`（ポート 8788。8787 は health-sync の受け口が使っている）→ `echo local > "$TMPDIR/t" && make state SERVER=http://127.0.0.1:8788 TOKEN_FILE="$TMPDIR/t"`

## 試験で叩くコマンド

経路の切り替え（書いたものだけオン・アプリが一度前面に出る）: `make routes R=alertPush`／`R=poll`／`R=usageWake`／`R=silentPush`／`R=none`

### 試験1: 外からのロック
| 手順 | 誰 | コマンド・操作 |
|---|---|---|
| 経路を1つだけオン | ヘスティア | `make routes R=alertPush`（R3 → R5 → R4 の順。R2 は1回だけ） |
| 払って終了・許可アプリを開いたまま | 啓輔・実機 | App スイッチャーで上に払う → 時計を開く |
| ロック | ヘスティア | `make lock` ＋（R3）`make push-alert`／（R2）`make push-silent` |
| ロック画面を目で確認 | 啓輔・実機 | 許可していないアプリ（X など）を開く |
| 解除（1-3） | ヘスティア → 啓輔 | `make unlock` → 試作アプリを開く → 払って終了 |
| 集計 | ヘスティア | `make events`（経路別の中央値・最大・60秒以内の割合・R1 の開いてから反映まで） |
| 1-4 放置 | ヘスティア → 啓輔 | `make routes R=poll,usageWake` → 72時間開かない → `make events` の「目覚め」表 |

R5 の段数: `make usage-n N=120`（アプリ内の Picker でも可）。登録できた最大数は記録の `arm R5 registered=` に出る。

### 試験2: 許可アプリを除いて数えられるか
`make test2`（監視を登録）→ 啓輔さんが許可アプリだけ15分（2-1）／許可していないアプリを10分（2-2・3回）→ `make events` の「しきい値の発火」。2-3 は段階イベント（E-step-all-k／E-step-allowed-k）の最後に発火したもの同士の差をスクリーンタイムの値と比べる。

### 試験3: ロック画面の文言
`make lock` → 啓輔さんが許可していないアプリを5回開き直す → `make events` の「ロック画面の文言の種類」。上書き: アプリの「上書きを読み込む（保存）」（サンプルに80字の長い文言が入っている）。

### 試験4: 時間解除のあとの自動再ロック
`make lock` → 開いて同期 → `make unlock M=15` → 開いて同期 → 払って終了 → 15分後から1分おきに確かめる。記録の `relock` と突き合わせる。

### PushExt から Family Controls を外して試す
`make build PUSHEXT_FC_SUFFIX=-noFC && make install`

## 啓輔さんの手作業（まとめ）

| いつ | 誰 | 何を | 回数 |
|---|---|---|---|
| 初回 | 【啓輔・ブラウザ】 | Team ID を見る・APNs の .p8 を作って置く | 1回 |
| 初回インストール後 | 【啓輔・実機】 | 認可（Face ID）・通知の許可・許可アプリの選択 | 1回 |
| 試験中 | 【啓輔・実機】 | 払って終了・アプリを使う・ロック画面を見る | 試験ごと |

それ以外（生成・ビルド・インストール・デプロイ・ロック指示・プッシュ・集計）はヘスティアのコマンドで済む。

## メモ

- `*.xcodeproj` は生成物（`xcodegen generate`）。コミットしない
- `devicectl` でアプリへ引数を渡すときは前に `--`
- 拡張の `NSExtensionPointIdentifier` は Xcode 27.0 のテンプレート（`Xcode.app/…/Templates/Project Templates/iOS/Application Extension/*.xctemplate/TemplateInfo.plist`）から写した
- 記録は App Group の `engawa/log.jsonl`（2000行まで）と未送信分の `outbox.jsonl`。ファイル保護は `completeUntilFirstUserAuthentication`
- サーバーの API は設計の7本に `GET /device`（push.sh がデバイストークンを取る用）を足している
