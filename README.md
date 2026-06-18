# codebase-memory-mcp-ds

## Introduction

Unofficial Docker packaging for
[`codebase-memory-mcp`](https://github.com/DeusData/codebase-memory-mcp).

This repository is **codebase-memory-mcp-ds**, not the upstream
`codebase-memory-mcp` project. It exists to run the upstream MCP server and 3D
graph UI from Docker, then wire local agents to that container. For product
features, MCP tool behavior, releases, and upstream design, read the upstream
repository.

The upstream binary is not committed here. Each Docker build downloads release
artifacts from upstream GitHub Releases at build time and verifies them with
the published checksums.

## Quick Start

Choose one host folder Docker may read. This is usually the parent folder where you keep all projects. The default is C:/Workspace, mounted read-only as /workspace.
```powershell
Invoke-WebRequest `
  -Uri https://raw.githubusercontent.com/k-s-studio/codebase-memory-mcp-ds/main/install.ps1 `
  -OutFile install.ps1

.\install.ps1 -WorkspacePath C:/path/to/projects
```

Optional:
- Pin an upstream release instead of using latest
  ```powershell
  .\install.ps1 -Version v0.8.1
  ```
- publish the UI on a specific host port
  ```powershell
  .\install.ps1 -UiPort 9751
  ```

```powershell
# Manual Docker flow
$env:CBM_WORKSPACE = "C:/Workspace"
$env:CBM_UI_PORT = "9749"
docker compose build --build-arg CBM_VERSION=latest
docker compose up -d
```

```text
UI: installer prints the actual URL; default is http://localhost:9749
Host source root example: C:/Workspace
Container source root: /workspace
MCP repo path example: /workspace/my-repo
```

Restart your agent after installation so it reloads MCP config, hooks, and the
`codebase-memory-ds` skill.

`-WorkspacePath` and `CBM_WORKSPACE` are host paths. MCP tools must use paths
under the container mount `/workspace`.

## Host Command

The installer adds `codebase-memory-mcp-ds` to your user PATH. Restart the
terminal if the command is not found immediately after install.

```powershell
codebase-memory-mcp-ds status
codebase-memory-mcp-ds ui
codebase-memory-mcp-ds index C:/Workspace/my-repo
codebase-memory-mcp-ds projects
codebase-memory-mcp-ds cli search_graph '{"label":"Function","name_pattern":".*Handler.*"}'
```

Useful commands:

- `mcp`: run the MCP stdio server through `docker exec`; this is what agent
  config uses.
- `cli <tool> [json]`: invoke one upstream MCP tool inside the container.
- `index <path>`: convert a host path under `-WorkspacePath` to `/workspace/...`
  and call `index_repository`.
- `status` / `doctor`: check Docker, container, UI, workspace, and wrapper
  configuration.
- `ui` / `port`: print the actual graph UI URL and port mapping.
- `logs`, `start`, `stop`, `restart`: manage the DS container.
- `config <list|get|set|reset>`: manage upstream runtime config in the Docker
  volume.
- `update [version]`: DS-specific update; rebuilds the Docker image and runs
  `docker compose up -d`.
- `uninstall [-y] [--volumes] [--image] [--keep-cli]`: DS-specific uninstall;
  removes DS resources only and leaves any upstream local install alone.

The wrapper intentionally does not support upstream `install` or UI flags such
as `--ui=true --port=9749`. Use `install.ps1` for host agent setup and
`install.ps1 -UiPort <port>` for the host UI port.

## Known Limitations / Notes

- The container sees your selected host source root at `/workspace`.
- The workspace bind mount is read-only by default.
- Only one host source root is mounted by the default compose file. Put repos
  under that root, or edit `docker-compose.yml`.
- Each Docker build fetches the upstream release artifact from GitHub Releases.
  Builds require network access and can change when `CBM_VERSION=latest`.
- Use `-Version vX.Y.Z` or `--build-arg CBM_VERSION=vX.Y.Z` for reproducible
  builds.
- The UI and MCP sessions share the same container cache volume.
- The MCP server exposed to agents is stdio via `docker exec`, not HTTP.
- The installer prefers UI port 9749, but automatically picks the next free
  port when 9749 is already in use. Pass `-UiPort` to require a specific port.
- Hooks are best-effort agent helpers. The PreToolUse hook exits successfully if
  Docker or the container is unavailable.

## Cleanup / Rollback

```powershell
$env:CBM_WORKSPACE = "C:/Workspace"
docker compose down
docker compose down -v
docker image rm codebase-memory-mcp-ds:ui-local
```

```powershell
# Remove installed ds skill and hooks
Remove-Item "$HOME/.claude/skills/codebase-memory-ds" -Recurse -Force
Remove-Item "$HOME/.claude/hooks/cbm-ds-*" -Force
```

`install.ps1` backs up edited JSON files as `*.bak-<timestamp>`. Restore those
backups if you want to roll back MCP or hook configuration exactly.

`install.ps1` preserves an existing upstream local install by default. Use
`.\install.ps1 -RemoveLegacy` only when you explicitly want this Docker edition
to remove the older upstream resources.

## Container Architecture and File Responsibilities

```text
Host browser
  -> http://localhost:<host-ui-port>
  -> Docker published port ${CBM_UI_PORT:-9749}:9749
  -> socat in container
  -> 127.0.0.1:9750
  -> codebase-memory-mcp --ui=true

Agent MCP client
  -> codebase-memory-mcp-ds mcp
  -> docker exec -i codebase-memory-mcp-ds codebase-memory-mcp --ui=false

Host source root
  -> /workspace:ro

Named cache volume
  -> /home/cbm/.cache/codebase-memory-mcp
```

- `Dockerfile`: two-stage image. The fetch stage downloads
  `codebase-memory-mcp-ui-linux-<arch>-portable.tar.gz` and `checksums.txt`
  from upstream GitHub Releases during every Docker build, verifies SHA256, and
  copies the binary into a Debian runtime image.
- `docker-entrypoint.sh`: starts the upstream binary with `--ui=true` on an
  internal loopback port, keeps stdin open so the UI process stays alive, and
  exposes it through `socat` on `0.0.0.0:9749` inside the container.
- `docker-compose.yml`: fixes the Docker Compose project, service, container,
  and image names to `codebase-memory-mcp-ds`, then defines the host UI port,
  cache volume, and read-only workspace mount at `/workspace`. The host UI port
  defaults to 9749 and can be set with `CBM_UI_PORT`.
- `install.ps1`: Windows installer. It resolves or downloads this repo, sets
  `CBM_WORKSPACE` and `CBM_UI_PORT`, runs `docker compose build` and `up -d`,
  installs the `codebase-memory-ds` skill, hooks, and host command, registers
  the MCP server through `codebase-memory-mcp-ds mcp`, and optionally removes
  an old upstream local install.
- `agent/skills/codebase-memory-ds/SKILL.md`: vendored agent skill text,
  renamed for this Docker edition.
- `agent/hooks/cbm-ds-code-discovery-gate`: Docker-aware PreToolUse hook that
  calls upstream `hook-augment` inside the container.
- `agent/hooks/cbm-ds-session-reminder`: vendored SessionStart reminder text.
- `LICENSE`: The Unlicense for this repository's original packaging work.
- `NOTICE`: attribution and license details for upstream and vendored content.

## License and Attribution

This repository is unofficial and is not affiliated with, sponsored by, or
endorsed by DeusData.

No copyright is claimed over the original packaging work in this repository. To
the extent possible under law, that original work is dedicated to the public
domain under The Unlicense.

The upstream project, vendored upstream text, and upstream release artifacts
remain under their original license and copyright:

- Upstream: <https://github.com/DeusData/codebase-memory-mcp>
- License: MIT
- Copyright: Copyright (c) 2025 DeusData

This repository does not redistribute the upstream binary. Docker build fetches
it from upstream GitHub Releases.
