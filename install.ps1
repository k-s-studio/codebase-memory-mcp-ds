# install.ps1 - codebase-memory-mcp-ds (Docker edition) installer for Windows.
#
# This is NOT the upstream installer. Upstream downloads a binary, drops it on
# PATH, and runs `<binary> install -y` to self-configure agents against that
# local binary. That approach cannot work for a containerized server (the
# binary's `install -y` writes the *container's* HOME and detects no host
# agents), so this script does the wiring itself, in PowerShell:
#
#   1. Get the repo (Dockerfile + compose). Either a local checkout next to this
#      script, or downloaded from GitHub.
#   2. `docker compose build` + `up -d`. The image fetches the upstream UI binary
#      at build time (see Dockerfile); no upstream binary is installed on the host.
#   3. Wire Claude Code / agents to the *container*:
#        - MCP server  -> `codebase-memory-mcp-ds mcp`
#        - PreToolUse hook (graph augment) -> routed through `docker exec`
#        - SessionStart reminder hook (static text)
#        - skill installed under the name `codebase-memory-ds`
#        - host wrapper command installed as `codebase-memory-mcp-ds`
#        - Codex: if ~/.codex exists, register the MCP server and a
#          SessionStart hook in ~/.codex/config.toml (mirrors upstream cli.c)
#   4. Preserve any upstream/local install by default. If you really want to
#      replace it, pass -RemoveLegacy to remove the legacy container, skill,
#      hooks, MCP entries, local .exe, and PATH entry.
#
# Docker and the host command use `codebase-memory-mcp-ds`; agent-facing skill,
# MCP server, and hook resources keep the shorter `codebase-memory-ds` /
# `cbm-ds-*` names so they remain distinct from upstream `codebase-memory-mcp`.
#
# Usage:
#   .\install.ps1                              # from a repo checkout, exposes C:/Workspace to Docker
#   .\install.ps1 -WorkspacePath C:/path/to/projects
#                                               # expose a different source root to Docker
#   .\install.ps1 -UiPort 9751                 # publish the UI on a specific host port
#   .\install.ps1 -RemoveLegacy                # remove the old upstream install
#   .\install.ps1 -SkipBuild                   # only (re)wire agents, don't touch docker
#   .\install.ps1 -Download                    # force download from GitHub even in a checkout

[CmdletBinding()]
param(
    [string]$WorkspacePath = "C:/Workspace",
    [string]$Version       = "latest",
    [ValidateRange(1, 65535)]
    [int]$UiPort           = 9749,
    [string]$Repo          = "k-s-studio/codebase-memory-mcp-ds",
    [string]$Branch        = "main",
    [string]$SourceDir,
    [switch]$Download,
    [switch]$SkipBuild,
    [switch]$SkipCleanup,
    [switch]$RemoveLegacy
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# ---- names (new, host-facing) ----
$ComposeProjectName = "codebase-memory-mcp-ds"
$ContainerName = "codebase-memory-mcp-ds"
$PreviousDsContainer = "codebase-memory-ds"
$BinInContainer = "codebase-memory-mcp"   # internal binary name inside the image (unchanged)
$McpName       = "codebase-memory-ds"
$SkillName     = "codebase-memory-ds"
$CliName       = "codebase-memory-mcp-ds"
$CliInstallDir = Join-Path $env:LOCALAPPDATA "Programs\codebase-memory-mcp-ds"
$CliConfigPath = Join-Path $CliInstallDir "config.json"

# ---- names (legacy upstream/local install; preserved unless -RemoveLegacy) ----
$OldContainer  = "codebase-memory-mcp"
$OldMcpName    = "codebase-memory-mcp"
$OldSkillName  = "codebase-memory"
$OldHookFiles  = @("cbm-code-discovery-gate", "cbm-session-reminder")
$OldExeDir     = Join-Path $env:LOCALAPPDATA "Programs\codebase-memory-mcp"
$OldVolumes    = @("cbm-cache", "codebase-memory-mcp-dockerservice_cbm-cache")
$DsHookCommandPatterns = @("*cbm-ds-code-discovery-gate*", "*cbm-ds-session-reminder*")
$LegacyHookCommandPatterns = @("*cbm-code-discovery-gate*", "*cbm-session-reminder*")

# ---- host config paths ----
$ClaudeDir   = Join-Path $env:USERPROFILE ".claude"
$McpJson     = Join-Path $ClaudeDir ".mcp.json"
$ClaudeJson  = Join-Path $env:USERPROFILE ".claude.json"
$SettingsJson= Join-Path $ClaudeDir "settings.json"
$SkillsDir   = Join-Path $ClaudeDir "skills"
$HooksDir    = Join-Path $ClaudeDir "hooks"

# ---- Codex host config (TOML; only wired when ~/.codex exists) ----
# Upstream registers Codex in ~/.codex/config.toml: an [mcp_servers.<name>] table
# plus a marker-wrapped [[hooks.SessionStart]] block. We mirror that flow but key
# the resources off the DS names so they stay distinct from an upstream install.
$CodexDir         = Join-Path $env:USERPROFILE ".codex"
$CodexConfigToml  = Join-Path $CodexDir "config.toml"
$CodexMcpSection  = "[mcp_servers.$McpName]"
$CodexHookBegin   = "# >>> $McpName SessionStart >>>"
$CodexHookEnd     = "# <<< $McpName SessionStart <<<"
$CodexReminderCmd = 'echo "Code discovery: prefer codebase-memory-ds tools (search_graph, trace_path, get_code_snippet, query_graph, search_code) over grep/file-read; run index_repository first if the project is not indexed."'
# legacy upstream Codex resources (removed only with -RemoveLegacy)
$OldCodexMcpSection = "[mcp_servers.$OldMcpName]"
$OldCodexHookBegin  = "# >>> $OldMcpName SessionStart >>>"
$OldCodexHookEnd    = "# <<< $OldMcpName SessionStart <<<"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Note { param($m) Write-Host "    $m" -ForegroundColor DarkGray }
function Write-Warn { param($m) Write-Host "    warning: $m" -ForegroundColor Yellow }

# ---------- JSON helpers (preserve no-BOM UTF-8; back up before writing) ----------
function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param([string]$Path, $Obj)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path $Path) {
        $bak = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $Path $bak -Force
        Write-Note "backed up $([System.IO.Path]::GetFileName($Path)) -> $([System.IO.Path]::GetFileName($bak))"
    }
    $json = $Obj | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

