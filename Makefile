# seigen-spike — スマホ制限アプリの試作（スパイク）。health-sync の Makefile の形に倣う
#
# よく使うのは:
#   make resign        generate → build → install（有料チームなので再署名は年1回でよい見込み）
#   make check         実機なしでコンパイルだけ確かめる（署名しない）
#   make lock / unlock M=15 / state     サーバーを叩く
#   make push-alert / push-silent        Mac から APNs（sandbox）へ送る（tools/push.sh）
#   make events        記録を取って経路別の遅れを表にする（tools/latency.py）
#
# ⚠️ 注意
#   - `*.xcodeproj` は生成物でコミットしない。各ターゲットの先頭で `xcodegen generate` を走らせる
#   - `devicectl` でアプリへ引数を渡すときは前に `--` が要る
#   - `make check` は build/ を壊さないよう build-check/ を使い、終わったら消す
#   - トークン・鍵は ~/.config/seigen-spike/ に置く（リポジトリ・vault の _memo には置かない）。値は表示しない

DEVICE  = 8EAC2623-47F0-58AC-9DEF-8DD9AE4D6E55
BUNDLE  = jp.kechiiiiin.seigenspike
PROJECT = seigen-spike.xcodeproj
SCHEME  = SeigenSpike
APP     = build/Build/Products/Debug-iphoneos/SeigenSpike.app
CONF    = $(HOME)/.config/seigen-spike

# 有料チームの Team ID。~/.config/seigen-spike/team-id（1行）か `make build TEAM=XXXXXXXXXX`。
# xcodegen が project.yml の ${SEIGEN_TEAM_ID} に展開する（push.sh も同じファイルを読む）
TEAM ?= $(shell cat $(CONF)/team-id 2>/dev/null)
export SEIGEN_TEAM_ID = $(TEAM)
TEAM_ARG = $(if $(TEAM),DEVELOPMENT_TEAM=$(TEAM),)
# PushExt から Family Controls を外して試すとき: make build PUSHEXT_FC_SUFFIX=-noFC
PUSHEXT_FC_SUFFIX ?=
FC_ARG = $(if $(PUSHEXT_FC_SUFFIX),PUSHEXT_FC_SUFFIX=$(PUSHEXT_FC_SUFFIX),)

# サーバー。既定は ~/.config/seigen-spike/server-url、ローカル試験は SERVER=http://127.0.0.1:8788
SERVER ?= $(shell cat $(CONF)/server-url 2>/dev/null)
TOKEN_FILE ?= $(CONF)/token
AUTH = -H "Authorization: Bearer $$(cat $(TOKEN_FILE))"
M ?=

.PHONY: help resign generate build install launch check devices clean \
        lock unlock state push-alert push-silent events import-token routes test2 usage-n

help:
	@echo "resign        generate → build → install"
	@echo "generate      xcodegen で .xcodeproj を作る"
	@echo "build         実機向けにビルドして署名（-allowProvisioningUpdates）"
	@echo "install       実機へ入れる（devicectl）"
	@echo "launch        実機で起動してコンソールを見る"
	@echo "check         実機なしでコンパイルだけ（署名なし）"
	@echo "devices       繋がっている端末の一覧"
	@echo "clean         build/ build-check/ と生成した .xcodeproj を消す"
	@echo "lock          サーバーをロックに（PUSH=alert|silent で Worker からも送る）"
	@echo "unlock M=15   サーバーを解除に（M を付けると時間解除）"
	@echo "state         サーバーの状態"
	@echo "push-alert    Mac から alert プッシュ（R3）"
	@echo "push-silent   Mac からサイレントプッシュ（R2）"
	@echo "events        記録を取って経路別の遅れを表に（SINCE= で絞る）"
	@echo "import-token  トークンとサーバー URL を実機へ流し込む（次の起動で App Group へ）"
	@echo "routes R=poll,usageWake  経路を起動引数で切り替える（書いたものだけオン。アプリが前面に出る）"
	@echo "test2         試験2 の監視を起動引数で登録させる（アプリが前面に出る）"

