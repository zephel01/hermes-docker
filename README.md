# hermes-docker — 初回構築手順書

`nousresearch/hermes-agent` を中心に **gateway / WebUI / HUD / SearXNG** の 4 サービスを
docker compose で立ち上げるための一式と、その**ゼロからの構築手順**。

障害発生時の調査記録は別ファイル [`TROUBLESHOOTING-webui-agent.md`](./TROUBLESHOOTING-webui-agent.md) に分離してある。
本ファイルは「動く状態を最短で作る」ための前向きな手順に絞る。

---

## 0. このリポジトリで何が立ち上がるか

| サービス | コンテナ名 | image | host から見えるポート | 役割 |
|---|---|---|---|---|
| `hermes-agent` | `hermes-agent` | `nousresearch/hermes-agent:main` | `127.0.0.1:8642` (現状未使用) | `hermes gateway run` — messaging + cron。s6 が gateway を supervise |
| `hermes-webui` | `hermes-webui` | local build（`./hermes-webui/Dockerfile`） | `127.0.0.1:8787` | チャット UI。**WebUI コンテナ内で独自の Hermes エージェントを起動**してチャットを処理する |
| `hermes-hudui` | `hermes-hudui` | local build（`./hermes-hudui/Dockerfile`） | `127.0.0.1:3001` | `~/.hermes/` の中身を可視化する React HUD |
| `searxng` | `searxng` | `searxng/searxng:latest` | `127.0.0.1:8080` | Web 検索バックエンド（config.yaml で `web.search_backend: searxng` のときに使う） |

ネットワークは `hermes-net`（bridge）。
ホストの `~/.hermes/` は 3 つの hermes 系コンテナすべてに bind mount される（**ここが状態の真実**）。
hermes-agent のソース `/opt/hermes` は named volume `hermes-docker_hermes-agent-src`
で agent ⇄ webui 間で共有される（webui がインプロセスで agent を import するため）。

> ⚠ **コンテナ内の `/home/hermes/...`, `/home/hermeswebui/...`, `/root/...`, `/opt/hermes/...` は
> ホストの `~/` 配下のディレクトリではない**。これらは **コンテナ内の独立した Linux
> ファイルシステム**で、ホストから直接見えるのは bind mount で繋いだ範囲だけ（下図の
> `bind ~/.hermes` などの矢印）。`docker compose down` でコンテナを消すと、bind 元
> （ホスト側）以外は **全部消える**。たとえば `/opt/hermes` 配下を編集してもホストの
> リポジトリには反映されないし（リポジトリの `./hermes-webui/` 等とは別物）、
> 逆にコンテナ内に `/tmp/foo` を作ってもホスト `~/tmp/foo` には現れない。

### ホスト ⇄ コンテナのマッピング図

```
══════════════════════════ ホスト (あなたの Mac / Linux) ═══════════════════════

  ~/works/project/hermes-docker/        ← このリポジトリ
  ├─ docker-compose.yml
  ├─ .env                               ← compose 変数置換用
  │                                       (HOST_UID / HOST_GID / SEARXNG_SECRET_KEY)
  ├─ hermes-webui/
  │   ├─ Dockerfile                     ← webui image のビルド元
  │   ├─ .env                           ← webui プロセス用 (HERMES_WEBUI_PASSWORD 等)
  │   └─ api/config.py                  ← ⚠ ローカルパッチが当たっている (§6)
  ├─ hermes-hudui/Dockerfile            ← hudui image のビルド元
  └─ searxng/settings.yml               ← searxng 設定 (bind 元)

  ~/.hermes/                            ★ Hermes "状態" の真実。3 コンテナ全部から見える
  ├─ config.yaml                          (LLM モデル、tool 設定 …)
  ├─ .env                               ★ LLM/tool 系 API キーの単一ソース
  ├─ auth.json                            (pooled credentials, hermes auth add の保存先)
  ├─ sessions/  skills/  memories/  logs/
  ├─ state.db    cron/    webui/    …

  ~/workspace/                          ← webui の file browser が表示するディレクトリ

  /var/lib/docker/volumes/              ⚠ ホストの ~/ には現れない Docker 管理領域
  └─ hermes-docker_hermes-agent-src/    ← named volume
       └ hermes-agent image の /opt/hermes が初回作成時にここへシードされ保持される
         (docker compose down では消えない。docker volume rm で明示的に消す)

═════════════════════════ コンテナ (docker compose 起動中だけ存在) ═════════════════════════

┌─ hermes-agent ────────────────────┐   ┌─ hermes-webui ─────────────────────────────┐
│ user: hermes (uid=1000)           │   │ user: hermeswebui (uid=1024)               │
│ command: hermes gateway run       │   │ コンテナ内で別の Hermes Agent も走る (※)    │
│                                   │   │                                            │
│ /home/hermes/.hermes/             │   │ /home/hermeswebui/.hermes/                 │
│   ↑ bind ──── ~/.hermes ──── bind ↑   │ ↑                                          │
│                                   │   │                                            │
│ /opt/hermes/                      │   │ /home/hermeswebui/.hermes/hermes-agent/    │
│   ↑ named volume ─── hermes-agent-src ─── 同じ volume を共有 ↑                     │
│                                   │   │                                            │
│ Listen 8642 → host 127.0.0.1:8642 │   │ /workspace/  ← bind ~/workspace            │
│   (gateway は HTTP 出してないので │   │ Listen 8787 → host 127.0.0.1:8787 (UI)     │
│    現状この port は使われていない) │   │                                            │
└───────────────────────────────────┘   └────────────────────────────────────────────┘

┌─ hermes-hudui ────────────────────┐   ┌─ searxng ─────────────────────────┐
│ user: root ⚠                      │   │ image: searxng/searxng:latest     │
│ React + FastAPI HUD               │   │                                   │
│                                   │   │ /etc/searxng/  ← bind ./searxng/  │
│ /root/.hermes/                    │   │                                   │
│   ↑ bind ──── ~/.hermes           │   │ Listen 8080 → host 127.0.0.1:8080 │
│                                   │   │                                   │
│ Listen 3001 → host 127.0.0.1:3001 │   └───────────────────────────────────┘
└───────────────────────────────────┘

凡例:
  bind ~/.hermes    : ホストの ~/.hermes と "同じ実体" がコンテナ内パスに現れる。
                      編集はホスト側のエディタで行ってよい。docker compose down しても残る。
  named volume      : Docker 管理領域内の volume が "同じ実体" として現れる。
                      ホストの ~/ からは直接見えない。docker compose down では消えず、
                      docker volume rm で明示的に削除しないと残り続ける (§7 参照)。
  Listen X → host Y : コンテナ内 port X を、ホストの 127.0.0.1:Y に publish している。
                      127.0.0.1 だけにバインドしているので外部公開はされていない。

(※) hermes-webui が「コンテナ内で独立した Hermes エージェントを起動する」点は
   このスタック最大の落とし穴。gateway とは別エージェントなので、設定が見える範囲が
   非対称になる。共通グラウンドは ~/.hermes/ だけ ([TROUBLESHOOTING §2](./TROUBLESHOOTING-webui-agent.md#2-前提アーキテクチャ重要))。
```