function Ensure-Prop {
    param($Obj, [string]$Name, $Default)
    if (-not ($Obj.PSObject.Properties.Name -contains $Name)) {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Default -Force
    }
}

# ---------- MCP wiring (small, well-formed files: .mcp.json) ----------
function Set-McpServer {
    param([string]$Path, [string]$Name, $Def, [switch]$Remove)
    $root = Read-JsonFile $Path
    if ($null -eq $root) {
        if ($Remove) { return }
        $root = [pscustomobject]@{}
    }
    Ensure-Prop $root 'mcpServers' ([pscustomobject]@{})
    $had = $root.mcpServers.PSObject.Properties.Name -contains $Name
    if ($had) { $root.mcpServers.PSObject.Properties.Remove($Name) }
    if ($Remove) {
        if (-not $had) { return }   # nothing changed, don't rewrite
    } else {
        $root.mcpServers | Add-Member -NotePropertyName $Name -NotePropertyValue $Def -Force
    }
    Write-JsonFile $Path $root
}

# ---------- MCP wiring (surgical, for ~/.claude.json) ----------
# ~/.claude.json cannot be round-tripped through ConvertFrom-Json: its `projects`
# map is keyed by absolute path and Windows produces case-variant duplicate keys
# (C:/... vs c:/...), which PowerShell's case-insensitive parser rejects. The file
# is still valid JSON (Claude Code's Go parser reads it fine), so we edit only the
# top-level "mcpServers" object in place and leave the rest of the bytes untouched.
function Find-TopLevelObjectValue {
    # Returns @{ valueStart; valueEnd } for the {...} value of a top-level key, or $null.
    param([string]$text, [string]$key)
    $n = $text.Length; $i = 0; $inStr = $false; $esc = $false; $depth = 0
    $keyTok = '"' + $key + '"'
    while ($i -lt $n) {
        $c = $text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            $i++; continue
        }
        if ($c -eq '"') {
            if ($depth -eq 1 -and ($i + $keyTok.Length) -le $n -and $text.Substring($i, $keyTok.Length) -eq $keyTok) {
                $j = $i + $keyTok.Length
                while ($j -lt $n -and [char]::IsWhiteSpace($text[$j])) { $j++ }
                if ($j -lt $n -and $text[$j] -eq ':') {
                    $j++
                    while ($j -lt $n -and [char]::IsWhiteSpace($text[$j])) { $j++ }
                    if ($j -lt $n -and $text[$j] -eq '{') {
                        $d2 = 0; $k = $j; $inS2 = $false; $esc2 = $false
                        while ($k -lt $n) {
                            $cc = $text[$k]
                            if ($inS2) {
                                if ($esc2) { $esc2 = $false } elseif ($cc -eq '\') { $esc2 = $true } elseif ($cc -eq '"') { $inS2 = $false }
                            } else {
                                if ($cc -eq '"') { $inS2 = $true }
                                elseif ($cc -eq '{') { $d2++ }
                                elseif ($cc -eq '}') { $d2--; if ($d2 -eq 0) { return @{ valueStart = $j; valueEnd = $k } } }
                            }
                            $k++
                        }
                    }
                }
            }
            $inStr = $true; $i++; continue
        }
        if ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') { $depth-- }
        $i++
    }
    return $null
}

