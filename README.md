<h1 align="center">hermes-docker</h1>

<p align="center">
  <b>Hermes Agent をローカルで「動く 1 セット」として立ち上げる private docker stack</b>
</p>

<p align="center">
  <img alt="Docker"   src="https://img.shields.io/badge/docker-compose%20v2-2496ED?logo=docker&logoColor=white">
  <img alt="BuildKit" src="https://img.shields.io/badge/buildkit-enabled-success">
  <img alt="OS"       src="https://img.shields.io/badge/macOS%20%7C%20Linux%20%7C%20WSL2-supported-informational">
  <img alt="Hermes"   src="https://img.shields.io/badge/hermes--agent-main-purple">
  <img alt="Status"   src="https://img.shields.io/badge/status-internal--use-lightgrey">
</p>

<p align="center">
  <a href="docs/setup.md"><b>📘 Setup ガイド</b></a> ·
  <a href="docs/TROUBLESHOOTING.md"><b>🩺 Troubleshooting</b></a> ·
  <a href="#-quick-start"><b>🚀 Quick start</b></a>
</p>

---

`nousresearch/hermes-agent` を中心に **gateway / WebUI / HUD / SearXNG** の
4 コンテナを `docker compose` 一発で起動する、自分のホストで完結する Hermes 環境です。
すべての状態は `~/.hermes/` の bind mount に集約され、コンテナを作り直しても消えません。

## 📦 What's inside

| Service          | Image / Build                            | Port (`127.0.0.1`) | 役割                                                 |
| ---------------- | ---------------------------------------- | -----------------: | ---------------------------------------------------- |
| **hermes-agent** | `nousresearch/hermes-agent:main`         |       `8642` *(unused)* | `hermes gateway run` — messaging + cron。s6 が supervise |
| **hermes-webui** | local build (`./hermes-webui/`)          |             `8787` | チャット UI。**コンテナ内で独立した Hermes Agent も動く** |
| **hermes-hudui** | local build (`./dockerfiles/hudui.…`)    |             `3001` | `~/.hermes/` を可視化する 17 タブの React HUD          |
| **searxng**      | `searxng/searxng:latest`                 |             `8080` | Private 検索バックエンド                              |

## 🗺 アーキテクチャ

ホストの `~/.hermes/` が 3 コンテナすべての **状態の単一ソース**。コンテナ内のパスは
ホスト上には存在しません（bind mount で繋いだ範囲だけがホストと共有されます）。

```
══════ HOST ════════════════════════════════════════════════
  ~/.hermes/      ★ Hermes の "状態" の真実 (config / sessions / skills …)
  ~/workspace/    webui の file browser がここを覗く
  ./hermes-docker/   ← このリポジトリ (compose / submodules / patches / scripts)
  /var/lib/docker/volumes/hermes-docker_hermes-agent-src/   ⚠ ホストから直接見えない

══════ CONTAINERS (docker compose 起動中だけ存在) ═════════════
  hermes-agent   /home/hermes/.hermes  ←── bind ── ~/.hermes
                 /opt/hermes           ←── named volume (hermes-agent ソース共有)
  hermes-webui   /home/hermeswebui/.hermes ← bind ── ~/.hermes  (同じ実体)
                 /workspace            ←── bind ── ~/workspace
  hermes-hudui   /root/.hermes         ←── bind ── ~/.hermes  (root で操作 ⚠)
  searxng        /etc/searxng          ←── bind ── ./searxng
```

詳細図と「ホストと同じ実体になっている場所」早見表は
👉 [docs/setup.md §2](docs/setup.md#2-ファイル構成) と
[docs/setup.md §1-1](docs/setup.md#1-1-プラットフォーム別の差macos--linux--wsl2)。

## 🚀 Quick start

> 動作確認済み: macOS / Linux / Windows WSL2 (Docker 23+ / BuildKit)。
> macOS 以外は `HOST_UID` / `HOST_GID` を必ず自分のホストに合わせること
> （[詳細](docs/setup.md#1-1-プラットフォーム別の差macos--linux--wsl2)）。

```bash
# 1) clone (submodule 込みで取得)
git clone --recurse-submodules <this-repo-url> hermes-docker
cd hermes-docker

# 2) submodule + ローカルパッチを bootstrap (idempotent)
./scripts/bootstrap.sh

# 3) compose 用 .env を生成 (HOST_UID/GID と searxng シークレット)
cat > .env <<EOF
SEARXNG_SECRET_KEY=$(openssl rand -hex 32)
HOST_UID=$(id -u)
HOST_GID=$(id -g)
EOF

# 4) webui プロセス用パスワードを変える (推奨)
$EDITOR ./hermes-webui/.env       # HERMES_WEBUI_PASSWORD=...

# 5) LLM API キーを集約 (両エージェントが共通で読む単一ソース)
$EDITOR ~/.hermes/.env            # ANTHROPIC_API_KEY=... など
chmod 0600 ~/.hermes/.env

# 6) 起動
docker compose pull && docker compose build && docker compose up -d
```

→ ブラウザで <http://127.0.0.1:8787> (WebUI) と <http://127.0.0.1:3001> (HUD) を開く。

健全性チェック手順、ハマりどころ、`hermes` CLI 経由の OAuth ログインなどは
👉 [**docs/setup.md**](docs/setup.md)。

## 🛠 Tech stack

- [`nousresearch/hermes-agent`](https://github.com/NousResearch/hermes-agent) (gateway, s6-supervised)
- [`nesquena/hermes-webui`](https://github.com/nesquena/hermes-webui) (git submodule)
- [`joeynyc/hermes-hudui`](https://github.com/joeynyc/hermes-hudui) (git submodule)
- [`searxng/searxng`](https://github.com/searxng/searxng)
- Docker Compose v2 + BuildKit
- ローカルパッチ管理: `patches/` + `scripts/bootstrap.sh`（idempotent）

## ⚠ Caveats (一読推奨)

このスタックは「素直に立てるとハマる」点がいくつかあります:

- **WebUI は gateway へブリッジしていない** — webui コンテナ内で独立した Hermes Agent が走る。
  共通グラウンドは `~/.hermes/` だけ。
- **`docker compose pull` 単独では `/opt/hermes` が更新されない** — named volume の
  staleness で `Restarting (127)` ループに入る。
- **ツール系の秘密は `~/.hermes/.env` のみ** — `./hermes-webui/.env` や compose
  `environment:` に書くと webui エージェントから見えず壊れる。
- **OAuth は `--manual-paste` 一択** — `--no-browser` のループバック callback が
  コンテナ内 127.0.0.1 になりホストから届かない。

調査記録と復旧手順は 👉 [**docs/TROUBLESHOOTING.md**](docs/TROUBLESHOOTING.md)。

## 📚 Documentation

| Doc | 内容 |
|---|---|
| [docs/setup.md](docs/setup.md) | 前提・初回構築・健全性・hermes CLI セットアップ・運用・既知のローカルパッチ・アンインストール |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 過去発生した不具合の根本原因・対処・compose 設計上の弱点 |

## 📝 License

このリポジトリ自体のグルーコード（compose / scripts / patches）は内部利用想定。
submodule 配下の hermes-webui / hermes-hudui、および取り込んでいる image はそれぞれ
upstream のライセンスに従う。
