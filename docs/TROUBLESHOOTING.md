# hermes-agent と hermes-webui の連携不具合 — 原因と対処まとめ

作成日: 2026-05-23
最終更新: 2026-06-02（§9 staleness, §10 compose 設計弱点, §11 適用修正を追記）

## 1. 概要

`nousresearch/hermes-agent:main`（gateway）と `hermes-docker-hermes-webui` が
「うまく連携できていない」状態だった。具体的な症状は次の2つ：

1. **WebUI 側でモデル（xai-oauth / grok-4.3）が選択肢に表示されない**
2. **WebUI のチャットで検索しようとすると「接続できない」エラーが出る**

調査の結果、これらは**独立した2つの根本原因**によるものだった。どちらも
「WebUI が gateway とは別に、自前のエージェントをコンテナ内で動かしている」
という構成特有の落とし穴に起因する。

---

## 2. 前提アーキテクチャ（重要）

この docker-compose 構成では **エージェントが2つ** 動いている：

| コンテナ | 役割 | 設定の読み取り元 |
|---|---|---|
| `hermes-agent` | `gateway run`（メッセージング＋cron） | `~/.hermes/config.yaml` + `~/.hermes/.env` + **自身の** compose `environment:` |
| `hermes-webui` | チャットUI。**UI用のエージェントをコンテナ内で別途実行** | `~/.hermes/config.yaml` + `~/.hermes/.env` + **自身の** compose `environment:` |

- WebUI のチャットは gateway に橋渡ししているのではなく、**WebUI コンテナ内で
  独立した Hermes エージェントを動かしている**（エージェントのソースは
  `hermes-agent-src` named volume 経由で共有）。
- したがって **WebUI 側のエージェントは `hermes-agent` コンテナの
  `environment:` を一切見ない**。共有されるのは `~/.hermes`（config.yaml と .env）だけ。

この「設定が見える範囲の非対称」が両不具合の土台になっている。

---

## 3. 根本原因 ①：環境変数の split-brain（検索が「接続できない」）

### 事象
WebUI チャットで検索→ページ取得しようとすると失敗する。一方 gateway 側は正常。

### 原因
Web ツールの設定が**2か所に分散**しており、片方しか共有されていなかった。

| 変数 | `~/.hermes/.env`（両方が読む） | `hermes-agent` compose env | WebUI エージェントから見えるか |
|---|---|---|---|
| `SEARXNG_URL` | ✅ あり (`http://searxng:8080`) | ✅ あり | ✅ 見える → 検索は動く |
| `FIRECRAWL_API_KEY` | ❌ **無い** | ✅ あり（compose のみ） | ❌ **MISSING** |

`config.yaml` の設定は以下のとおり：
```yaml
web:
  search_backend: searxng     # 検索 → searxng
  extract_backend: firecrawl  # 本文抽出 → firecrawl
```

WebUI エージェントは `FIRECRAWL_API_KEY` を持たないため、`web_extract`
（ページ本文の取得）で firecrawl が使えず searxng にフォールバック。
searxng は**検索専用**なので次のエラーになる：

> SearXNG is a search-only backend and cannot extract URL content.
> Set web.extract_backend to firecrawl, tavily, exa, or parallel.

= grok が「検索 → ページを読む」の読む段階で失敗 → ユーザー視点で「接続できない」。

### 補足（誤りやすい点）
- このバージョン（hermes-agent 0.14.0）に **grok ネイティブ検索（xAI Live Search）の
  統合は無い**。Web 検索バックエンドは searxng / firecrawl / exa / tavily / parallel のみ。
- よって「grok 使用時は `SEARXNG_URL` を外す」は逆効果。外すと検索が firecrawl に
  フォールバックするが、WebUI にはそのキーも無いため検索ごと壊れる。
- ネットワークは正常だった（WebUI コンテナから `http://searxng:8080/healthz` は HTTP 200）。
  問題は到達性ではなく**キーの有無**。

---

## 4. 根本原因 ②：xai-oauth のモデル一覧が空（grok-4.3 が表示されない）

### 事象
WebUI のモデルセレクタに grok-4.3（および他の grok）が出ない。
ただし `active_provider=xai-oauth` / `default_model=grok-4.3` 自体は検出済み。

### 原因（上流コードのバグ）
`hermes-webui/api/config.py` の `get_available_models()` で：