function Set-McpServerSurgical {
    param([string]$Path, [string]$AddName, $AddDef, [string[]]$RemoveNames)
    if (-not (Test-Path $Path)) { return }
    $text = [System.IO.File]::ReadAllText($Path)
    $span = Find-TopLevelObjectValue $text 'mcpServers'
    if ($span) {
        $objText = $text.Substring($span.valueStart, $span.valueEnd - $span.valueStart + 1)
        $obj = $objText | ConvertFrom-Json
    } else {
        if (-not $AddName) { return }   # nothing to add and no block to clean
        $obj = [pscustomobject]@{}
    }
    $changed = $false
    foreach ($rn in $RemoveNames) {
        if ($obj.PSObject.Properties.Name -contains $rn) { $obj.PSObject.Properties.Remove($rn); $changed = $true }
    }
    if ($AddName) {
        if ($obj.PSObject.Properties.Name -contains $AddName) { $obj.PSObject.Properties.Remove($AddName) }
        $obj | Add-Member -NotePropertyName $AddName -NotePropertyValue $AddDef -Force
        $changed = $true
    }
    if (-not $changed) { return }
    $newObjText = $obj | ConvertTo-Json -Depth 100
    if ($span) {
        $newText = $text.Substring(0, $span.valueStart) + $newObjText + $text.Substring($span.valueEnd + 1)
    } else {
        $braceIdx = $text.IndexOf('{')
        if ($braceIdx -lt 0) { return }
        $sep = "`n  `"mcpServers`": " + $newObjText + ","
        $newText = $text.Substring(0, $braceIdx + 1) + $sep + $text.Substring($braceIdx + 1)
    }
    $bak = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $Path $bak -Force
    Write-Note "backed up $([System.IO.Path]::GetFileName($Path)) -> $([System.IO.Path]::GetFileName($bak))"
    [System.IO.File]::WriteAllText($Path, $newText, $Utf8NoBom)
}

# ---------- hook wiring (settings.json) ----------
function Remove-HookEntriesByCommandPattern {
    # Drop hook groups owned by this installer while preserving unrelated hooks,
    # including a separately installed upstream/local codebase-memory hook.
    param($Entries, [string[]]$Patterns)
    if (-not $Entries) { return @() }
    return @($Entries | Where-Object {
        $matched = $false
        foreach ($h in @($_.hooks)) {
            foreach ($pattern in $Patterns) {
                if ($h.command -like $pattern) { $matched = $true }
            }
        }
        -not $matched
    })
}

function Remove-RegisteredHooks {
    param([string]$Path, [string[]]$Patterns)
    $root = Read-JsonFile $Path
    if ($null -eq $root) { return }
    if (-not ($root.PSObject.Properties.Name -contains 'hooks')) { return }
    Ensure-Prop $root.hooks 'PreToolUse'   @()
    Ensure-Prop $root.hooks 'SessionStart' @()

    $oldPre = @($root.hooks.PreToolUse)
    $oldSs  = @($root.hooks.SessionStart)
    $pre = @(Remove-HookEntriesByCommandPattern -Entries $oldPre -Patterns $Patterns)
    $ss  = @(Remove-HookEntriesByCommandPattern -Entries $oldSs  -Patterns $Patterns)

    if (($pre.Count -eq $oldPre.Count) -and ($ss.Count -eq $oldSs.Count)) { return }
    $root.hooks.PreToolUse   = @($pre)
    $root.hooks.SessionStart = @($ss)
    Write-JsonFile $Path $root
}

function Wire-Hooks {
    param([string]$Path, [switch]$RemoveOnly)
    $root = Read-JsonFile $Path
    if ($null -eq $root) {
        if ($RemoveOnly) { return }
        $root = [pscustomobject]@{}
    }
    Ensure-Prop $root 'hooks' ([pscustomobject]@{})
    Ensure-Prop $root.hooks 'PreToolUse'   @()
    Ensure-Prop $root.hooks 'SessionStart' @()

    # @(...) guards against PowerShell collapsing an empty pipeline result to
    # $null (which would turn the first `+=` into a scalar assignment).
    $pre = @(Remove-HookEntriesByCommandPattern -Entries $root.hooks.PreToolUse -Patterns $DsHookCommandPatterns)
    $ss  = @(Remove-HookEntriesByCommandPattern -Entries $root.hooks.SessionStart -Patterns $DsHookCommandPatterns)

    if (-not $RemoveOnly) {
        $pre += [pscustomobject]@{
            matcher = "Grep|Glob"
            hooks   = @([pscustomobject]@{ type = "command"; command = "~/.claude/hooks/cbm-ds-code-discovery-gate"; timeout = 5 })
        }
        foreach ($m in @("startup", "resume", "clear", "compact")) {
            $ss += [pscustomobject]@{
                matcher = $m
                hooks   = @([pscustomobject]@{ type = "command"; command = "~/.claude/hooks/cbm-ds-session-reminder" })
            }
        }
    }

    $root.hooks.PreToolUse   = @($pre)
    $root.hooks.SessionStart = @($ss)
    Write-JsonFile $Path $root
}

# ---------- Codex wiring (~/.codex/config.toml, TOML; upstream-compatible) ----------
# Codex config is TOML, not JSON, so we edit only our own section/marker block in
# place and leave the rest of the file untouched (mirrors upstream's in-place
# splice in src/cli/cli.c).
function Remove-CodexMcpSection {
    # Strip "[mcp_servers.<name>]" and its body up to the next "[" header or EOF.
    param([string]$Text, [string]$Header)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $idx = $Text.IndexOf($Header)
    if ($idx -lt 0) { return $Text }
    $nextIdx = $Text.IndexOf("`n[", $idx + $Header.Length)
    $prefix = $Text.Substring(0, $idx).TrimEnd("`r", "`n")
    $suffix = if ($nextIdx -ge 0) { $Text.Substring($nextIdx + 1) } else { "" }
    if ($prefix -and $suffix) { return "$prefix`n$suffix" }
    return "$prefix$suffix"
}

function Remove-CodexHookBlock {
    # Strip everything from the begin marker through the end marker (inclusive).
    param([string]$Text, [string]$BeginMarker, [string]$EndMarker)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $b = $Text.IndexOf($BeginMarker)
    if ($b -lt 0) { return $Text }
    $e = $Text.IndexOf($EndMarker, $b)
    if ($e -lt 0) { return $Text }   # malformed/half-written; leave as-is
    $prefix = $Text.Substring(0, $b).TrimEnd("`r", "`n")
    $suffix = $Text.Substring($e + $EndMarker.Length).TrimStart("`r", "`n")
    if ($prefix -and $suffix) { return "$prefix`n$suffix" }
    return "$prefix$suffix"
}

function Wire-Codex {
    param([switch]$RemoveOnly)
    # Detection mirrors upstream: only touch Codex if the user actually has ~/.codex.
    if (-not (Test-Path $CodexDir)) {
        if (-not $RemoveOnly) { Write-Note "Codex not detected (~/.codex absent); skipping Codex wiring" }
        return
    }
    if ($RemoveOnly -and -not (Test-Path $CodexConfigToml)) { return }
    $text = if (Test-Path $CodexConfigToml) { [System.IO.File]::ReadAllText($CodexConfigToml) } else { "" }
    $orig = $text

    # Always strip our own entries first (idempotent upsert / clean removal).
    $text = Remove-CodexHookBlock  -Text $text -BeginMarker $CodexHookBegin -EndMarker $CodexHookEnd
    $text = Remove-CodexMcpSection -Text $text -Header $CodexMcpSection

    if (-not $RemoveOnly) {
        # TOML basic string for the path: double every backslash ("\" is an escape).
        $cmdEscaped = (Join-Path $CliInstallDir "$CliName.cmd") -replace '\\', '\\'
        $mcpBlock = @(
            $CodexMcpSection
            "command = `"$cmdEscaped`""
            'args = ["mcp"]'
        ) -join "`n"
        # Hook command uses a TOML literal string ('...') so the inner double
        # quotes in the echo need no escaping (matches upstream's '%s').
        $hookBlock = @(
            $CodexHookBegin
            '[[hooks.SessionStart]]'
            'matcher = "startup|resume|clear|compact"'
            ''
            '[[hooks.SessionStart.hooks]]'
            'type = "command"'
            "command = '$CodexReminderCmd'"
            $CodexHookEnd
        ) -join "`n"

        $text = $text.TrimEnd("`r", "`n")
        $sep = if ($text) { "`n`n" } else { "" }
        $text = "$text$sep$mcpBlock`n`n$hookBlock`n"
    }

    if ($text -eq $orig) { return }   # nothing changed, don't rewrite
    if (Test-Path $CodexConfigToml) {
        $bak = "$CodexConfigToml.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $CodexConfigToml $bak -Force
        Write-Note "backed up config.toml -> $([System.IO.Path]::GetFileName($bak))"
    }
    [System.IO.File]::WriteAllText($CodexConfigToml, $text, $Utf8NoBom)
}

function Remove-CodexLegacy {
    # Strip an upstream/local install's Codex entries (only under -RemoveLegacy).
    if (-not (Test-Path $CodexConfigToml)) { return }
    $text = [System.IO.File]::ReadAllText($CodexConfigToml)
    $orig = $text
    $text = Remove-CodexHookBlock  -Text $text -BeginMarker $OldCodexHookBegin -EndMarker $OldCodexHookEnd
    $text = Remove-CodexMcpSection -Text $text -Header $OldCodexMcpSection
    if ($text -eq $orig) { return }
    $bak = "$CodexConfigToml.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $CodexConfigToml $bak -Force
    Write-Note "backed up config.toml -> $([System.IO.Path]::GetFileName($bak))"
    [System.IO.File]::WriteAllText($CodexConfigToml, $text, $Utf8NoBom)
    Write-Note "removed legacy Codex MCP/hook entries from config.toml"
}

# ---------- docker helpers ----------
function Test-Container { param([string]$Name) return [bool](docker ps -aq -f "name=^$Name$") }
function Test-ContainerRunning { param([string]$Name) return [bool](docker ps -q -f "name=^$Name$") }

function Get-ContainerPublishedPort {
    param([string]$Name, [int]$ContainerPort)
    try {
        $published = docker port $Name "$ContainerPort/tcp" 2>$null | Select-Object -First 1
        if ($published -match ':(\d+)$') { return [int]$Matches[1] }
    } catch {
        return $null
    }
    return $null
}

function Test-TcpPortAvailable {
    param([int]$Port)
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { $listener.Stop() }
    }
}

function Resolve-UiHostPort {
    param(
        [int]$PreferredPort,
        $ExistingDsPort,
        [bool]$AllowFallback
    )
    if (($null -ne $ExistingDsPort) -and ([int]$ExistingDsPort -eq $PreferredPort)) {
        return $PreferredPort
    }
    if (Test-TcpPortAvailable $PreferredPort) {
        return $PreferredPort
    }
    if (-not $AllowFallback) {
        throw "host UI port $PreferredPort is already in use. Choose another port with -UiPort or stop the process using it."
    }

    for ($candidate = $PreferredPort + 1; $candidate -le 65535 -and $candidate -le ($PreferredPort + 100); $candidate++) {
        if (Test-TcpPortAvailable $candidate) {
            return $candidate
        }
    }
    throw "could not find a free UI host port near $PreferredPort. Pass -UiPort with an available port."
}

function Test-HttpEndpoint {
    param([string]$Url)
    try {
        Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

# ============================================================
if ($SkipCleanup) { $RemoveLegacy = $false }
$uiPortWasSpecified = $PSBoundParameters.ContainsKey('UiPort')
$resolvedUiPort = $UiPort
$legacyMode = if ($RemoveLegacy) { "remove upstream/local install" } else { "preserve upstream/local install" }

Write-Host ""
Write-Host "codebase-memory-mcp-ds installer (Docker edition)" -ForegroundColor Green
Write-Host "  compose   : $ComposeProjectName"
Write-Host "  container : $ContainerName"
Write-Host "  version   : $Version  (upstream release fetched at build time)"
Write-Host "  workspace : $WorkspacePath  (mounted read-only at /workspace)"
Write-Host "  UI port   : $UiPort"
Write-Host "  legacy    : $legacyMode"
Write-Host ""
if ($SkipCleanup) { Write-Warn "-SkipCleanup is deprecated; legacy installs are preserved unless -RemoveLegacy is set." }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found on PATH. Install Docker Desktop and retry."
}

# ---------- 1. resolve source dir ----------
$src = $null
$downloadedSource = $false
if ($SourceDir) {
    $src = (Resolve-Path $SourceDir).Path
} elseif ((-not $Download) -and $PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "docker-compose.yml"))) {
    $src = $PSScriptRoot
    Write-Step "Using local checkout: $src"
} else {
    Write-Step "Downloading $Repo@$Branch ..."
    $tmp = Join-Path $env:TEMP "cbm-ds-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp "repo.zip"
    Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $extracted = Get-ChildItem -Path $tmp -Directory | Where-Object { $_.Name -like "codebase-memory-mcp-ds-*" } | Select-Object -First 1
    if (-not $extracted) { throw "could not find extracted repo directory under $tmp" }
    $src = $extracted.FullName
    $downloadedSource = $true
}
if ($downloadedSource) {
    $stableSrc = Join-Path $CliInstallDir "source"
    New-Item -ItemType Directory -Path $CliInstallDir -Force | Out-Null
    if (Test-Path $stableSrc) { Remove-Item $stableSrc -Recurse -Force }
    Copy-Item $src $stableSrc -Recurse -Force
    $src = $stableSrc
    Write-Note "cached source for future update/start commands: $src"
}
Write-Note "source: $src"

$skillSrc = Join-Path $src "agent\skills\$SkillName"
$hookSrc  = Join-Path $src "agent\hooks"
$binSrc   = Join-Path $src "bin"
foreach ($p in @($skillSrc, (Join-Path $hookSrc "cbm-ds-code-discovery-gate"), (Join-Path $hookSrc "cbm-ds-session-reminder"), (Join-Path $binSrc "$CliName.ps1"), (Join-Path $binSrc "$CliName.cmd"))) {
    if (-not (Test-Path $p)) { throw "missing required file in source: $p" }
}

# ---------- 2. build + up ----------
if (-not $SkipBuild) {
    if ($PreviousDsContainer -ne $ContainerName -and (Test-Container $PreviousDsContainer)) {
        Write-Step "Removing previous DS container '$PreviousDsContainer' (renamed to '$ContainerName')"
        docker rm -f $PreviousDsContainer | Out-Null
    }

    if ($RemoveLegacy -and (Test-Container $OldContainer)) {
        Write-Step "Removing legacy container '$OldContainer'"
        docker rm -f $OldContainer | Out-Null
    } elseif (Test-Container $OldContainer) {
        Write-Note "legacy container '$OldContainer' preserved; selecting a non-conflicting UI port if needed"
    }

    $existingDsUiPort = Get-ContainerPublishedPort -Name $ContainerName -ContainerPort 9749
    $canReuseExistingDsPort = $existingDsUiPort -and (
        (Test-ContainerRunning $ContainerName) -or
        (Test-TcpPortAvailable $existingDsUiPort)
    )
    if ((-not $uiPortWasSpecified) -and $canReuseExistingDsPort) {
        $resolvedUiPort = $existingDsUiPort
        Write-Note "reusing existing UI host port $resolvedUiPort"
    } else {
        $resolvedUiPort = Resolve-UiHostPort -PreferredPort $UiPort -ExistingDsPort $existingDsUiPort -AllowFallback $(-not $uiPortWasSpecified)
        if ($resolvedUiPort -ne $UiPort) {
            Write-Warn "host UI port $UiPort is unavailable; using $resolvedUiPort instead"
        }
    }

    Write-Step "docker compose build (fetches upstream UI binary, version=$Version)"
    Push-Location $src
    try {
        $oldComposeProjectName = $env:COMPOSE_PROJECT_NAME
        $env:CBM_WORKSPACE = $WorkspacePath
        $env:CBM_UI_PORT = [string]$resolvedUiPort
        $env:COMPOSE_PROJECT_NAME = $ComposeProjectName
        docker compose build --build-arg CBM_VERSION=$Version
        if ($LASTEXITCODE -ne 0) { throw "docker compose build failed" }
        Write-Step "docker compose up -d (UI host port=$resolvedUiPort)"
        docker compose up -d
        if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }
    } finally {
        $env:COMPOSE_PROJECT_NAME = $oldComposeProjectName
        Pop-Location
    }

    # brief readiness check
    Start-Sleep -Seconds 2
    if (-not (docker ps -q -f "name=^$ContainerName$")) {
        Write-Warn "container '$ContainerName' is not running yet; check 'docker logs $ContainerName'"
    } else {
        Write-Note "container '$ContainerName' is up (UI on http://localhost:$resolvedUiPort)"
    }
} else {
    Write-Step "Skipping docker build/up (-SkipBuild)"
    $existingDsUiPort = Get-ContainerPublishedPort -Name $ContainerName -ContainerPort 9749
    if ($existingDsUiPort) { $resolvedUiPort = $existingDsUiPort }
}