### 「ホストと同じ実体」になっている場所だけ覚えればよい

| コンテナ内パス | ホスト側の実体 | 編集すべき場所 |
|---|---|---|
| `/home/hermes/.hermes/` (agent) | `~/.hermes/` | **ホスト側のエディタで OK** |
| `/home/hermeswebui/.hermes/` (webui) | `~/.hermes/`（同じ実体） | 同上 |
| `/root/.hermes/` (hudui) | `~/.hermes/`（同じ実体、ただし root 権限注意） | 同上 |
| `/workspace/` (webui) | `~/workspace/` | ホスト側で OK |
| `/etc/searxng/` (searxng) | `./searxng/`（リポジトリ内） | リポジトリ側で OK |
| `/opt/hermes/` (agent, webui) | **どこにも無い**（named volume 内） | 直接編集してはいけない。image を作り直す経路で更新する |
| 上記以外 (e.g. `/tmp`, `/etc`, `/var`) | **どこにも無い**（コンテナレイヤ） | 触っても `docker compose down` で消える |

---

## 1. 前提

ホスト要件:

- Docker Engine 20.10+ / Docker Desktop（compose v2 + BuildKit 同梱、Docker 23+ なら自動）
- `git`（リポジトリ + 2 つの git submodule の取得に使う）
- `~/.hermes/` がすでに存在し、`config.yaml` がある（hermes-cli を1度ホストで動かしているか、別マシンから持ってきた状態）
  - 完全な新規ユーザは先に hermes-cli をローカル install → 起動 → 終了 で雛形を生成する想定
- `~/workspace/`（hermes-webui の file browser が `/workspace` として参照する。空ディレクトリで構わない）
- ホストの空きディスク: ベース image だけで **約 5.5GB**（`nousresearch/hermes-agent` が 4.78GB）

このリポジトリは **2 つの upstream リポジトリを git submodule として束ねている**:

| サブモジュール | upstream | 用途 |
|---|---|---|
| `hermes-webui/` | https://github.com/nesquena/hermes-webui | チャット UI のソース |
| `hermes-hudui/` | https://github.com/joeynyc/hermes-hudui | HUD UI のソース |

そのため `git clone` の段階で `--recurse-submodules` を付けるか、後から `scripts/bootstrap.sh` を
走らせる必要がある（§3-1 参照）。

このリポジトリ自体に必要な秘密情報:

| 場所 | 変数 | 用途 |
|---|---|---|
| `./.env`（compose 変数置換用） | `SEARXNG_SECRET_KEY` | SearXNG の Cookie 署名キー（任意の 64hex 文字列） |
| `./.env` | `HOST_UID` / `HOST_GID` | hermes-agent コンテナ内の hermes ユーザの UID/GID。bind mount 越しに `~/.hermes` を読み書きするため一致が必要 |
| `~/.hermes/.env` | `API_SERVER_KEY` 等 | **両エージェント（gateway / webui）が共通で読む秘密**。LLM API キーや FIRECRAWL_API_KEY 等の web ツール系の鍵もここに置く |
| `./hermes-webui/.env` | `HERMES_WEBUI_PASSWORD` 他 | **webui プロセスのみ**の設定（ポート、UI 認証パスワード等）。LLM/web ツールの鍵はここに書かない |

