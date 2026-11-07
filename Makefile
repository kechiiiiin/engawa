# engawa — スマホ制限アプリの試作（スパイク）。health-sync の Makefile の形に倣う
#
# よく使うのは:
#   make resign        generate → build → install（有料チームなので再署名は年1回でよい見込み）
#   make check         実機なしでコンパイルだけ確かめる（署名しない）
#   make lock / unlock M=15 / state     サーバーを叩く
#   make unlocks       縁側アプリからの解除の履歴（理由つき・SINCE= で絞る）
#   make push-alert / push-silent        Mac から APNs（sandbox）へ送る（tools/push.sh）
#   make events        記録を取って経路別の遅れを表にする（tools/latency.py）
#
# 配る（README「配る（TestFlight）」・fam-echo/ios と同形）
#   make archive            Release で .xcarchive を作る（ビルド番号は日時で自動。BUILD_NUMBER= で上書き可）
#   make export-testflight  .xcarchive から App Store Connect 向けの .ipa を build/export/ に書き出す（送らない）
#   make upload             API キーで App Store Connect へ上げる（Release.local.env と .p8 が要る）
#   make release            archive → upload
#   make verify-ipa         書き出した .ipa の5ターゲットの署名と entitlement を見る
#
# ⚠️ 注意
#   - `*.xcodeproj` は生成物でコミットしない。各ターゲットの先頭で `xcodegen generate` を走らせる
#   - `devicectl` でアプリへ引数を渡すときは前に `--` が要る
#   - `make check` は build/ を壊さないよう build-check/ を使い、終わったら消す
#   - トークン・鍵は ~/.config/engawa/ に置く（リポジトリ・vault の _memo には置かない）。値は表示しない

DEVICE  = 8EAC2623-47F0-58AC-9DEF-8DD9AE4D6E55
BUNDLE  = jp.kechiiiiin.engawa
PROJECT = engawa.xcodeproj
SCHEME  = Engawa
APP     = build/Build/Products/Debug-iphoneos/Engawa.app
CONF    = $(HOME)/.config/engawa

# 有料チームの Team ID。~/.config/engawa/team-id（1行）か `make build TEAM=XXXXXXXXXX`。
# xcodegen が project.yml の ${ENGAWA_TEAM_ID} に展開する（push.sh も同じファイルを読む）
TEAM ?= $(shell cat $(CONF)/team-id 2>/dev/null)
export ENGAWA_TEAM_ID = $(TEAM)
TEAM_ARG = $(if $(TEAM),DEVELOPMENT_TEAM=$(TEAM),)
# PushExt から Family Controls を外して試すとき: make build PUSHEXT_FC_SUFFIX=-noFC
PUSHEXT_FC_SUFFIX ?=
FC_ARG = $(if $(PUSHEXT_FC_SUFFIX),PUSHEXT_FC_SUFFIX=$(PUSHEXT_FC_SUFFIX),)

# サーバー。既定は ~/.config/engawa/server-url、ローカル試験は SERVER=http://127.0.0.1:8788
SERVER ?= $(shell cat $(CONF)/server-url 2>/dev/null)
TOKEN_FILE ?= $(CONF)/token
AUTH = -H "Authorization: Bearer $$(cat $(TOKEN_FILE))"
M ?=

.PHONY: help resign generate build install launch check devices clean \
        lock unlock state unlocks push-alert push-silent events import-token routes test2 usage-n \
        archive export-testflight upload release verify-ipa require-asc-key require-team

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
	@echo "unlocks       アプリからの解除の履歴（理由つき。SINCE=ISO で絞る）"
	@echo "push-alert    Mac から alert プッシュ（R3）"
	@echo "push-silent   Mac からサイレントプッシュ（R2）"
	@echo "events        記録を取って経路別の遅れを表に（SINCE= で絞る）"
	@echo "import-token  トークンとサーバー URL を実機へ流し込む（次の起動で App Group へ）"
	@echo "routes R=poll,usageWake  経路を起動引数で切り替える（書いたものだけオン。アプリが前面に出る）"
	@echo "test2         試験2 の監視を起動引数で登録させる（アプリが前面に出る）"
	@echo "archive       Release で .xcarchive（ビルド番号は日時で自動・BUILD_NUMBER= で上書き）"
	@echo "export-testflight  App Store Connect 向けの .ipa を build/export/ に書き出す（送らない）"
	@echo "upload        App Store Connect へ上げる（TestFlight）"
	@echo "release       archive → upload"
	@echo "verify-ipa    .ipa の5ターゲットの署名と entitlement を見る"

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
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE) -- -engawaRoutes "$(R)"