# ---------- 3. wire agents on the host ----------
Write-Step "Installing skill -> $SkillsDir\$SkillName"
$skillDst = Join-Path $SkillsDir $SkillName
if (Test-Path $skillDst) { Remove-Item $skillDst -Recurse -Force }
New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null
Copy-Item $skillSrc $skillDst -Recurse -Force

Write-Step "Installing hooks -> $HooksDir"
New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null
Copy-Item (Join-Path $hookSrc "cbm-ds-code-discovery-gate") $HooksDir -Force
Copy-Item (Join-Path $hookSrc "cbm-ds-session-reminder")    $HooksDir -Force

Write-Step "Registering hooks in settings.json"
Wire-Hooks -Path $SettingsJson

Write-Step "Installing host command -> $CliInstallDir\$CliName.cmd"
New-Item -ItemType Directory -Path $CliInstallDir -Force | Out-Null
Copy-Item (Join-Path $binSrc "$CliName.ps1") $CliInstallDir -Force
Copy-Item (Join-Path $binSrc "$CliName.cmd") $CliInstallDir -Force
$cliConfig = [pscustomobject]@{
    containerName      = $ContainerName
    composeProjectName = $ComposeProjectName
    imageName          = "codebase-memory-mcp-ds:ui-local"
    binInContainer     = $BinInContainer
    composeDir         = $src
    workspaceHost      = $WorkspacePath
    workspaceContainer = "/workspace"
    uiHostPort         = $resolvedUiPort
    mcpName            = $McpName
    skillName          = $SkillName
    installDir         = $CliInstallDir
}
Write-JsonFile $CliConfigPath $cliConfig