1. `_PROVIDER_MODELS` の xAI 用キーは **`x-ai`**。`xai-oauth` というキーは無い。
2. `_canonicalise_provider_id("xai-oauth")` は **`xai-oauth` のまま**返す
   （`xai` / `x-ai` に正規化されない）。
3. このためグループ生成ループで `xai-oauth` はどの分岐にも入らず、**グループ 0 件**になる。
4. 最後の「デフォルトモデル注入」処理が
   ```python
   if not injected and groups:   # ← groups が非空であることが条件
   ```
   となっており、**groups が空のままだと grok-4.3 すら注入されない**。
5. 結果 `/api/models` が `groups: []` を返す。
6. フロント `static/ui.js` は groups が空だと早期 return（"keep HTML defaults"）し、
   その後の `_fetchLiveModels()`（ライブ取得）に到達しない → 何も表示されない。

```
detected_providers = {xai-oauth}
  → loop で xai-oauth はどの catalog 分岐にも該当せず group 追加されない
  → groups = []
  → default 注入は "and groups" ガードで skip
  → groups = []  ← /api/models の応答
  → ui.js が早期 return → ライブ取得が走らない → 選択肢ゼロ
```

### さらに：ディスクキャッシュによる固着
`get_available_models()` の結果は `~/.hermes/webui/models_cache.json` に永続化される
（マウント先なのでコンテナ再作成・イメージ再ビルドでも残る）。
一度 `groups: []` がキャッシュされると、fingerprint ベースの無効化では更新されず
**古い空の結果が返り続けた**。

> 注意：キャッシュ機構自体は正常（性能用）。問題は「空の値が焼き付いた」こと。
> よってキャッシュを無効化する必要はない。修正後に**一度だけ削除**すればよい。

---

## 5. 適用した修正

### ① 環境変数を共有 .env に集約（根本原因①）
- `~/.hermes/.env` に追記：
  ```
  FIRECRAWL_API_KEY=fc-...   # 値は元の compose 由来
  ```
  → 両エージェント（gateway / WebUI）が同一の web 設定を読むようになる。
- `docker-compose.yml` の `hermes-agent` から重複していた
  `SEARXNG_URL` / `FIRECRAWL_API_KEY` を削除し、`.env` を単一ソースに統一
  （ドリフト防止のコメントを追記）。

### ② モデル注入パッチ（根本原因②）
- `hermes-webui/api/config.py` の `get_available_models()`：
  ```python
  # 変更前
  if not injected and groups:
  # 変更後（ローカルパッチ）
  if not injected:
  ```
  → グループが空でも設定済みデフォルト（grok-4.3）を必ず注入。
  groups が非空になるのでフロントが早期 return せず、`_fetchLiveModels()` で
  残りの grok モデルも補完される。

### ③ 反映手順
WebUI は起動毎に `/apptoo`（イメージ内）→ `/app` へ rsync するため、
コードパッチはイメージ再ビルドが必須：
```bash
docker compose build hermes-webui
rm -f ~/.hermes/webui/models_cache.json   # 古い空キャッシュを一度だけ削除
docker compose up -d hermes-webui
```

---

## 6. 検証結果

| 項目 | 結果 |
|---|---|
| 両エージェントが SEARXNG / FIRECRAWL を認識 | ✅ どちらも `True`（共有 .env 経由） |
| WebUI エージェントのバックエンド解決 | ✅ `search=searxng` / `extract=firecrawl` |
| `/api/models` の groups | ✅ `xai-oauth → grok-4.3`（以前は `[]`） |
| `/api/models/live` | ✅ grok-4.3 ほか 8 件 |
| 再生成された models_cache.json | ✅ grok-4.3 入り（正しく永続化） |
| gateway / health | ✅ `alive`, `gateway running` |

---

## 7. 注意点・今後

- **`config.py` のパッチはローカル改変**。hermes-webui を上流更新すると消える。
  再適用するか、上流が OAuth/portal プロバイダの空グループを修正したか確認する。
  （上流へバグ報告する価値あり：`xai-oauth` 等で `get_available_models()` が空 groups を返し、
  デフォルト注入が `and groups` ガードで skip される）
- **`models_cache.json` はマウント永続**。モデル周りのロジックを変えたら一度削除する。
  キャッシュ自体は残してよい（高速化に有用）。