resign: generate build install
	@echo "✅ 実機に入れた"

generate:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination "id=$(DEVICE)" -configuration Debug \
	  -derivedDataPath build -allowProvisioningUpdates $(TEAM_ARG) $(FC_ARG) build

## 端末を繋がずに、署名つきで通るか（プロファイルを作れるか）だけ確かめる
build-generic: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS' -configuration Debug \
	  -derivedDataPath build -allowProvisioningUpdates $(TEAM_ARG) $(FC_ARG) build

install:
	xcrun devicectl device install app --device $(DEVICE) $(APP)

launch:
	xcrun devicectl device process launch --device $(DEVICE) --console \
	  --terminate-existing $(BUNDLE)

## 経路を切り替える（例: make routes R=alertPush）。⚠️ アプリへの引数の前の `--` は必須
routes:
	@test -n "$(R)" || { echo "R= を渡すこと（例: make routes R=poll  ／ 全部切るなら R=none）"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE) -- -seigenRoutes "$(R)"

test2:
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE) -- -seigenRegisterTest2 YES

usage-n:
	@test -n "$(N)" || { echo "N= を渡すこと（60/120/240）"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE) -- -seigenUsageN "$(N)"

## トークン（とサーバー URL）をアプリのコンテナ tmp/ に置く。次の起動で App Group へ移してファイルは消える。値は表示しない
import-token:
	@test -s $(TOKEN_FILE) || { echo "$(TOKEN_FILE) が無い"; exit 1; }
	xcrun devicectl device copy to --device $(DEVICE) \
	  --domain-type appDataContainer --domain-identifier $(BUNDLE) --user mobile \
	  --source $(TOKEN_FILE) --destination tmp/seigen-import-token
	@if [ -s $(CONF)/server-url ]; then \
	  xcrun devicectl device copy to --device $(DEVICE) \
	    --domain-type appDataContainer --domain-identifier $(BUNDLE) --user mobile \
	    --source $(CONF)/server-url --destination tmp/seigen-import-server; fi
	@echo "✅ 置いた。iPhone で試作アプリを開く（または make launch）と取り込まれ、ファイルは消える"

check: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS' -configuration Debug \
	  -derivedDataPath build-check CODE_SIGNING_ALLOWED=NO build
	@rm -rf build-check
	@echo "✅ コンパイルは通る"

devices:
	xcrun devicectl list devices

clean:
	rm -rf build build-check $(PROJECT)

# --- サーバー ---

_server:
	@test -n "$(SERVER)" || { echo "SERVER が無い（$(CONF)/server-url を置くか SERVER=… を渡す）"; exit 1; }
	@test -s $(TOKEN_FILE) || { echo "$(TOKEN_FILE) が無い"; exit 1; }

lock: _server
	@date -u +"送った時刻 %Y-%m-%dT%H:%M:%SZ"
	@curl -sS -X POST $(AUTH) "$(SERVER)/lock?push=$(or $(PUSH),none)"; echo

unlock: _server
	@date -u +"送った時刻 %Y-%m-%dT%H:%M:%SZ"
	@curl -sS -X POST $(AUTH) "$(SERVER)/unlock?push=$(or $(PUSH),none)$(if $(M),&minutes=$(M),)"; echo

state: _server
	@curl -sS $(AUTH) "$(SERVER)/state"; echo

push-alert: _server
	SERVER="$(SERVER)" TOKEN_FILE="$(TOKEN_FILE)" tools/push.sh alert

push-silent: _server
	SERVER="$(SERVER)" TOKEN_FILE="$(TOKEN_FILE)" tools/push.sh silent

events: _server
	SERVER="$(SERVER)" TOKEN_FILE="$(TOKEN_FILE)" python3 tools/latency.py $(if $(SINCE),--since "$(SINCE)",)
