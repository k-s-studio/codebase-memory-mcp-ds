# codebase-memory-mcp-ds — 非官方 Docker 打包（含 3D UI）

> **Unofficial Docker packaging of [`codebase-memory-mcp`](https://github.com/DeusData/codebase-memory-mcp).**
> 把上游那支「單一靜態二進位檔」的 MCP server 跑成 Docker 容器，並一鍵接上 Claude Code
>（skill / hooks / MCP 全部指向容器），同時把內建的 3D 知識圖譜 UI 一起開起來。
>
> - 上游專案：<https://github.com/DeusData/codebase-memory-mcp>（MIT，© 2025 DeusData）
> - 與 DeusData **無任何隸屬關係**；上游官方明說「No Docker」，這是社群包裝。
> - 本 repo 的打包檔以 **The Unlicense**（公眾領域）釋出；vendored 自上游的檔案維持上游 MIT。
>   詳見 [LICENSE](LICENSE) / [NOTICE](NOTICE)。

---

## 0. 它是什麼

`codebase-memory-mcp` 是一個 **MCP server**，把一個 codebase 解析成「知識圖譜」
（functions / classes / routes / 呼叫關係…），讓 AI agent 用圖譜工具查程式碼，比純文字
grep 精準。設計理念是**單一靜態二進位檔、零基礎設施**：

- 底層儲存是 **SQLite**（不是 Neo4j），但支援唯讀的 openCypher 子集查詢。
- 跟 client 之間走 **stdio**（JSON-RPC over stdin/stdout），**不是 HTTP service、沒有對外 port**。
- UI 變體額外內建 **3D 知識圖譜視覺化**（HTTP，預設 `localhost:9749`）。
- 提供 14 個工具：`index_repository`, `search_graph`, `query_graph`, `trace_path`,
  `get_code_snippet`, `get_graph_schema`, `get_architecture`, `search_code`,
  `list_projects`, `delete_project`, `index_status`, `detect_changes`, `manage_adr`,
  `ingest_traces`。

**這個 repo 本身不含任何二進位檔。** Docker image 在 `build` 時才從上游 GitHub Releases
下載官方發布的 binary，並用官方 `checksums.txt` 驗 SHA256。所以你拿到的永遠是上游正版檔。

---

## 1. 快速開始（Windows）

前置：已安裝 **Docker Desktop**。

### 方式一：`install.ps1`（推薦，全自動）

下載並執行；它會 build + 啟動容器，並把 Claude Code 的 skill / hooks / MCP 全部接到容器：

```powershell
# 1. 下載
Invoke-WebRequest -Uri https://raw.githubusercontent.com/k-s-studio/codebase-memory-mcp-ds/main/install.ps1 -OutFile install.ps1

# 2.（建議）先看過腳本內容
notepad install.ps1

# 3. 執行
.\install.ps1                          # 預設索引 C:/Workspace、抓上游 latest
.\install.ps1 -WorkspacePath D:/code   # 改成索引別的原始碼目錄
.\install.ps1 -Version v0.8.1          # 鎖定上游版本（reproducible build，見 §6）
```

執行後：**重啟 Claude Code** 讓它重新載入 skill / hooks / MCP，然後請 agent 對你的專案跑一次
`index_repository`（見 §4）。3D UI 開在 <http://localhost:9749>。

`install.ps1` 參數：

| 參數 | 預設 | 作用 |
|---|---|---|
| `-WorkspacePath` | `C:/Workspace` | 唯讀掛載進容器 `/workspace` 的原始碼根目錄 |
| `-Version` | `latest` | 要抓的上游 release（`latest` 或 `vX.Y.Z`）|
| `-SkipCleanup` | off | 保留舊的「上游本機安裝」，不移除 |
| `-SkipBuild` | off | 只重接 agent，不碰 docker build/up |
| `-Download` | off | 即使在 checkout 內也強制從 GitHub 下載 repo |
| `-SourceDir` | — | 用指定的本機 checkout 當來源 |

### 方式二：手動 `docker compose`

只想要容器、不要動 agent 設定時：

```powershell
$env:CBM_WORKSPACE = "C:/Workspace"     # 要索引的原始碼根目錄
docker compose build                    # 鎖版本：docker compose build --build-arg CBM_VERSION=v0.8.1
docker compose up -d
```

手動方式需要你自己把 Claude Code 的 MCP 指向容器（見 §3.2）。

---

## 2. `install.ps1` 做了什麼

> 它**不是**上游的安裝器。上游安裝器是下載 binary 到本機、再跑 `<binary> install -y` 讓
> binary 自己設定 agent——但那一套對容器化行不通（容器內的 binary 寫的是容器的 `$HOME`、
> 偵測不到 host 上的 agent）。所以這支腳本改由 PowerShell 自己做接線。

1. **取得 repo**：本機 checkout 優先，否則從 GitHub 下載 zip。
2. **`docker compose build` + `up -d`**：image 在 build 時抓上游 UI binary（見 §0）。
3. **把 agent 接到容器**：

   | 接線項目 | 指向 |
   |---|---|
   | MCP server `codebase-memory-ds` | `docker exec -i codebase-memory-ds codebase-memory-mcp --ui=false` |
   | PreToolUse hook（圖譜輔助） | 經 `docker exec` 呼叫容器內 `hook-augment` |
   | SessionStart hook（啟動提醒） | 純文字提醒（不碰容器） |
   | skill | 安裝為 `~/.claude/skills/codebase-memory-ds/` |

4. **（預設）清掉舊的上游本機安裝**：舊容器 / volume、skill `codebase-memory`、hook `cbm-*`、
   MCP 條目、本機 exe、PATH。用 `-SkipCleanup` 可保留。

所有對 `~/.claude/*.json` 的修改**都會先備份**成 `*.bak-<timestamp>`，可回滾。

> **命名**：所有 host 端產物都命名為 `codebase-memory-ds` / `cbm-ds-*`，與上游官方安裝
> 零衝突、可並存。容器內的二進位檔仍叫 `codebase-memory-mcp`（內部實作細節，不影響使用）。

---

## 3. 容器架構

```
            host browser ──http──► http://localhost:9749
                                         │  (docker compose: ports 9749:9749)
   ┌─────────────────────────────────────┼──────────────────────────────────┐
   │ container  (entrypoint = docker-entrypoint.sh, 以非 root 'cbm' 執行)     │
   │                                      ▼                                   │
   │   PID1: socat  0.0.0.0:9749 ───────► 127.0.0.1:9750                       │
   │                                       └ codebase-memory-mcp --ui=true     │
   │                                         --port=9750                       │
   │                                         (UI thread + idle stdio MCP)      │
   │                                         stdin 由 `tail -f /dev/null` 保活  │
   │                                                                          │
   │   Claude ──docker exec -i──► codebase-memory-mcp --ui=false               │
   │                              (每次連線一個 per-session stdio MCP process) │
   │                                                                          │
   │   兩條路徑共用同一份 SQLite 索引（volume: cbm-ds-cache）                  │
   │   原始碼：${CBM_WORKSPACE} ──(ro)──► /workspace                           │
   └──────────────────────────────────────────────────────────────────────────┘
```

### 3.1 檔案職責

- **[`Dockerfile`](Dockerfile)** — multi-stage：
  - stage `fetch`：依 `TARGETARCH`（amd64/arm64）組出
    `codebase-memory-mcp-ui-linux-<arch>-portable.tar.gz` 下載網址，抓檔 + 用 `checksums.txt`
    驗 SHA256 + 解壓。`CBM_VERSION` build arg 預設 `latest`，可鎖版本。
  - stage runtime（`debian:12-slim` + `git` + `socat`，非 root user `cbm`）：COPY 二進位檔與
    entrypoint，設 `CBM_CACHE_DIR`，`EXPOSE 9749`。
- **[`docker-entrypoint.sh`](docker-entrypoint.sh)** — 啟動 UI（loopback `127.0.0.1:9750`，
  stdin 用 `tail -f /dev/null` 保活）＋ `exec socat` 把 `0.0.0.0:9749` 轉到 `127.0.0.1:9750`
  （socat 當 PID1，它死容器就停）。內部 port 可用 `CBM_UI_PORT_INTERNAL`（預設 9750）、
  `CBM_PUBLISH_PORT`（預設 9749）覆寫。
- **[`docker-compose.yml`](docker-compose.yml)** — service/container/image 皆為
  `codebase-memory-ds`、`ports: 9749:9749`、volumes：named `cbm-ds-cache`（索引持久化）＋
  `${CBM_WORKSPACE:-C:/Workspace}:/workspace:ro`（原始碼唯讀）。
- **[`install.ps1`](install.ps1)** — 見 §2。
- **[`agent/`](agent/)** — 要複製到 host `~/.claude` 的素材：`skills/codebase-memory-ds/SKILL.md`
  （vendored 自上游）、`hooks/cbm-ds-code-discovery-gate`（原創，走 docker exec）、
  `hooks/cbm-ds-session-reminder`（vendored 自上游）。

### 3.2 手動接線（不想用 install.ps1 時）

把 Claude Code 的 MCP `command` 指向容器。`~/.claude.json` 的 `mcpServers` 區塊：

```json
{
  "mcpServers": {
    "codebase-memory-ds": {
      "command": "docker",
      "args": ["exec", "-i", "codebase-memory-ds", "codebase-memory-mcp", "--ui=false"]
    }
  }
}
```

> ⚠️ 若你在 Windows 上手改 `~/.claude.json`：它的 `projects` 區塊常有大小寫不同的重複路徑 key
> （`C:/` vs `c:/`），會讓 PowerShell 的 `ConvertFrom-Json` 解析失敗。`install.ps1` 用的是
> 只動 `mcpServers` 區塊的局部編輯來繞過這個問題；手改請小心別整檔 round-trip。

---

## 4. 索引一個專案（重點：用容器內路徑）

容器看到的是 `/workspace/...` 不是 `C:\...`。透過 MCP 工具：

```
index_repository(repo_path="/workspace/<your-project>")
```

`${CBM_WORKSPACE}`（預設 `C:/Workspace`）已整個唯讀掛進 `/workspace`，所以其底下任何 repo
都只要對 `/workspace/<repo>` 跑一次 `index_repository`。容器初次啟動時索引是空的。

---

## 5. Runbook

```powershell
# 狀態 / port
docker ps --filter name=codebase-memory-ds

# UI 是否回應（host 端）
Invoke-WebRequest -Uri http://localhost:9749 -UseBasicParsing | Select-Object StatusCode

# 列出已索引專案（不經 MCP handshake，直接 cli）
docker exec -i codebase-memory-ds codebase-memory-mcp --ui=false cli list_projects

# 啟動 / 停止 / 重建
docker compose up -d
docker compose down                      # 停止並移除容器（保留 cbm-ds-cache / 索引）
docker compose up -d --force-recreate    # 改了 image/compose 後重建
```

---

## 6. 版本鎖定 / reproducible build

預設 `CBM_VERSION=latest` 代表**每次 build 都抓上游當下最新 release**——同一份 Dockerfile
在不同時間 build 結果可能不同，而且上游若出 breaking change（CLI flag、UI port 綁定、config
持久化機制…），你的 build 可能突然壞掉，但本 repo 內容沒變。

要 **reproducible build**，鎖定版本：

```powershell
.\install.ps1 -Version v0.8.1
# 或手動：
docker compose build --build-arg CBM_VERSION=v0.8.1
```

> 升級版本前建議先看上游 release note。注意：`install -y` / 升版偵測到索引格式不相容時，
> 上游 binary 會**自動刪掉既有索引**（需重新 `index_repository`）。

---

## 7. 清理 / 回退

```powershell
# 停容器（要連索引一起清就加 -v）
docker compose down            # 保留索引 volume
docker compose down -v         # 連 cbm-ds-cache 索引一起刪

# 移除 image
docker image rm codebase-memory-ds:ui-local
```

回退成上游本機版：照上游 README 跑 `install.ps1`（不帶本 repo 的 Docker 流程），再把
`~/.claude.json` 的 `command` 指回本機 exe。`install.ps1` 改動前的 `*.bak-*` 備份可用來還原設定。

---

## 8. 已知限制 / 注意事項

- **索引路徑必須是容器路徑** `/workspace/<repo>`，不能用 Windows 路徑。
- **原始碼是唯讀掛載**（`:ro`）：對 `index_repository`（純掃描）沒問題；若日後用到任何寫回
  原始碼的功能會受限，需改掛載模式。
- **UI 與 MCP session 共用同一份 SQLite**：大型重建時 UI 可能短暫卡頓（SQLite 靠檔案鎖處理）。
- **vendored skill 是凍結版本**：`agent/skills/codebase-memory-ds/SKILL.md` vendored 自上游
  v0.8.1。上游若更新這份 cheat-sheet，本 repo 不會自動跟；需手動覆蓋後重跑 `install.ps1`。
- **非官方包裝**：上游官方明說「No Docker」。

---

## 9. 授權與屬名

- 本 repo 的**原創打包檔**（`Dockerfile`、`docker-entrypoint.sh`、`docker-compose.yml`、
  `install.ps1`）以 **The Unlicense**（公眾領域）釋出——隨意使用，不主張版權。見 [LICENSE](LICENSE)。
- 從上游 **vendored** 的檔案（`agent/skills/codebase-memory-ds/SKILL.md`、
  `agent/hooks/cbm-ds-session-reminder`）維持上游 **MIT License，© 2025 DeusData**，
  來源為上游 `src/cli/cli.c`。完整屬名見 [NOTICE](NOTICE)。
- 上游二進位檔**未在本 repo 重新散布**，由 Docker build 在執行時從上游 GitHub Releases 下載。