- Web ツールの秘密情報（`SEARXNG_URL`, `FIRECRAWL_API_KEY`, `EXA_API_KEY` 等）は
  **必ず `~/.hermes/.env` に置く**。単一コンテナの compose `environment:` だけに書くと
  WebUI 側のエージェントから見えず連携が壊れる。

## 8. 再発防止チェックリスト

- [ ] 新しい web/ツール系の秘密は `~/.hermes/.env` に追加したか（compose の片方だけにしていないか）
- [ ] `docker exec -u hermeswebui hermes-webui ...` で WebUI エージェントからキーが見えるか確認したか
- [ ] モデルが出ない時は `/api/models`（groups）と `/api/models/live` を切り分けたか
- [ ] モデル系の変更後に `~/.hermes/webui/models_cache.json` を削除したか
- [ ] コード変更は `docker compose build` でイメージに焼き込んだか（`/app` への直接編集は再起動で消える）

---

## 9. 根本原因 ③：hermes-agent-src ボリュームの陳腐化（`Restarting (127)` ループ）

追記日: 2026-06-02

### 事象
`docker ps` で `hermes-agent` が `Restarting (127) 24 seconds ago` のような状態を
延々と繰り返す。WebUI は依存停止または不安定。

### ログの典型パターン
```
/etc/cont-init.d/01-hermes-setup: 2: exec: /opt/hermes/docker/stage2-hook.sh: not found
cont-init: info: /etc/cont-init.d/01-hermes-setup exited 127
/opt/hermes/.venv/bin/python: No module named hermes_cli.container_boot
cont-init: info: /etc/cont-init.d/02-reconcile-profiles exited 1
...
/run/s6/basedir/scripts/rc.init: 91: /opt/hermes/docker/main-wrapper.sh: not found
```

exit code 127 = command not found。`stage2-hook.sh` / `main-wrapper.sh` /
`hermes_cli.container_boot` がいずれも見つからない、というのが特徴。

### 原因
`/opt/hermes` をマウントしている **名前付きボリューム `hermes-docker_hermes-agent-src`
の中身が、pull した新しい image と乖離している**。

Docker は名前付きボリュームを**初回作成時にしか image の内容でシードしない**仕様。
したがって `docker compose pull` で image を新しくしても、ボリュームは**作成当初の
古い image の `/opt/hermes` をそのまま保持し続ける**。image 側の `/etc/cont-init.d/*`
（これは image 内にあるので新しくなる）が新パスを参照するのに、ボリュームには
そのファイルが無いため exit 127 → s6 がコンテナを kill → restart loop。

検証時の例：

| パス | 古いボリューム | 新しい image |
|---|---|---|
| `/opt/hermes/docker/` | `SOUL.md`, `entrypoint.sh` のみ | `stage2-hook.sh`, `main-wrapper.sh`, `hermes-exec-shim.sh` 等が揃っている |
| `/opt/hermes/hermes_cli/container_boot.py` | 無い | 有る |

### 対処（webui も同ボリュームを共有しているので一緒に再生成する）
```bash
docker compose stop hermes-agent hermes-webui
docker compose rm -f hermes-agent hermes-webui
docker volume rm hermes-docker_hermes-agent-src
docker compose up -d hermes-agent hermes-webui
```

- `~/.hermes`（ユーザデータ）は**バインドマウント**なのでこの操作で消えない。
- `hermes-agent-src` ボリュームはアプリ本体のコード共有用なので、image から
  再シードして問題なし。
- webui は `/home/hermeswebui/.hermes/hermes-agent` で同ボリュームを共有しているため、
  片方だけ消そうとすると `volume is in use` で失敗する。両方止めてから消す。

### 注意点
- これ自体は復旧手順だが、§4 の `config.py` パッチ（[[hermes-webui-xai-oauth-model-picker-patch]]）は
  webui の **イメージ内ファイルへの改変**なので、`hermes-agent-src` の再生成では消えない
  （別レイヤ）。ただし upstream image の更新で `config.py` の構造が変わるとパッチが
  当たらなくなる可能性があるので、復旧後にモデルピッカーで grok が出るか確認すること。
- `models_cache.json` は `~/.hermes/webui/` 配下なのでバインドマウント側、こちらも残る。

### 再発予防
- `docker compose pull` で image を更新したあと、init ログにエラーが出ていないか
  一度 `docker logs hermes-agent --tail 50` で確認する習慣をつける。
