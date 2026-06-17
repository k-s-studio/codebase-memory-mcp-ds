# codebase-memory-mcp 非官方 Docker 包裝（UI 版）
#
# 這個專案本身主打 "single static binary, zero infrastructure"，官方不提供
# Dockerfile。這裡純粹是把該二進位檔包進 image，方便在 docker-compose 環境裡
# 跟其他服務一起管理，並把內建的 3D 知識圖譜 UI 一起跑起來。
#
# 為什麼用 UI 變體（codebase-memory-mcp-ui-*）：
#   標準變體拒絕 --ui（沒有內嵌 UI 資源）。UI 變體同名（codebase-memory-mcp）
#   但體積大很多（~270MB），同一支 binary 同時提供 MCP server（stdio）與 UI。
#
# 為什麼用 *-portable：
#   標準/UI 的非 portable 版是動態連結，依賴執行環境的 glibc/libstdc++ 版本
#   （需 GLIBC_2.38+ / GLIBCXX_3.4.32+），debian:12-slim 太舊會跑不起來。
#   *-portable 是 static linked，不依賴系統 glibc，可放進任何 base image。
#
# 執行架構見 docker-entrypoint.sh：UI thread 與 stdio MCP loop 同一個 process，
# 且 UI 只綁 127.0.0.1，故用 socat 轉出 0.0.0.0。

ARG CBM_VERSION=latest

# ---------- Stage 1: 下載 + 驗證 release ----------
FROM debian:12-slim AS fetch

ARG CBM_VERSION
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/cbm

# TARGETARCH 是 buildx 注入的 amd64 / arm64，對應 release 檔名
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) CBM_ARCH=amd64 ;; \
        arm64) CBM_ARCH=arm64 ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    if [ "$CBM_VERSION" = "latest" ]; then \
        BASE_URL="https://github.com/DeusData/codebase-memory-mcp/releases/latest/download"; \
    else \
        BASE_URL="https://github.com/DeusData/codebase-memory-mcp/releases/download/${CBM_VERSION}"; \
    fi; \
    ARCHIVE="codebase-memory-mcp-ui-linux-${CBM_ARCH}-portable.tar.gz"; \
    curl -fsSL -o "$ARCHIVE" "${BASE_URL}/${ARCHIVE}"; \
    curl -fsSL -o checksums.txt "${BASE_URL}/checksums.txt"; \
    grep " ${ARCHIVE}\$" checksums.txt | sha256sum -c -; \
    tar -xzf "$ARCHIVE"; \
    chmod +x codebase-memory-mcp

# ---------- Stage 2: 執行期 ----------
FROM debian:12-slim

# git: index_repository 變更偵測；socat: 把 loopback-only 的 UI 轉到 0.0.0.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git socat \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin cbm

COPY --from=fetch /tmp/cbm/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV CBM_CACHE_DIR=/home/cbm/.cache/codebase-memory-mcp
RUN mkdir -p "$CBM_CACHE_DIR" && chown -R cbm:cbm /home/cbm

USER cbm
# 與 docker-compose.yml 的 bind-mount target 一致（你的原始碼會唯讀掛在這裡）
WORKDIR /codebase-memory-mcp-ds

# 3D 知識圖譜 UI（透過 entrypoint 的 socat 轉出）
EXPOSE 9749

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