$userPathForCli = [Environment]::GetEnvironmentVariable("PATH", "User")
if (-not $userPathForCli) { $userPathForCli = "" }
if (($userPathForCli -split ';') -notcontains $CliInstallDir) {
    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPathForCli)) { $CliInstallDir } else { "$userPathForCli;$CliInstallDir" }
    [Environment]::SetEnvironmentVariable("PATH", $newUserPath, "User")
    Write-Note "added $CliInstallDir to user PATH"
}
if (($env:PATH -split ';') -notcontains $CliInstallDir) {
    $env:PATH = "$env:PATH;$CliInstallDir"
}

$mcpDef = [pscustomobject]@{
    command = (Join-Path $CliInstallDir "$CliName.cmd")
    args    = @("mcp")
}
Write-Step "Wiring MCP server '$McpName' -> $CliName mcp"
Set-McpServer         -Path $McpJson    -Name $McpName -Def $mcpDef
Set-McpServerSurgical -Path $ClaudeJson -AddName $McpName -AddDef $mcpDef

Write-Step "Wiring Codex MCP/hook in ~/.codex/config.toml (if Codex is installed)"
Wire-Codex

# ---------- 4. optional legacy upstream/local cleanup ----------
if ($RemoveLegacy) {
    Write-Step "Removing legacy upstream/local install (-RemoveLegacy)"

    if (Test-Container $OldContainer) {
        docker rm -f $OldContainer | Out-Null
        Write-Note "removed container '$OldContainer'"
    }
    foreach ($v in $OldVolumes) {
        if (docker volume ls -q -f "name=^$v$") { docker volume rm $v | Out-Null; Write-Note "removed volume '$v'" }
    }

    $oldSkill = Join-Path $SkillsDir $OldSkillName
    if (Test-Path $oldSkill) { Remove-Item $oldSkill -Recurse -Force; Write-Note "removed skill '$OldSkillName'" }

    foreach ($h in $OldHookFiles) {
        $p = Join-Path $HooksDir $h
        if (Test-Path $p) { Remove-Item $p -Force; Write-Note "removed hook '$h'" }
    }
    Remove-RegisteredHooks -Path $SettingsJson -Patterns $LegacyHookCommandPatterns

    Set-McpServer         -Path $McpJson    -Name $OldMcpName -Remove
    Set-McpServerSurgical -Path $ClaudeJson -RemoveNames @($OldMcpName)
    Remove-CodexLegacy

    $oldExeRemoved = $true
    if (Test-Path $OldExeDir) {
        try {
            Remove-Item $OldExeDir -Recurse -Force -ErrorAction Stop
            Write-Note "removed local exe dir $OldExeDir"
        } catch {
            $oldExeRemoved = $false
            Write-Warn "could not remove local exe dir $OldExeDir; close running processes and remove it manually if desired. $($_.Exception.Message)"
        }
    }

    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($oldExeRemoved -and $userPath -and $userPath -like "*$OldExeDir*") {
        $newPath = ($userPath -split ';' | Where-Object { $_ -and ($_ -ne $OldExeDir) }) -join ';'
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Note "removed old exe dir from user PATH"
    }
} else {
    Write-Step "Preserving legacy upstream/local install"
    Write-Note "pass -RemoveLegacy to remove old codebase-memory-mcp resources"
}