- exit 127 や `not found` / `No module named` が出ていたら本セクションの手順を実行。
- 2026-06-02 に hermes-agent に **process-based healthcheck** を追加した
  （§11 参照）。陳腐化で init が失敗するとコンテナが `unhealthy` になるので、
  `docker ps` で気付きやすくなった。

---

## 10. docker-compose.yml の既知の設計上の弱点

追記日: 2026-06-02

過去の不具合の整理のなかで、`docker-compose.yml` 自体に潜む弱点が複数見つかった
ため記録。**現在の運用では一部対処済み**（§11 参照）だが、根本治療には webui /
hermes-agent image 側の改修が必要なものもある。

### 10.1 [未解決] `hermes-agent-src` named volume の構造的 staleness（最重要）

§9 の根本原因と同じ。`/opt/hermes` を名前付きボリュームでマウントする限り、
**image を更新するたびに staleness のリスクが残り続ける**。

この構造は webui の `docker_init.bash` が

```
uv pip install /home/hermeswebui/.hermes/hermes-agent[all]
```

として hermes-agent ソースを参照することに起因する。すなわち
「webui コンテナが hermes-agent のソースに到達するための共有経路」が必要で、
そのためにこのボリュームが存在している。

#### 検討した代替案

| 案 | 内容 | コスト | 推奨度 |
|---|---|---|---|
| A | webui の Dockerfile で hermes-agent を直接 pip install（PyPI / Git） | webui 側 Dockerfile・bootstrap の改修が必要 | 長期的にはこれが正解 |
| B | webui の bootstrap が起動時に hermes-agent image の中身を `docker cp` 相当で取得 | webui の起動シーケンスを大きく変える | 複雑、非推奨 |
| C | named volume を使わず、ホスト側に hermes-agent ソースを展開してバインドマウント | 「自分でアプリソースを管理する」運用に変わる | 開発用途には良いが本番には不向き |
| D | 現状維持 + 手動復旧手順を文書化 | ゼロコスト、ただし image 更新のたびに当事者が手を動かす | **採用中**（§9） |

webui の upstream が `pip install hermes-agent` のパスを整えてくれれば
A に移行できる。それまでは D。

### 10.2 [対処済 §11.1] `${UID:-1000}` / `${GID:-1000}` がフォールバックで動いていた

旧定義：
```yaml
- HERMES_UID=${UID:-1000}
- HERMES_GID=${GID:-1000}
```

問題：
- bash の `UID` は **readonly だが未 export**。compose のシェル変数読み取りで
  拾えるかは実装依存
- `GID` はそもそも bash built-in に無く、ホストシェルでも空

→ ほとんどのケースで `:-1000` のフォールバックが効いて結果的に動くが、
**ホスト UID/GID が 1000:1000 でない環境では暗黙の不整合が起きる**
（`~/.hermes` を bind mount したときの permission ミスマッチ等）。

§11.1 で `HOST_UID` / `HOST_GID` という明示的な変数に切り替えた。

### 10.3 [対処済 §11.2] `depends_on` に health 条件が無かった

旧定義：
```yaml
hermes-webui:
  depends_on:
    - hermes-agent      # condition なし → service_started 扱い
hermes-agent:
  depends_on:
    - searxng           # searxng には healthcheck があるのに無視
```

問題：
- `service_started` は「コンテナの開始」だけを待つので、§9 のような
  init で死んで restart loop している状態でも webui は起動を試みる
- `searxng` には既に healthcheck があるのに `hermes-agent` 側は依存条件を
  指定していないため、searxng が立ち上がる前に gateway 起動を試行する可能性

§11.2 で agent に healthcheck を追加し、両方の `depends_on` を
`condition: service_healthy` 化した。

### 10.4 [未解決] webui の env split-brain 構造（運用ルールで回避中）

§3 と同じ。`hermes-webui` の `env_file: ./hermes-webui/.env` と、
両エージェントが読む `~/.hermes/.env` の **二系統が存在**しており、
ツール系の秘密（FIRECRAWL_API_KEY 等）をどちらに書くかで挙動が変わる。

→ compose だけで構造的に解決するのは難しい（webui process 用と
shared tool secret 用を物理的に分けたい意図はある）。**運用ルール：
「秘密は `~/.hermes/.env` のみ。`./hermes-webui/.env` には webui プロセス
設定だけ書く」を守る**。