test2:
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE) -- -engawaRegisterTest2 YES

usage-n:
	@test -n "$(N)" || { echo "N= を渡すこと（60/120/240）"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE) -- -engawaUsageN "$(N)"

## トークン（とサーバー URL）をアプリのコンテナ tmp/ に置く。次の起動で App Group へ移してファイルは消える。値は表示しない
import-token:
	@test -s $(TOKEN_FILE) || { echo "$(TOKEN_FILE) が無い"; exit 1; }
	xcrun devicectl device copy to --device $(DEVICE) \
	  --domain-type appDataContainer --domain-identifier $(BUNDLE) --user mobile \
	  --source $(TOKEN_FILE) --destination tmp/engawa-import-token
	@if [ -s $(CONF)/server-url ]; then \
	  xcrun devicectl device copy to --device $(DEVICE) \
	    --domain-type appDataContainer --domain-identifier $(BUNDLE) --user mobile \
	    --source $(CONF)/server-url --destination tmp/engawa-import-server; fi
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

unlocks: _server
	@curl -sS $(AUTH) "$(SERVER)/unlocks$(if $(SINCE),?since=$(SINCE),)" | python3 -c 'import sys,json; [print(u["at"], str(u["minutes"])+"分", ("個別"+str(u.get("appCount"))+"個" if u.get("kind")=="apps" else "全体")+("・スーパー" if u.get("superLock") else ""), u.get("lockReason") or "-", "使用"+str(u.get("usedMinutes"))+"/"+str(u.get("quotaMinutes")), u["reason"].replace(chr(10)," ")) for u in json.load(sys.stdin)["unlocks"]]'

push-alert: _server
	SERVER="$(SERVER)" TOKEN_FILE="$(TOKEN_FILE)" tools/push.sh alert

push-silent: _server
	SERVER="$(SERVER)" TOKEN_FILE="$(TOKEN_FILE)" tools/push.sh silent

events: _server
	SERVER="$(SERVER)" TOKEN_FILE="$(TOKEN_FILE)" python3 tools/latency.py $(if $(SINCE),--since "$(SINCE)",)

# --- 配る（TestFlight）。fam-echo/ios の Makefile と同形 ---
#
# 署名は API キー＋ -allowProvisioningUpdates の自動署名。archive は開発用（Apple Development）で署名され、
# export-testflight が配布用（Apple Distribution・App Store プロファイル）で署名し直す。
# このとき aps-environment は配布プロファイルに合わせて production になる（entitlements ファイルの development は
# 開発用の make resign のためにそのまま残す）。確かめるのは make verify-ipa。
# xcodebuild の全文ログ（build/archive.log・build/export.log）には API キーのパスと Key ID が出る。build/ は gitignore 済み

RELEASE_ENV   = Release.local.env
ARCHIVE       = build/archive/Engawa.xcarchive
EXPORT_DIR    = build/export
EXPORT_PLIST  = build/ExportOptions.generated.plist
RELEASE_DD    = build/release
VERIFY_DIR    = build/verify-ipa
DESTINATION  ?= export
# ビルド番号（CFBundleVersion）: 「年月日.1時分」（例 20261107.12257）。App Store Connect は同じ番号を受け付けないので、
# 上げるたびに増えればよい。project.yml の CURRENT_PROJECT_VERSION（1）は開発用のまま書き換えない。
# コマンドラインの CURRENT_PROJECT_VERSION= は5ターゲットすべてに効く（本体と拡張の番号は一致が必須）
BUILD_NUMBER ?= $(shell date +%Y%m%d.1%H%M)

# API キー（Release.local.env から読む。環境変数でも渡せる）。値は表示しない
env_value = $(strip $(shell sed -n 's/^$(1)=//p' $(RELEASE_ENV) 2>/dev/null | tail -1))
ASC_KEY_ID    ?= $(call env_value,ASC_KEY_ID)
ASC_ISSUER_ID ?= $(call env_value,ASC_ISSUER_ID)
ASC_KEY_PATH  ?= $(call env_value,ASC_KEY_PATH)
ifeq ($(strip $(ASC_KEY_PATH)),)
ASC_KEY_PATH := $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8
endif
ASC_KEY_PATH := $(patsubst ~/%,$(HOME)/%,$(ASC_KEY_PATH))
ifneq ($(and $(ASC_KEY_ID),$(ASC_ISSUER_ID),$(wildcard $(ASC_KEY_PATH))),)
AUTH_FLAGS = -authenticationKeyPath "$(ASC_KEY_PATH)" -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID)
endif