# ---------- done + post-install check ----------
$publishedUiPort = Get-ContainerPublishedPort -Name $ContainerName -ContainerPort 9749
if ($publishedUiPort) { $resolvedUiPort = $publishedUiPort }
$uiUrl = "http://localhost:$resolvedUiPort"
$containerExists = Test-Container $ContainerName
$containerRunning = Test-ContainerRunning $ContainerName
$skillInstalled = Test-Path $skillDst
$hooksInstalled = (Test-Path (Join-Path $HooksDir "cbm-ds-code-discovery-gate")) -and (Test-Path (Join-Path $HooksDir "cbm-ds-session-reminder"))
$cliInstalled = (Test-Path (Join-Path $CliInstallDir "$CliName.cmd")) -and (Test-Path $CliConfigPath)
$codexPresent = Test-Path $CodexDir
$codexConfigured = $codexPresent -and (Test-Path $CodexConfigToml) -and ([System.IO.File]::ReadAllText($CodexConfigToml) -like "*$CodexMcpSection*")

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Post-install check:" -ForegroundColor Cyan
if ($containerRunning) {
    Write-Host "  [ok] container '$ContainerName' is running"
} elseif ($containerExists) {
    Write-Warn "container '$ContainerName' exists but is not running; check: docker logs $ContainerName"
} else {
    Write-Warn "container '$ContainerName' was not found"
}