§11.3 で compose にこのルールをコメントとして追記。

### 10.5 [未解決] `hermes-hudui` が root で動いている

```yaml
hermes-hudui:
  environment:
    - HERMES_HOME=/root/.hermes
  volumes:
    - ${HOME}/.hermes:/root/.hermes
```

他コンテナは `hermes` / `hermeswebui` という非 root ユーザで `~/.hermes` を
触るが、hudui だけ root で同じディレクトリを操作する。

リスク：**hudui が root で `~/.hermes` に書き込んだファイルを、他コンテナの
非 root ユーザが触れず permission denied になる**ことがある。今のところ
顕在化していないが、hudui がファイル書き込みする経路が増えたら必ず踏む。

根本治療には `hermes-hudui/Dockerfile` で非 root ユーザを作って `USER` を
切り替える必要がある。compose 側だけでは対処できない（compose の `user:`
ディレクティブはあるが、image が root 前提で書かれていれば壊れる）。

### 10.6 [情報] `127.0.0.1:8642:8642` の port mapping は現状未使用

調査時に `hermes-agent` コンテナ内では `8642` で何も listen していないことを
確認した（gateway は messaging/cron で HTTP 公開なし。dashboard は
`HERMES_DASHBOARD=1` のときのみ port 9119）。

この mapping を残しているのは将来の HTTP API のためか、過去の名残かは不明。
**害は無いが、現状の `curl http://127.0.0.1:8642/...` は常に失敗する**ことを
覚えておくと事故が減る。

---

## 11. 適用した修正（2026-06-02）

§10 で挙げた弱点のうち、リスクゼロで入れられるものを順次適用した。

### 11.1 UID/GID を明示変数化

**`.env`** に追記：
```env
HOST_UID=1000
HOST_GID=1000
```

**`docker-compose.yml`** （hermes-agent）：
```yaml
environment:
  - HERMES_UID=${HOST_UID:-1000}   # was: ${UID:-1000}
  - HERMES_GID=${HOST_GID:-1000}   # was: ${GID:-1000}
```

→ 他ホストへこの一式を持っていく場合は `.env` の値を `id -u` / `id -g` に
合わせて変更すればよい。bash の built-in に依存しなくなった。

### 11.2 hermes-agent に process-based healthcheck＋depends_on を service_healthy 化

`hermes-agent` に追加：
```yaml
healthcheck:
  # No HTTP surface — gateway is messaging/cron only (port 8642 mapping
  # is currently unused). Process-based check catches init failures (the
  # exit-127 staleness loop) and post-start crashes that s6 can't restore.
  test: ["CMD-SHELL", "pgrep -f 'hermes gateway run' >/dev/null"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 90s
```

`hermes-agent.depends_on` と `hermes-webui.depends_on` を健全性ベースに：
```yaml
hermes-agent:
  depends_on:
    searxng:
      condition: service_healthy
hermes-webui:
  depends_on:
    hermes-agent:
      condition: service_healthy
```

効果：
- §9 の staleness 障害が再発したとき、`docker ps` で `unhealthy` になり
  早く検知できる
- webui は agent が **本当に init を抜けて gateway プロセスとして
  立ち上がるまで** 起動を待つ

検証：
```
$ docker ps --filter "name=hermes" --format "table {{.Names}}\t{{.Status}}"
NAMES          STATUS
hermes-agent   Up 8 seconds (healthy)
hermes-webui   Up 10 minutes (healthy)
```

### 11.3 compose に運用ルールをコメントとして埋め込んだ

- `hermes-agent.volumes` の `hermes-agent-src:/opt/hermes` 行に、staleness と
  復旧手順への参照コメント
- `hermes-webui.env_file` に、秘密は `~/.hermes/.env` 側に書くべきという
  ルールコメント
- `hermes-webui.volumes` の `hermes-agent-src` 行に、agent 側と同じ staleness
  注意のコメント

→ compose を読んだ人がドキュメントを当たらなくても落とし穴に気付ける。

### 11.4 未対処の項目（再掲）

- 10.1（hermes-agent-src の構造的 staleness） — 設計改修が必要、当面 §9 の
  手動復旧で対応
- 10.4（env split-brain） — 運用ルールで回避
- 10.5（hudui が root） — hudui 側 Dockerfile 改修が必要

これらは TODO として残す。

