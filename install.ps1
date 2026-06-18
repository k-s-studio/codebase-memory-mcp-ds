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
#      at build time (see Dockerfile); nothing is installed on the host.
#   3. Wire Claude Code / agents to the *container*:
#        - MCP server  -> `docker exec -i codebase-memory-ds codebase-memory-mcp --ui=false`
#        - PreToolUse hook (graph augment) -> routed through `docker exec`
#        - SessionStart reminder hook (static text)
#        - skill installed under the name `codebase-memory-ds`
#   4. (default) Remove the old upstream local install: container, skill, hooks,
#      MCP entries, the local .exe, PATH entry. Disable with -SkipCleanup.
#
# Everything host-facing is namespaced `codebase-memory-ds` / `cbm-ds-*` so it
# coexists with (or cleanly replaces) an upstream local install.
#
# Usage:
#   .\install.ps1                              # from a repo checkout, exposes C:/Workspace to Docker
#   .\install.ps1 -WorkspacePath C:/path/to/projects
#                                               # expose a different source root to Docker
#   .\install.ps1 -SkipCleanup                 # keep the old upstream install
#   .\install.ps1 -SkipBuild                   # only (re)wire agents, don't touch docker
#   .\install.ps1 -Download                    # force download from GitHub even in a checkout

[CmdletBinding()]
param(
    [string]$WorkspacePath = "C:/Workspace",
    [string]$Version       = "latest",
    [string]$Repo          = "k-s-studio/codebase-memory-mcp-ds",
    [string]$Branch        = "main",
    [string]$SourceDir,
    [switch]$Download,
    [switch]$SkipBuild,
    [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# ---- names (new, host-facing) ----
$ContainerName = "codebase-memory-ds"
$BinInContainer = "codebase-memory-mcp"   # internal binary name inside the image (unchanged)
$McpName       = "codebase-memory-ds"
$SkillName     = "codebase-memory-ds"

# ---- names (old, upstream local install — cleanup targets) ----
$OldContainer  = "codebase-memory-mcp"
$OldMcpName    = "codebase-memory-mcp"
$OldSkillName  = "codebase-memory"
$OldHookFiles  = @("cbm-code-discovery-gate", "cbm-session-reminder")
$OldExeDir     = Join-Path $env:LOCALAPPDATA "Programs\codebase-memory-mcp"
$OldVolumes    = @("cbm-cache", "codebase-memory-mcp-dockerservice_cbm-cache")

# ---- host config paths ----
$ClaudeDir   = Join-Path $env:USERPROFILE ".claude"
$McpJson     = Join-Path $ClaudeDir ".mcp.json"
$ClaudeJson  = Join-Path $env:USERPROFILE ".claude.json"
$SettingsJson= Join-Path $ClaudeDir "settings.json"
$SkillsDir   = Join-Path $ClaudeDir "skills"
$HooksDir    = Join-Path $ClaudeDir "hooks"

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
function Remove-CbmHookEntries {
    # drop any hook-group whose command points at a cbm-* script (old or ds);
    # preserves the user's own unrelated hooks.
    param($arr)
    if (-not $arr) { return @() }
    return @($arr | Where-Object {
        $hasCbm = $false
        foreach ($h in @($_.hooks)) { if ($h.command -like "*cbm-*") { $hasCbm = $true } }
        -not $hasCbm
    })
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
    $pre = @(Remove-CbmHookEntries $root.hooks.PreToolUse)
    $ss  = @(Remove-CbmHookEntries $root.hooks.SessionStart)

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

# ---------- docker helpers ----------
function Test-Container { param([string]$Name) return [bool](docker ps -aq -f "name=^$Name$") }

# ============================================================
Write-Host ""
Write-Host "codebase-memory-mcp-ds installer (Docker edition)" -ForegroundColor Green
Write-Host "  container : $ContainerName"
Write-Host "  version   : $Version  (upstream release fetched at build time)"
Write-Host "  workspace : $WorkspacePath  (mounted read-only at /workspace)"
Write-Host "  cleanup   : $((-not $SkipCleanup))"
Write-Host ""

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found on PATH. Install Docker Desktop and retry."
}

# ---------- 1. resolve source dir ----------
$src = $null
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
}
Write-Note "source: $src"

$skillSrc = Join-Path $src "agent\skills\$SkillName"
$hookSrc  = Join-Path $src "agent\hooks"
foreach ($p in @($skillSrc, (Join-Path $hookSrc "cbm-ds-code-discovery-gate"), (Join-Path $hookSrc "cbm-ds-session-reminder"))) {
    if (-not (Test-Path $p)) { throw "missing required file in source: $p" }
}

# ---------- 2. build + up ----------
if (-not $SkipBuild) {
    # Free port 9749 first: the old container binds it and would block `up`.
    if (Test-Container $OldContainer) {
        Write-Step "Stopping old container '$OldContainer' (frees port 9749)"
        if ($SkipCleanup) { docker stop $OldContainer | Out-Null }
        else              { docker rm -f $OldContainer | Out-Null }
    }

    Write-Step "docker compose build (fetches upstream UI binary, version=$Version)"
    Push-Location $src
    try {
        $env:CBM_WORKSPACE = $WorkspacePath
        docker compose build --build-arg CBM_VERSION=$Version
        if ($LASTEXITCODE -ne 0) { throw "docker compose build failed" }
        Write-Step "docker compose up -d"
        docker compose up -d
        if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }
    } finally {
        Pop-Location
    }

    # brief readiness check
    Start-Sleep -Seconds 2
    if (-not (docker ps -q -f "name=^$ContainerName$")) {
        Write-Warn "container '$ContainerName' is not running yet; check 'docker logs $ContainerName'"
    } else {
        Write-Note "container '$ContainerName' is up (UI on http://localhost:9749)"
    }
} else {
    Write-Step "Skipping docker build/up (-SkipBuild)"
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

$mcpDef = [pscustomobject]@{
    command = "docker"
    args    = @("exec", "-i", $ContainerName, $BinInContainer, "--ui=false")
}
Write-Step "Wiring MCP server '$McpName' -> docker exec"
Set-McpServer         -Path $McpJson    -Name $McpName -Def $mcpDef
Set-McpServerSurgical -Path $ClaudeJson -AddName $McpName -AddDef $mcpDef

# ---------- 4. cleanup old upstream install ----------
if (-not $SkipCleanup) {
    Write-Step "Removing old upstream install"

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

    # old MCP entries (filter in Wire-Hooks already dropped old hook *registrations*)
    Set-McpServer         -Path $McpJson    -Name $OldMcpName -Remove
    Set-McpServerSurgical -Path $ClaudeJson -RemoveNames @($OldMcpName)

    if (Test-Path $OldExeDir) { Remove-Item $OldExeDir -Recurse -Force; Write-Note "removed local exe dir $OldExeDir" }

    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -and $userPath -like "*$OldExeDir*") {
        $newPath = ($userPath -split ';' | Where-Object { $_ -and ($_ -ne $OldExeDir) }) -join ';'
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Note "removed old exe dir from user PATH"
    }
} else {
    Write-Step "Skipping cleanup (-SkipCleanup): old upstream install left in place"
}

# ---------- done ----------
Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  - Restart Claude Code so it reloads skills / hooks / MCP config."
Write-Host "  - The container starts with an EMPTY index. Re-index your repos, e.g.:"
Write-Host "      ask the agent to run index_repository(repo_path=\"/workspace/<your-project>\")"
Write-Host "  - 3D graph UI: http://localhost:9749"
Write-Host ""