if ($publishedUiPort) {
    Write-Host "  [ok] UI published on host port $publishedUiPort"
} else {
    Write-Warn "UI port mapping was not found; check: docker port $ContainerName"
}

if ($containerRunning -and $publishedUiPort -and (Test-HttpEndpoint $uiUrl)) {
    Write-Host "  [ok] UI responds at $uiUrl"
} elseif ($containerRunning -and $publishedUiPort) {
    Write-Warn "UI did not respond yet at $uiUrl; it may still be starting"
}

if ($skillInstalled -and $hooksInstalled) {
    Write-Host "  [ok] skill and hooks installed"
} else {
    Write-Warn "skill or hooks are missing; rerun this installer"
}
if ($cliInstalled) {
    Write-Host "  [ok] command '$CliName' installed"
} else {
    Write-Warn "host command '$CliName' is missing; rerun this installer"
}
if ($codexPresent) {
    if ($codexConfigured) {
        Write-Host "  [ok] Codex MCP/hook registered in ~/.codex/config.toml"
    } else {
        Write-Warn "Codex detected but MCP entry is missing; rerun this installer"
    }
}

Write-Host ""
Write-Host "Port information:" -ForegroundColor Cyan
Write-Host "  - 3D graph UI URL : $uiUrl"
Write-Host "  - Host UI port    : $resolvedUiPort"
Write-Host "  - Container port  : 9749/tcp"
Write-Host "  - Internal UI port: 9750/tcp inside the container"
Write-Host "  - MCP transport   : stdio via $CliName mcp (no host TCP port)"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  - Restart Claude Code so it reloads skills / hooks / MCP config."
Write-Host "  - Restart this terminal if '$CliName' is not found on PATH yet."
Write-Host "  - Useful commands: $CliName status, $CliName ui, $CliName index C:\path\to\repo"
Write-Host "  - The container starts with an EMPTY index. Re-index your repos, e.g.:"
Write-Host "      ask the agent to run index_repository(repo_path=\"/workspace/<your-project>\")"
Write-Host ""