require-team:
	@test -n "$(TEAM)" || { echo "Team ID がありません（$(CONF)/team-id を置くか TEAM=… を渡す）"; exit 1; }

require-asc-key:
	@test -n "$(ASC_KEY_ID)" -a -n "$(ASC_ISSUER_ID)" || { echo "ASC_KEY_ID / ASC_ISSUER_ID がありません。Release.example.env を見て Release.local.env を作ってください"; exit 1; }
	@test -f "$(ASC_KEY_PATH)" || { echo "API キーがありません: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"; exit 1; }

archive: require-team require-asc-key generate
	@mkdir -p build/archive
	rm -rf build/archive/Engawa.xcarchive
	@echo "ビルド番号 $(BUILD_NUMBER) で archive します"
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -derivedDataPath $(RELEASE_DD) -archivePath $(ARCHIVE) \
	  -allowProvisioningUpdates $(AUTH_FLAGS) $(TEAM_ARG) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) archive 2>&1 \
	  | tee build/archive.log | grep -E '(error|warning):|ARCHIVE (SUCCEEDED|FAILED)' ; \
	  grep -q 'ARCHIVE SUCCEEDED' build/archive.log || { echo "archive に失敗しました（全文は build/archive.log）"; exit 1; }
	@echo "$(BUILD_NUMBER)" > build/archive/BUILD_NUMBER
	@printf "できました: %s（版 %s・ビルド %s）\n" "$(ARCHIVE)" \
	  "$$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' $(ARCHIVE)/Info.plist)" \
	  "$$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' $(ARCHIVE)/Info.plist)"

export-testflight: require-team require-asc-key
	@test -d $(ARCHIVE) || { echo "$(ARCHIVE) がありません。先に make archive"; exit 1; }
	rm -rf build/export
	@mkdir -p $(EXPORT_DIR)
	cp ExportOptions.plist $(EXPORT_PLIST)
	@plutil -replace teamID -string "$(TEAM)" $(EXPORT_PLIST)
	plutil -replace destination -string $(DESTINATION) $(EXPORT_PLIST)
	@xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportPath $(EXPORT_DIR) \
	  -exportOptionsPlist $(EXPORT_PLIST) -allowProvisioningUpdates $(AUTH_FLAGS) 2>&1 \
	  | tee build/export.log | grep -E '(error|warning):|EXPORT (SUCCEEDED|FAILED)|Upload|Uploaded|uploaded' ; \
	  grep -q 'EXPORT SUCCEEDED' build/export.log || { echo "export に失敗しました（全文は build/export.log）"; exit 1; }
	@if [ "$(DESTINATION)" = export ]; then ls -lh $(EXPORT_DIR)/*.ipa; else echo "App Store Connect へ上げました（処理が済むと TestFlight に出る）"; fi

upload: require-asc-key
	$(MAKE) export-testflight DESTINATION=upload

release: archive upload

## .ipa を build/verify-ipa/ に展開して、本体と拡張4つの署名者・entitlement を出す（Family Controls・aps-environment の確認用）
verify-ipa:
	@ls $(EXPORT_DIR)/*.ipa >/dev/null 2>&1 || { echo "$(EXPORT_DIR)/*.ipa がありません。先に make export-testflight"; exit 1; }
	rm -rf build/verify-ipa
	@mkdir -p $(VERIFY_DIR) && unzip -q "$$(ls $(EXPORT_DIR)/*.ipa | head -1)" -d $(VERIFY_DIR)
	@for b in $(VERIFY_DIR)/Payload/Engawa.app $(VERIFY_DIR)/Payload/Engawa.app/PlugIns/*.appex; do \
	  echo "== $$(basename $$b)（ビルド $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $$b/Info.plist)）"; \
	  codesign -dvv $$b 2>&1 | grep -E '^Authority=Apple (Distribution|Development)' | sed 's/ (.*//; s/^/  /'; \
	  codesign -d --entitlements :- $$b 2>/dev/null | plutil -convert json -o - - | python3 -c 'import sys,json; e=json.load(sys.stdin); print("  family-controls:", e.get("com.apple.developer.family-controls"), "/ aps-environment:", e.get("aps-environment", "-"), "/ get-task-allow:", e.get("get-task-allow"), "/ beta-reports-active:", e.get("beta-reports-active"))'; \
	done