> **重要**: ツール系の秘密（`SEARXNG_URL`, `FIRECRAWL_API_KEY`, `EXA_API_KEY` 等）を
> compose の `environment:` や `./hermes-webui/.env` に書くと、**webui 側の
> エージェントから見えなくなり**チャットの検索/抽出が壊れる。理由は
> [TROUBLESHOOTING §3](./TROUBLESHOOTING-webui-agent.md#3-根本原因-環境変数の-split-brain検索が接続できない) を参照。
> **必ず `~/.hermes/.env` を単一ソースにする**。

### 1-1. プラットフォーム別の差（macOS / Linux / WSL2）

セットアップ手順そのものは共通（`docker compose ...` 以降は同一コマンドで動く）。
ただし **以下 4 点でホスト側の前提が違う**ので、自分の環境に合わせて読み替える:

| 項目 | macOS | Linux | Windows WSL2 |
|---|---|---|---|
| Docker | Docker Desktop / OrbStack / Colima のいずれか | Docker Engine 直入れ（公式 apt repo 等） | Docker Desktop + WSL2 integration、または WSL2 ディストリ内に Engine 直入れ |
| `HOST_UID` / `HOST_GID` | **何でも動く**（VirtioFS / gRPC-FUSE が UID を透過マッピング。デフォルト 1000 のままで OK） | **`id -u` / `id -g` に必ず一致**（ズレると bind mount で permission denied） | Linux と同じ扱い。**WSL2 ディストリ内で `id -u`** に一致させる |
| `~/.hermes/` と `~/workspace/` の置き場所 | Mac 側ホームの素のパスで OK | ホストの素のパスで OK | ★ **必ず WSL2 内 Linux FS** (`/home/<user>/.hermes/`)。`/mnt/c/Users/...` に置くと 9p プロトコル経由で SQLite 書き込みが極端に遅くロック競合も起きる |
| ブラウザ ⇄ コンテナ（UI / OAuth callback） | host のブラウザで `localhost:8787` がそのまま開く | 同左 | host (Windows) ブラウザでも `localhost:8787` は通る（WSL2 の localhost relay）。OAuth URL は `wslview <url>` か手で Windows ブラウザに貼る |

#### WSL2 ユーザの追加注意

- **`~` の指す先**: WSL2 シェルでの `~/works/project/hermes-docker/` は **WSL2 ディストリ内の
  Linux ホーム**。Windows 側エディタから触りたい場合は `\\wsl$\<Distro>\home\<user>\...`
  経由でアクセスする。Windows 側 `C:\` 配下にプロジェクトを置くと bind mount 性能が
  大幅に劣化するため非推奨。
- **Docker context**: Docker Desktop の WSL2 integration が ON なら、WSL2 シェルでも
  Windows PowerShell でも同じデーモンを見る。混在させない（特に `docker compose build`
  は WSL2 側で統一する）と path 周りの事故が減る。
- **改行コード**: `scripts/bootstrap.sh` は LF 必須。Windows 側 git の
  `core.autocrlf=true` でチェックアウトすると CRLF に化けて
  `bad interpreter: /usr/bin/env bash^M` で実行不能になる。本リポジトリは
  `.gitattributes` で `*.sh text eol=lf` を強制しているので、**WSL2 内の git で
  clone する限り問題なし**。Windows 側 git でチェックアウトする運用はやめる。
- **OAuth `--manual-paste`**: `--no-browser` のループバック callback が
  **コンテナの 127.0.0.1** になる事情は WSL2 でも同じなので、§5-5-1 の
  `--manual-paste` 経路をそのまま使えばよい。URL は Windows ブラウザに手でコピーで OK。

#### macOS ユーザの注意

- `id -u` は通常 501、`HOST_UID` のデフォルト 1000 とは不一致だが **Docker Desktop が
  吸収する**ので実害なし。`docker exec` でコンテナに入ると `id` は `uid=1000(hermes)` で
  見える（このリポジトリの動作検証環境がまさにこれ）。
- ファイルシステム性能は VirtioFS 系を選ぶと bind mount の速度が改善する
  （Docker Desktop の Settings → General → "Use virtualization framework" / "VirtioFS"）。
  デフォルト設定でも実用上は十分。

#### Linux ユーザの注意

- `~/.hermes/` を root 所有にしてしまっていると bind mount でコンテナの hermes
  (uid=1000) ユーザから書けない。`sudo chown -R $(id -u):$(id -g) ~/.hermes` で直す。
- Docker daemon socket (`/var/run/docker.sock`) を非 root で叩くため、ユーザを `docker`
  グループに入れる（`sudo usermod -aG docker $USER` → 再ログイン）。
  Docker Desktop for Linux を使っているなら不要。
- SELinux / AppArmor が enforce な distro では bind mount に `:z` / `:Z` ラベルを足す
  必要があるケースがある（本リポでは指定していない）。`Permission denied` が出るのに
  UID は合っているなら SELinux を疑う。`getenforce` で確認、`audit2allow` で診断。

---

## 2. ファイル構成

```
.
├── .env                           # compose 変数置換専用 (HOST_UID/GID, SEARXNG_SECRET_KEY) ★gitignore
├── .gitignore
├── .gitmodules                    # hermes-webui / hermes-hudui の URL と pinned commit を記録
├── docker-compose.yml             # 4 サービス定義 + named volume + network
├── README.md
├── TROUBLESHOOTING-webui-agent.md # 既知の不具合・復旧手順・compose 設計上の弱点
│
├── hermes-webui/                  # ⊕ git submodule (nesquena/hermes-webui, pinned)
│   ├── api/config.py              #    ← 起動時 bootstrap.sh が patches/ から動的に書き換える
│   ├── .env                       #    webui プロセス用 (HERMES_WEBUI_PASSWORD 等)
│   └── ...                        #    その他 upstream のソース
│
├── hermes-hudui/                  # ⊕ git submodule (joeynyc/hermes-hudui, pinned)
│   └── ...                        #    upstream のソース (Dockerfile は含まない — 下記に分離)
│
├── dockerfiles/
│   └── hudui.Dockerfile           # hudui 用の Dockerfile (upstream に無いのでここに置く)
│
├── patches/
│   └── hermes-webui/
│       └── 0001-xai-oauth-default-injection.patch
│                                   # webui submodule に bootstrap.sh で当てるローカルパッチ
│
├── scripts/
│   └── bootstrap.sh               # submodule init + patches/ 適用。clone / submodule 更新後に必須
│
└── searxng/
    └── settings.yml               # SearXNG の設定 (起動時に /etc/searxng にマウント)
```

サブモジュール部分は `.gitmodules` で commit pin されている:

```
[submodule "hermes-webui"]
        path = hermes-webui
        url  = https://github.com/nesquena/hermes-webui.git
[submodule "hermes-hudui"]
        path = hermes-hudui
        url  = https://github.com/joeynyc/hermes-hudui.git
```

`git submodule status` で現在 pin されている commit を確認できる。新しい人が clone した
時もこの pin の commit が取得されるため、**動作検証済みのバージョンと完全に一致**する。

---

## 3. 初回構築手順

### 3-1. clone と submodule + パッチの bootstrap（最重要）

```bash
# 推奨: clone と同時に submodule も取る
git clone --recurse-submodules <this-repo-url> hermes-docker
cd hermes-docker

# 既に --recurse-submodules 抜きで clone してしまった場合
# (hermes-webui/, hermes-hudui/ が空になっているはず)
git submodule update --init --recursive

# ★ submodule を持ってきただけでは webui のローカルパッチが当たっていない。
#    bootstrap.sh で patches/ 配下の .patch を submodule に適用する。
#    べき等なので何度走らせても安全。
./scripts/bootstrap.sh
```

`bootstrap.sh` の出力例（fresh clone 後）:

```
== bootstrap @ /path/to/hermes-docker ==
[1/2] git submodule update --init --recursive
[2/2] apply local patches
  [ok]   applied:        /.../patches/hermes-webui/0001-xai-oauth-default-injection.patch
== bootstrap complete ==
```

2 回目以降は `[skip] already applied` になる。**忘れたまま `docker compose build`
すると xai-oauth のパッチが当たっていない素の upstream で焼かれ、モデルピッカーが
壊れる**（[TROUBLESHOOTING §4](./TROUBLESHOOTING-webui-agent.md#4-根本原因-xai-oauth-のモデル一覧が空grok-43-が表示されない) 直結）。詳細は §6 参照。

> `git status` で `hermes-webui` が `Am`（staged-as-add + modified content）と
> 表示されるのは **正常**。bootstrap.sh がワーキングツリーにパッチを当てた状態。
> 親リポジトリは clean な submodule commit を pin している（このローカル汚れは
> 親の commit には含めない）。

### 3-2. ホスト準備

```bash
# UID/GID を確認
id -u   # → HOST_UID
id -g   # → HOST_GID

# ~/.hermes と ~/workspace を確認（存在しなければ作る）
ls -ld ~/.hermes ~/workspace
mkdir ~/.hermes
mkdir ~/workspace
```

### 3-3. シークレットを配置

```bash
# 1) compose 用の .env を作る（既に存在するなら値だけ書き換え）
cat > ./.env <<EOF
SEARXNG_SECRET_KEY=$(openssl rand -hex 32)
HOST_UID=$(id -u)
HOST_GID=$(id -g)
EOF

# 2) webui プロセス用の .env を編集（パスワードを必ず変える）
$EDITOR ./hermes-webui/.env
#   - HERMES_WEBUI_PASSWORD=CHANGE_ME_STRONG_PASSWORD を強い値に
#   - 127.0.0.1 だけに bind するなら無くても動くが、推奨は設定する

# 3) ~/.hermes/.env に LLM / web ツール系の鍵を集約
#    （既に hermes-cli を使っていれば既存のものをそのまま使う）
$EDITOR ~/.hermes/.env
#   例:
#     API_SERVER_KEY=...
#     ANTHROPIC_API_KEY=sk-ant-...
#     OPENROUTER_API_KEY=...
#     FIRECRAWL_API_KEY=fc-...       # web.extract_backend: firecrawl を使うなら必須
chmod 0600 ~/.hermes/.env
```

> macOS だと `id -u` は通常 501、Linux だと 1000。
> `HOST_UID/GID` をホストに合わせない場合は `~/.hermes` の bind mount で
> permission denied が起こり得るので必ず確認する。

### 3-4. image を取得 / build

```bash
docker compose pull         # nousresearch/hermes-agent:main と searxng を取得
docker compose build        # hermes-webui / hermes-hudui を local build
```

### 3-5. 起動

```bash
docker compose up -d
```

`depends_on.condition: service_healthy` チェーンにより、`searxng` ⇒ `hermes-agent` ⇒
`hermes-webui` の順に **「前段が healthy になるまで次が起動を試行しない」** 形で立ち上がる。
`hermes-hudui` はチェーンに入っておらず単独で起動する。

期待される進行:

```
 Network hermes-docker_hermes-net Created
 Volume  hermes-docker_hermes-agent-src Created
 Container searxng       Created → Starting → Healthy
 Container hermes-hudui  Created → Starting → Started
 Container hermes-agent  Waiting → Starting → Started → Healthy
 Container hermes-webui  Waiting → Starting → Started
```

webui の healthcheck（`curl http://localhost:8787/health`）が緑になるまで通常 10～30 秒。

---

## 4. 健全性確認

`docker ps` で全コンテナが `(healthy)` になっていることが基本だが、ログまで含めて確認する。

### 4-1. コンテナ状態

```bash
docker ps --filter "name=hermes" --filter "name=searxng" \
  --format "table {{.Names}}\t{{.Status}}"
```

期待値:

```
NAMES          STATUS
hermes-webui   Up Xs (healthy)
hermes-agent   Up Xs (healthy)
hermes-hudui   Up Xs                    # healthcheck 未定義なので healthy 表示は出ない
searxng        Up Xs (healthy)
```

### 4-2. hermes-agent の init ログにエラーが無いこと

```bash
docker logs hermes-agent --tail 30
```

良いログのキーワード:

- `cont-init: info: /etc/cont-init.d/01-hermes-setup exited 0`
- `s6-rc: info: service main-hermes successfully started`
- `Hermes Gateway Starting...`

**悪いログの兆候**（出ていたらすぐ [TROUBLESHOOTING §9](./TROUBLESHOOTING-webui-agent.md#9-根本原因-hermes-agent-src-ボリュームの陳腐化restarting-127-ループ) へ）:

- `exec: /opt/hermes/docker/stage2-hook.sh: not found`
- `cont-init: ... exited 127`
- `No module named hermes_cli.container_boot`

### 4-3. gateway プロセスが上がっていること

```bash
docker exec hermes-agent pgrep -af "hermes gateway"
# →  154 /opt/hermes/.venv/bin/python3 /opt/hermes/.venv/bin/hermes gateway run
```

### 4-4. WebUI

```bash
curl -sS http://127.0.0.1:8787/health
# → {"status":"ok","sessions":0,...}
```

ブラウザで `http://127.0.0.1:8787/` を開き、`hermes-webui/.env` の
`HERMES_WEBUI_PASSWORD` でログイン。チャット送信＋モデルピッカーで利用するモデルが
出ることを確認する。

`/api/models` を curl で叩いて 401 や `Authentication required` が返るのは正常
（認証必須エンドポイントのため）。**「モデルが UI に出ない」場合のトリアージは
[TROUBLESHOOTING §4](./TROUBLESHOOTING-webui-agent.md#4-根本原因-xai-oauth-のモデル一覧が空grok-43-が表示されない) を参照**。

### 4-5. HUD UI

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3001/api/state
# → 200
```

ブラウザで `http://127.0.0.1:3001/` を開けば 17 タブの HUD が出る。
（hudui は無認証なので 127.0.0.1 以外には絶対に晒さないこと）

### 4-6. SearXNG

```bash
curl -sS http://127.0.0.1:8080/healthz
# → OK
```

---

## 5. コンテナ内 `hermes` CLI による初期セットアップ

`docker compose up` で container は立ち上がるが、API キーや OAuth ログイン、
モデル選択、gateway の messaging プラットフォーム設定などは
**コンテナの中の `hermes` CLI から行う**。ホストに hermes-cli を入れる必要はない。

### 5-0. 大原則（最初に必ず読む）

1. **必ず `-u hermes` を付ける**。
   `docker exec hermes-agent ...` だけだとデフォルトの **root** で実行されてしまい、
   `~/.hermes/auth.json` などが root 所有で書き込まれてホストの `id -u` ユーザから
   触れなくなる。bind mount なので一度起きると面倒。
2. **対話コマンドには `-it` を付ける**（`hermes setup` / `hermes login` / `hermes model` 等）。
3. **CLI 実体のパスは `/opt/hermes/.venv/bin/hermes`**。`/opt/hermes` は named volume
   `hermes-agent-src` 経由なので `docker compose pull` 後に staleness 障害が起きると
   このパスごと消えることがある（[TROUBLESHOOTING §9](./TROUBLESHOOTING-webui-agent.md#9-根本原因-hermes-agent-src-ボリュームの陳腐化restarting-127-ループ)）。
4. **設定は `~/.hermes/` 配下に書かれ、bind mount でホストに即反映される**。
   gateway / webui の双方に影響が及ぶ（両者が `~/.hermes/config.yaml` と `.env` を共有）。

エイリアスにしておくと楽:

```bash
alias hermes-docker='docker exec -it -u hermes hermes-agent /opt/hermes/.venv/bin/hermes'
hermes-docker status
hermes-docker doctor
```

以降このセクション内では **`hermes-docker` = 上記エイリアス** として表記する。

### 5-1. まず現状を診断する

```bash
hermes-docker status     # 何が見えていて何が無いか（API キー、Auth、Provider）
hermes-docker doctor     # 構成検査。⚠ で出た項目に対応していけばよい
```

参考: 直後の `doctor` 典型出力（API キー未設定の素状態）。

```
◆ Configuration Files
  ✓ /home/hermes/.hermes/.env file exists
  ⚠ No API key found in /home/hermes/.hermes/.env
  ✓ /home/hermes/.hermes/config.yaml exists
  ⚠ Config version outdated (v23 → v25) (new settings available)

◆ Auth Providers
  ⚠ Nous Portal auth (not logged in)
  ⚠ OpenAI Codex auth (not logged in)
  ⚠ Google Gemini OAuth (not logged in)
  ⚠ xAI OAuth (not logged in)
```

> ⚠ コンテナ内の `/home/hermes/.hermes/` は **ホストの `~/.hermes/` と同じディレクトリ**
> （bind mount）。コンテナ内パスでメッセージが出ても、編集はホスト側のエディタで
> 行ってよい。

### 5-2. 設定ファイルの場所を確認

```bash
hermes-docker config path        # → /home/hermes/.hermes/config.yaml
hermes-docker config env-path    # → /home/hermes/.hermes/.env
hermes-docker config show        # 現在の設定をダンプ
hermes-docker config migrate     # スキーマ更新（doctor が v23→v25 を指摘した場合）
```

### 5-3. クレデンシャルの 2 系統と使い分け

hermes 0.15 系では LLM プロバイダの認証情報を保持する場所が **2 系統**あり、
両者は独立して併用できる:

| 系統 | 保存先 | 追加方法 | 主な用途 |
|---|---|---|---|
| **環境変数** | `~/.hermes/.env`（host bind） | エディタで直接書く | 古典的な API キー（`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `FIRECRAWL_API_KEY` 等）、tool 系の秘密も含む |
| **Pooled Credentials** | `~/.hermes/auth.json`（host bind） | `hermes auth add <provider> ...` | OAuth（Nous/xAI/Codex 等）、複数キーのプール／ローテーション、ラベル管理が要るもの |

`hermes-docker status` の `◆ API Keys` セクションは **環境変数系統**、
`◆ Auth Providers` セクションは **pooled 系統** を別々に表示する。
LLM プロバイダによっては両方サポートしていて、どちらでも動く。

> ⚠ **ツール系の秘密** (`SEARXNG_URL`, `FIRECRAWL_API_KEY`, `EXA_API_KEY` 等) は
> 環境変数系統一択。compose の `environment:` や `./hermes-webui/.env` に書くと
> webui エージェントから見えず壊れる（[TROUBLESHOOTING §3](./TROUBLESHOOTING-webui-agent.md#3-根本原因-環境変数の-split-brain検索が接続できない)）。

### 5-4. パターン A: 環境変数（`~/.hermes/.env`）に API キーを書く（最短）

ホスト側のエディタで直接編集する一番単純な経路:

```bash
$EDITOR ~/.hermes/.env

# 例:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENROUTER_API_KEY=...
# OPENAI_API_KEY=sk-...
# FIRECRAWL_API_KEY=fc-...

chmod 0600 ~/.hermes/.env
docker compose restart hermes-agent hermes-webui
hermes-docker status        # ◆ API Keys セクションに ✓ が並ぶこと
```

### 5-5. パターン B: `hermes auth add` で pooled credentials に登録

OAuth はこの経路でしか入れられない。API キーもこの経路を選ぶ価値があるのは
「同じ provider の鍵を複数プールして自動ローテーションさせたい」「ラベルを付けて
管理したい」場合。

> 旧版にあった `hermes login` コマンドは **廃止**。エラーメッセージで
> `"The 'hermes login' command has been removed. Use 'hermes auth' to manage credentials..."`
> と案内されたら本節の経路に切り替える。

#### 5-5-1. OAuth プロバイダ（Nous Portal / xAI Grok / Codex 等）

コンテナ内には GUI ブラウザが無いので、ホストのブラウザで認可ページを開く必要がある。
OAuth フローには 2 つの方式があり、**Docker 構成では `--manual-paste` 一択**:

| flag | 仕組み | Docker での可否 |
|---|---|---|
| `--no-browser` | CLI が **コンテナ内の `127.0.0.1:<random>`** に callback リスナーを立て、ホストブラウザのリダイレクトを受ける | ✗ **動かない**。ホストブラウザの `127.0.0.1` はあなたの Mac/Linux 側を指すので、コンテナ内リスナーには絶対に到達しない（毎回ランダム port なので docker-compose にも書けない） |
| `--manual-paste` | callback リスナーを立てず、ブラウザが「接続できません」になった後の URL をユーザがコピペで CLI に渡す | ✓ **これを使う**。コンテナ ⇄ ホスト間のネット経路を一切要求しない |

##### `--manual-paste` の正しい手順

```bash
hermes-docker auth add xai-oauth --type oauth --manual-paste
# 例: 他に nous, openai-codex 等も同じ形
```

CLI が次のような認可 URL を表示する:

```
Open this URL to authorize Hermes with xAI:
https://auth.x.ai/oauth2/authorize?response_type=code&client_id=...&redirect_uri=http%3A%2F%2F127.0.0.1%3A56121%2Fcallback&...
```

1. **ホスト側のブラウザで URL を開く** → プロバイダのページで「Authorize」をクリック。
2. ブラウザは `http://127.0.0.1:56121/callback?code=...&state=...` にリダイレクトしようとして
   **`ERR_CONNECTION_REFUSED` / 「このページが表示できません」になる**。← これで正常。
3. **ブラウザのアドレスバーに残った URL を丸ごとコピー**
   （`http://127.0.0.1:.../callback?code=...&state=...` の全部）。
4. CLI が `Paste callback URL:` 等で待っているターミナルに **ペーストして Enter**。
5. CLI が `code` を xAI/Portal と直接交換して `~/.hermes/auth.json` に保存。

> もし `--no-browser` で起動してしまって `Waiting for callback on http://127.0.0.1:.../callback`
> から進まなくなったら、ハマっているサインなので **Ctrl+C で中断**し、上記の
> `--manual-paste` で取り直す。

##### 別解: ホストの `hermes-cli` で取って共有する

ホストに hermes-cli が入っているか、これから入れてもよいなら:

```bash
hermes auth add xai-oauth --type oauth     # ホスト側なら loopback 経路がそのまま通る
```

`~/.hermes/auth.json` は bind mount でコンテナと共有されているので、書き込まれた瞬間に
コンテナから見える（gateway は次回起動から拾う。確実に効かせるなら
`docker compose restart hermes-agent hermes-webui`）。

Nous Portal をワンショットで設定（OAuth + provider 切替 + Tool Gateway opt-in までまとめて）:

```bash
hermes-docker setup --portal
```

#### 5-5-2. API キー型を pooled で持つ

```bash
# プロンプトで安全に入力
hermes-docker auth add anthropic --type api-key --label "personal-key"

# 非対話モード（CI 等。--api-key で直接渡す。シェル履歴に残るので注意）
hermes-docker auth add anthropic --type api-key --label "personal-key" --api-key "sk-ant-..."
```

#### 5-5-3. 確認・削除

```bash
hermes-docker auth list                  # 全プロバイダ
hermes-docker auth list anthropic        # 特定プロバイダだけ
hermes-docker auth status anthropic      # 当該 provider の認証状態詳細
hermes-docker auth remove <id>           # id は list で確認
hermes-docker auth logout <provider>     # provider 単位で全クレデンシャル削除
hermes-docker auth reset <provider>      # exhaustion 状態（quota 切れ等）をクリア

hermes-docker status                     # ◆ Auth Providers セクションが ✓ になる
```

### 5-6. デフォルトモデルを選ぶ

```bash
hermes-docker model            # 対話的にプロバイダ → モデルを選択
hermes-docker model --refresh  # 各プロバイダの /v1/models キャッシュを破棄して再取得
```

選択結果は `~/.hermes/config.yaml` の `model:` セクションに書かれ、
**gateway / webui どちらにも反映される**（再起動推奨）。

### 5-7. 対話ウィザード（フル）

```bash
hermes-docker setup            # フルウィザード（既存設定は現値が default として表示される）
hermes-docker setup --quick    # 未設定の項目だけ訊く（差分セットアップ向け）

# セクション単位
hermes-docker setup model      # モデルだけ
hermes-docker setup tts        # TTS（読み上げ）だけ
hermes-docker setup terminal   # ターミナル装飾だけ
hermes-docker setup gateway    # messaging gateway だけ
hermes-docker setup tools      # toolset on/off だけ
hermes-docker setup agent      # agent 系パラメータだけ
```

`setup --reset` で `config.yaml` を default に戻す（破壊的操作。`docker compose down` の前に
`~/.hermes/` をバックアップする運用が無難）。

### 5-8. Messaging Gateway を有効化する（Telegram / Discord / Slack 等）

`hermes-agent` コンテナの `command: gateway run` は **messaging プラットフォームの
受信ループ**。Telegram / Discord / Slack / WhatsApp などを使うときに意味を持つ。

```bash
# 対話 wizard で platform ごとの token を入れる（~/.hermes/config.yaml に保存）
hermes-docker setup gateway

# 状態確認
hermes-docker gateway status
hermes-docker gateway list

# 設定を変えたら gateway を再起動（s6 supervised なので compose restart で確実）
docker compose restart hermes-agent
```

> `hermes gateway list` が `not running` と表示されることがあるが、
> これは pid ファイル経由の判定で、**s6 supervised 下では別系統**になる。
> `hermes-docker doctor` の `◆ s6 Supervision` セクションが
> `✓ Per-profile gateways: 1/1 supervised up` であれば実際は走っている。
> 加えてホスト側で `docker exec hermes-agent pgrep -af "hermes gateway"` を打てば PID が出る。

User allowlist（**重要・現状未設定だと全 platform 拒否**）:

```bash
# ~/.hermes/.env に以下のいずれかを追加
# GATEWAY_ALLOW_ALL_USERS=true                 # 開放（テスト用）
# TELEGRAM_ALLOWED_USERS=<numeric_user_id>     # Telegram の場合
# DISCORD_ALLOWED_USERS=<discord_user_id>      # Discord の場合
docker compose restart hermes-agent
```

これを入れないと初回起動ログに次の warning が出る:

```
WARNING gateway.run: No user allowlists configured. All unauthorized users will be denied.
```

### 5-9. 起動時 dashboard を有効化したい場合

`hermes-agent` 内には s6 supervised の dashboard service が**待機**で入っている。
有効化するには compose の environment に追加:

```yaml
# docker-compose.yml の hermes-agent: environment:
- HERMES_DASHBOARD=1
```

`docker compose up -d hermes-agent` で再起動すると s6 が dashboard プロセスを起動し、
コンテナ内 port 9119 で立ち上がる（host への port mapping は別途追加が必要）。

### 5-10. 設定変更を反映させるためのリスタート早見表

| 変えた場所 | 再起動するもの |
|---|---|
| `~/.hermes/.env`（API キー追加など） | `docker compose restart hermes-agent hermes-webui` |
| `~/.hermes/config.yaml`（モデル/ツール変更など） | 同上 |
| `~/.hermes/config.yaml` の gateway/messaging 設定 | `docker compose restart hermes-agent` |
| `./hermes-webui/api/*.py`（ローカルパッチ） | `docker compose build hermes-webui && docker compose up -d hermes-webui`（§6 参照） |
| `docker-compose.yml` 自体 | `docker compose up -d`（差分検知して該当コンテナだけ作り直す） |

### 5-11. よく使う運用コマンド

```bash
# セッション履歴
hermes-docker sessions list
hermes-docker sessions export <id>

# 古い checkpoint を掃除
hermes-docker checkpoints --help

# バックアップ（~/.hermes/ の zip）
hermes-docker backup -o /home/hermes/.hermes/backup-$(date +%Y%m%d).zip
# → ホスト側では ~/.hermes/backup-*.zip として残る

# クレデンシャル管理
hermes-docker auth list
hermes-docker auth remove <id>
hermes-docker auth status <provider>

# ログ確認
hermes-docker logs --help
docker compose logs -f hermes-agent     # コンテナ stdout 経由でも見える
```

### 5-12. 落とし穴

- **`docker exec hermes-agent hermes ...` は動かない**。PATH に hermes が無いので
  `/opt/hermes/.venv/bin/hermes` をフルパスで指定する必要がある。
- **`-u hermes` を忘れて root で `setup` を実行**→ `~/.hermes/auth.json` 等が
  root:root で作られ、ホストユーザから読めなくなる。直すには
  `sudo chown -R $(id -u):$(id -g) ~/.hermes` （バックアップ後に）。
- **`docker compose pull` 後に `hermes` コマンドが not found** → named volume の
  staleness。[TROUBLESHOOTING §9](./TROUBLESHOOTING-webui-agent.md#9-根本原因-hermes-agent-src-ボリュームの陳腐化restarting-127-ループ) の手順で復旧。
- **webui コンテナ内でも `hermes` CLI が使える**（`docker exec -it -u hermeswebui
  hermes-webui /home/hermeswebui/.hermes/hermes-agent/.venv/bin/hermes ...`）が、
  通常は `hermes-agent` 側で行うこと。webui 側はチャット UI 用の最小構成しか想定していない。

---

## 6. 既知のローカルパッチ（webui xai-oauth）

`hermes-webui` submodule の `api/config.py` の `get_available_models()` に
**upstream に未反映のバグ修正**を当てている:

```python
# patches/hermes-webui/0001-xai-oauth-default-injection.patch
- if not injected and groups:
+ if not injected:
```

`xai-oauth` 等の OAuth/portal プロバイダで `groups` が空のまま返ると、
**デフォルトモデルすら注入されず**フロントの early return でモデル選択が空になる、
という上流バグへの対処（[TROUBLESHOOTING §4](./TROUBLESHOOTING-webui-agent.md#4-根本原因-xai-oauth-のモデル一覧が空grok-43-が表示されない) で発生時の症状確認可能）。

### 6-1. パッチ運用フロー

`hermes-webui/` 自体は **upstream を素のままで pin した git submodule**。パッチは
`patches/hermes-webui/*.patch` に独立ファイルとして置かれており、
**`scripts/bootstrap.sh` が submodule の working tree に動的に当てる**。

```
scripts/bootstrap.sh
  ├─ git submodule update --init --recursive          ← upstream を pinned commit で取得
  └─ for each patches/hermes-webui/*.patch:
       ├─ already applied? → skip
       ├─ applies cleanly? → git apply
       └─ conflict?        → fail (= upstream が変わって patch がズレた)
```

`bootstrap.sh` 内では `git apply --check --reverse` でべき等性を判定しているため、
何度走らせても安全。

### 6-2. パッチを当てる典型シナリオ

| 状況 | やること |
|---|---|
| 初回 clone 直後 | `./scripts/bootstrap.sh`（§3-1） |
| submodule の HEAD を変えた（`git submodule update --remote` 等） | `./scripts/bootstrap.sh`（再適用） |
| パッチを修正した／追加した | パッチを `patches/<submodule>/` に置き、`./scripts/bootstrap.sh` |
| `bootstrap.sh` が **`[FAIL] cannot apply`** で止まった | upstream のドリフト。`cd hermes-webui && git apply --check ../patches/...` で詳細確認、パッチを upstream の現行に合わせて手で更新 |

### 6-3. 親リポジトリでの submodule の見え方

`bootstrap.sh` がパッチを working tree に当てると、親 `git status` で
`hermes-webui` が **`Am` (staged-as-add + modified content)** と表示される。
**これは想定通りの状態**であり、コミットしない（コミットすると pin が動的に
ズレてしまい、パッチが二重適用される）。

CI などで「submodule が dirty」を厳密チェックしたい場合は、bootstrap.sh が
当てる方の差分を白リスト化する必要がある。

### 6-4. パッチを増やしたいとき

```bash
# 1) submodule の working tree で編集
$EDITOR hermes-webui/api/somefile.py

# 2) git diff から .patch を作る
cd hermes-webui
git diff > ../patches/hermes-webui/0002-short-description.patch
cd ..

# 3) submodule の working tree をクリーンに戻す
git -C hermes-webui checkout -- .

# 4) bootstrap.sh が新しいパッチも拾うことを確認
./scripts/bootstrap.sh
```

ファイル名先頭の `NNNN-` で適用順を制御できる（`find ... | sort` 順）。

---

## 7. 日常運用コマンド

| やりたいこと | コマンド |
|---|---|
| ログを追う | `docker compose logs -f hermes-agent` |
| 全部止める | `docker compose stop` |
| 全部上げる | `docker compose up -d` |
| 全部消す（image と volume は残る） | `docker compose down` |
| **named volume も消す**（image 更新後の staleness 復旧） | `docker compose down && docker volume rm hermes-docker_hermes-agent-src && docker compose up -d` |
| webui のコード変更を反映 | `docker compose build hermes-webui && rm -f ~/.hermes/webui/models_cache.json && docker compose up -d hermes-webui` |
| HUD UI のコード変更を反映 | `docker compose build hermes-hudui && docker compose up -d hermes-hudui` |
| hermes-agent image だけ更新 | `docker compose pull hermes-agent` → **ログを確認** → 問題あれば named volume を消して再起動 |
| submodule を upstream の最新に更新する | `git submodule update --remote hermes-webui && ./scripts/bootstrap.sh` （パッチが当たらなくなったら §6-2 参照）|
| submodule を pin の commit まで戻す | `git submodule update --init --recursive && ./scripts/bootstrap.sh` |

### upstream image 更新時の落とし穴（必ず確認）

```bash
docker compose pull hermes-agent
docker compose up -d hermes-agent
docker logs hermes-agent --tail 50    # ← exit 127 / not found / No module が出ていないか
```

出ていたら named volume の staleness（[TROUBLESHOOTING §9](./TROUBLESHOOTING-webui-agent.md#9-根本原因-hermes-agent-src-ボリュームの陳腐化restarting-127-ループ)）。
復旧は次:

```bash
docker compose stop hermes-agent hermes-webui
docker compose rm -f hermes-agent hermes-webui
docker volume rm hermes-docker_hermes-agent-src
docker compose up -d hermes-agent hermes-webui
```

`~/.hermes/` はバインドマウントなので消えない。

---

## 8. アンインストール

```bash
docker compose down
docker volume rm hermes-docker_hermes-agent-src
docker rmi nousresearch/hermes-agent:main \
           hermes-docker-hermes-webui \
           hermes-docker-hermes-hudui \
           searxng/searxng:latest
# ~/.hermes と ~/workspace は触らない（ユーザデータ）
# 完全に消すなら手動で rm -rf ~/.hermes ~/workspace（取り返しがつかないので注意）
```

---

## 9. このスタックの「設計上わかっておくと事故が減る」点

[TROUBLESHOOTING §10](./TROUBLESHOOTING-webui-agent.md#10-docker-composeyml-の既知の設計上の弱点) に詳しいが要点だけ:

1. **hermes-webui は gateway へブリッジしているわけではなく、コンテナ内で別の Hermes エージェントを起動する**。
   → 設定が見える範囲が gateway と非対称。`~/.hermes/` だけが両者の共通グラウンド。
2. **`/opt/hermes` を named volume で共有しているため、`docker compose pull` 単独では中身が更新されない**。
   → upstream image 更新時は必ずログを確認、staleness が出たら named volume を rm。
3. **ツール系の秘密は `~/.hermes/.env` のみ**。compose `environment:` や `./hermes-webui/.env` に書くと webui エージェントから見えず壊れる。
4. **`HOST_UID/HOST_GID` はホストに必ず合わせる**。bash の built-in `$UID`/`$GID` には依存しない（過去に暗黙の不整合があった経緯）。
5. **hermes-hudui は root で `~/.hermes` を触る**。他コンテナの非 root ユーザが書いたファイルを root が触れる方向には問題ないが、逆方向（hudui が書いたファイルを agent/webui が読む）でハマる可能性がある。今のところ未顕在。
