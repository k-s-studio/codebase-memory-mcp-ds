$ErrorActionPreference = "Stop"

$WrapperVersion = "0.1.0"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.json"

function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Load-Config {
    $defaults = [pscustomobject]@{
        containerName      = "codebase-memory-ds"
        imageName          = "codebase-memory-ds:ui-local"
        binInContainer     = "codebase-memory-mcp"
        composeDir         = ""
        workspaceHost      = "C:/Workspace"
        workspaceContainer = "/workspace"
        uiHostPort         = 9749
        mcpName            = "codebase-memory-ds"
        skillName          = "codebase-memory-ds"
        installDir         = $ScriptDir
    }
    if (-not (Test-Path $ConfigPath)) { return $defaults }
    try {
        $cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
        foreach ($p in $defaults.PSObject.Properties) {
            if (-not ($cfg.PSObject.Properties.Name -contains $p.Name)) {
                $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
        }
        return $cfg
    } catch {
        Write-Err "warning: could not read $ConfigPath; using defaults. $($_.Exception.Message)"
        return $defaults
    }
}

$Cfg = Load-Config

function Show-Help {
    @"
codebase-memory-mcp-ds $WrapperVersion

Usage:
  codebase-memory-mcp-ds <command> [args]

Commands:
  mcp                         Run MCP stdio server through docker exec
  cli <tool> [json]           Run one MCP tool once
  index <host-or-/workspace>  Index a repository path
  projects                    List indexed projects
  status                      Show container, UI, workspace, and command status
  doctor                      Run status checks with suggested fixes
  ui                          Print the graph UI URL
  port                        Print host/container/internal port mapping
  logs [-f] [docker args]     Show container logs
  start                       Start the DS container/UI service
  stop                        Stop the DS container/UI service
  restart                     Restart the DS container/UI service
  config <list|get|set|reset> Manage upstream runtime config in the Docker volume
  version                     Show wrapper and upstream versions
  update [version]            DS update: rebuild/up the Docker image
  uninstall [-y] [--volumes] [--image] [--keep-cli]
                              DS uninstall: remove DS resources only
  hook-augment                Internal hook command
  help                        Show this help

Not supported here:
  install                     Use install.ps1 on the host
  --ui=true / --port=N        UI is managed by Docker compose/install.ps1
"@
}

function Require-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "docker not found on PATH. Install Docker Desktop and retry."
    }
}

function Test-Container {
    param([string]$Name = $Cfg.containerName)
    Require-Docker
    try {
        return [bool](docker ps -aq -f "name=^$Name$" 2>$null)
    } catch {
        return $false
    }
}

function Test-ContainerRunning {
    param([string]$Name = $Cfg.containerName)
    Require-Docker
    try {
        return [bool](docker ps -q -f "name=^$Name$" 2>$null)
    } catch {
        return $false
    }
}

function Get-PublishedUiPort {
    try {
        $published = docker port $Cfg.containerName "9749/tcp" 2>$null | Select-Object -First 1
        if ($published -match ':(\d+)$') { return [int]$Matches[1] }
    } catch {
        return $null
    }
    return $null
}

function Get-UiPort {
    $published = Get-PublishedUiPort
    if ($published) { return $published }
    return [int]$Cfg.uiHostPort
}

function Get-UiUrl {
    return "http://localhost:$(Get-UiPort)"
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

function Invoke-InContainer {
    param([string[]]$ArgsForBinary)
    Require-Docker
    & docker exec -i $Cfg.containerName $Cfg.binInContainer @ArgsForBinary
    exit $LASTEXITCODE
}

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    Require-Docker
    if (-not $Cfg.composeDir -or -not (Test-Path $Cfg.composeDir)) {
        throw "compose directory is not available in config. Re-run install.ps1."
    }

    $oldWorkspace = $env:CBM_WORKSPACE
    $oldUiPort = $env:CBM_UI_PORT
    try {
        $env:CBM_WORKSPACE = $Cfg.workspaceHost
        $env:CBM_UI_PORT = [string](Get-UiPort)
        Push-Location $Cfg.composeDir
        try {
            & docker compose @ComposeArgs
            return $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } finally {
        $env:CBM_WORKSPACE = $oldWorkspace
        $env:CBM_UI_PORT = $oldUiPort
    }
}

function Convert-ToContainerPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "missing path" }
    if ($Path -like "/workspace" -or $Path -like "/workspace/*") { return $Path }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $workspace = (Resolve-Path -LiteralPath $Cfg.workspaceHost).Path
    $resolvedFull = [System.IO.Path]::GetFullPath($resolved).TrimEnd('\')
    $workspaceFull = [System.IO.Path]::GetFullPath($workspace).TrimEnd('\')

    $isWorkspaceRoot = $resolvedFull.Equals($workspaceFull, [System.StringComparison]::OrdinalIgnoreCase)
    $workspacePrefix = $workspaceFull + [System.IO.Path]::DirectorySeparatorChar
    $isWorkspaceChild = $resolvedFull.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isWorkspaceRoot -and -not $isWorkspaceChild) {
        throw "path is outside configured workspace '$($Cfg.workspaceHost)': $Path"
    }

    $rel = if ($isWorkspaceRoot) { "" } else { $resolvedFull.Substring($workspaceFull.Length).TrimStart('\', '/') }
    $rel = $rel -replace '\\', '/'
    if ([string]::IsNullOrWhiteSpace($rel)) { return $Cfg.workspaceContainer }
    return ($Cfg.workspaceContainer.TrimEnd('/') + "/" + $rel)
}

function Invoke-Tool {
    param([string]$Tool, [string]$Json = "{}")
    Invoke-InContainer -ArgsForBinary @("cli", $Tool, $Json)
}

function Remove-McpServerFromJson {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) { return }
    try {
        $root = Get-Content -Raw -Path $Path | ConvertFrom-Json
        if (-not $root -or -not ($root.PSObject.Properties.Name -contains "mcpServers")) { return }
        if (-not ($root.mcpServers.PSObject.Properties.Name -contains $Name)) { return }
        $root.mcpServers.PSObject.Properties.Remove($Name)
        $bak = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $Path $bak -Force
        $root | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding UTF8
        Write-Host "removed MCP server '$Name' from $Path"
    } catch {
        Write-Err "warning: could not update $Path. $($_.Exception.Message)"
    }
}

function Remove-PathEntry {
    param([string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $userPath) { return }
    $parts = @($userPath -split ';' | Where-Object {
        $_ -and ($_ -ne $Dir)
    })
    $newPath = $parts -join ';'
    if ($newPath -ne $userPath) {
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Host "removed $Dir from user PATH"
    }
}

function Remove-DsHookRegistrations {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        $root = Get-Content -Raw -Path $Path | ConvertFrom-Json
        if (-not $root -or -not ($root.PSObject.Properties.Name -contains "hooks")) { return }
        foreach ($name in @("PreToolUse", "SessionStart")) {
            if (-not ($root.hooks.PSObject.Properties.Name -contains $name)) { continue }
            $oldEntries = @($root.hooks.$name)
            $newEntries = @($oldEntries | Where-Object {
                $ownedByDs = $false
                foreach ($h in @($_.hooks)) {
                    if ($h.command -like "*cbm-ds-code-discovery-gate*" -or
                        $h.command -like "*cbm-ds-session-reminder*") {
                        $ownedByDs = $true
                    }
                }
                -not $ownedByDs
            })
            $root.hooks.$name = @($newEntries)
        }
        $bak = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $Path $bak -Force
        $root | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding UTF8
        Write-Host "removed DS hook registrations from $Path"
    } catch {
        Write-Err "warning: could not update hook registrations in $Path. $($_.Exception.Message)"
    }
}

function Show-Status {
    param([switch]$Doctor)
    Require-Docker
    $running = Test-ContainerRunning
    $exists = Test-Container
    $port = Get-PublishedUiPort
    $url = Get-UiUrl
    $workspaceOk = $Cfg.workspaceHost -and (Test-Path $Cfg.workspaceHost)
    $composeOk = $Cfg.composeDir -and (Test-Path $Cfg.composeDir)
    $pathHasCommand = (($env:PATH -split ';') -contains $ScriptDir)

    Write-Host "codebase-memory-mcp-ds status"
    Write-Host "  config      : $ConfigPath"
    Write-Host "  container   : $($Cfg.containerName)"
    Write-Host "  image       : $($Cfg.imageName)"
    Write-Host "  workspace   : $($Cfg.workspaceHost) -> $($Cfg.workspaceContainer)"
    Write-Host "  compose dir : $($Cfg.composeDir)"
    Write-Host "  UI URL      : $url"
    Write-Host ""

    if ($exists) { Write-Host "  [ok] container exists" } else { Write-Host "  [warn] container does not exist" }
    if ($running) { Write-Host "  [ok] container is running" } else { Write-Host "  [warn] container is not running" }
    if ($port) { Write-Host "  [ok] UI published on host port $port" } else { Write-Host "  [warn] UI port mapping not found" }
    if ($running -and $port -and (Test-HttpEndpoint $url)) { Write-Host "  [ok] UI responds" } elseif ($running -and $port) { Write-Host "  [warn] UI is not responding yet" }
    if ($workspaceOk) { Write-Host "  [ok] workspace path exists" } else { Write-Host "  [warn] workspace path is missing" }
    if ($composeOk) { Write-Host "  [ok] compose dir exists" } else { Write-Host "  [warn] compose dir is missing" }
    if ($pathHasCommand) { Write-Host "  [ok] current shell PATH includes wrapper dir" } else { Write-Host "  [warn] current shell PATH may need restart to include wrapper dir" }

    if ($Doctor) {
        Write-Host ""
        Write-Host "Suggested fixes:"
        if (-not $exists) { Write-Host "  - Run: codebase-memory-mcp-ds update" }
        elseif (-not $running) { Write-Host "  - Run: codebase-memory-mcp-ds start" }
        if (-not $workspaceOk) { Write-Host "  - Re-run install.ps1 with -WorkspacePath pointing at your source root" }
        if (-not $composeOk) { Write-Host "  - Re-run install.ps1 so the wrapper config points at the compose checkout" }
        if (-not $pathHasCommand) { Write-Host "  - Restart this terminal, or add $ScriptDir to PATH for this session" }
    }
}

function Invoke-Update {
    param([string[]]$Rest)
    $version = "latest"
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if ($Rest[$i] -eq "--version" -or $Rest[$i] -eq "-Version") {
            if (($i + 1) -ge $Rest.Count) { throw "missing version after $($Rest[$i])" }
            $version = $Rest[$i + 1]
            $i++
        } elseif ($Rest[$i] -and -not $Rest[$i].StartsWith("-")) {
            $version = $Rest[$i]
        } else {
            throw "unknown update option: $($Rest[$i])"
        }
    }

    Write-Host "Updating DS Docker image from upstream release: $version"
    $rc = Invoke-Compose -ComposeArgs @("build", "--build-arg", "CBM_VERSION=$version")
    if ($rc -ne 0) { exit $rc }
    $rc = Invoke-Compose -ComposeArgs @("up", "-d")
    exit $rc
}

function Invoke-Uninstall {
    param([string[]]$Rest)
    $yes = $false
    $removeVolumes = $false
    $removeImage = $false
    $keepCli = $false
    foreach ($arg in $Rest) {
        switch ($arg) {
            "-y" { $yes = $true }
            "--yes" { $yes = $true }
            "--volumes" { $removeVolumes = $true }
            "--image" { $removeImage = $true }
            "--keep-cli" { $keepCli = $true }
            default { throw "unknown uninstall option: $arg" }
        }
    }

    if (-not $yes) {
        $answer = Read-Host "Remove DS container, agent config, skill/hooks, and wrapper? [y/N]"
        if ($answer -notmatch '^[Yy]$') {
            Write-Host "Cancelled."
            return
        }
    }

    if ($Cfg.composeDir -and (Test-Path $Cfg.composeDir)) {
        $args = @("down")
        if ($removeVolumes) { $args += "-v" }
        $rc = Invoke-Compose -ComposeArgs $args
        if ($rc -ne 0) { Write-Err "warning: docker compose down exited with $rc" }
    } elseif (Test-Container) {
        docker rm -f $Cfg.containerName | Out-Null
        Write-Host "removed container $($Cfg.containerName)"
    }

    if ($removeImage) {
        docker image rm $Cfg.imageName
    }

    $home = $env:USERPROFILE
    Remove-McpServerFromJson -Path (Join-Path $home ".claude\.mcp.json") -Name $Cfg.mcpName
    Remove-McpServerFromJson -Path (Join-Path $home ".claude.json") -Name $Cfg.mcpName
    Remove-DsHookRegistrations -Path (Join-Path $home ".claude\settings.json")

    $skillPath = Join-Path $home ".claude\skills\$($Cfg.skillName)"
    if (Test-Path $skillPath) {
        Remove-Item $skillPath -Recurse -Force
        Write-Host "removed skill $skillPath"
    }
    $hooksDir = Join-Path $home ".claude\hooks"
    foreach ($hook in @("cbm-ds-code-discovery-gate", "cbm-ds-session-reminder")) {
        $p = Join-Path $hooksDir $hook
        if (Test-Path $p) {
            Remove-Item $p -Force
            Write-Host "removed hook $p"
        }
    }

    if (-not $keepCli) {
        Remove-PathEntry -Dir $ScriptDir
        try {
            Remove-Item $ScriptDir -Recurse -Force
            Write-Host "removed wrapper directory $ScriptDir"
        } catch {
            Write-Err "warning: could not remove wrapper directory $ScriptDir. $($_.Exception.Message)"
        }
    }
}

if ($args.Count -eq 0) {
    Show-Help
    exit 0
}

$Command = $args[0]
$Rest = @()
if ($args.Count -gt 1) { $Rest = @($args[1..($args.Count - 1)]) }

try {
    switch ($Command) {
        "help" { Show-Help }
        "--help" { Show-Help }
        "-h" { Show-Help }
        "install" {
            Write-Err "install is host-side for this Docker edition. Use install.ps1."
            exit 2
        }
        { $_ -like "--ui=*" -or $_ -like "--port=*" } {
            Write-Err "UI flags are managed by Docker compose/install.ps1. Use 'codebase-memory-mcp-ds ui' or re-run install.ps1 -UiPort <port>."
            exit 2
        }
        "mcp" { Invoke-InContainer -ArgsForBinary @("--ui=false") }
        "cli" { Invoke-InContainer -ArgsForBinary (@("cli") + $Rest) }
        "config" { Invoke-InContainer -ArgsForBinary (@("config") + $Rest) }
        "hook-augment" {
            try {
                if (-not (Test-ContainerRunning)) { exit 0 }
                $stdin = [Console]::In.ReadToEnd()
                if ([string]::IsNullOrEmpty($stdin)) {
                    docker exec -i $Cfg.containerName $Cfg.binInContainer hook-augment 2>$null | Out-Null
                } else {
                    $stdin | docker exec -i $Cfg.containerName $Cfg.binInContainer hook-augment 2>$null
                }
            } catch {
                exit 0
            }
            exit 0
        }
        "index" {
            if ($Rest.Count -lt 1) { throw "usage: codebase-memory-mcp-ds index <host-or-/workspace-path>" }
            $containerPath = Convert-ToContainerPath $Rest[0]
            $json = @{ repo_path = $containerPath } | ConvertTo-Json -Compress
            Invoke-Tool "index_repository" $json
        }
        "projects" { Invoke-Tool "list_projects" "{}" }
        "status" { Show-Status }
        "doctor" { Show-Status -Doctor }
        "ui" { Write-Host (Get-UiUrl) }
        "port" {
            Write-Host "Host UI port    : $(Get-UiPort)"
            Write-Host "Container port  : 9749/tcp"
            Write-Host "Internal UI port: 9750/tcp inside the container"
            Write-Host "MCP transport   : stdio via codebase-memory-mcp-ds mcp -> docker exec"
        }
        "logs" {
            Require-Docker
            & docker logs @Rest $Cfg.containerName
            exit $LASTEXITCODE
        }
        "start" {
            if ($Cfg.composeDir -and (Test-Path $Cfg.composeDir)) {
                exit (Invoke-Compose -ComposeArgs @("up", "-d"))
            }
            docker start $Cfg.containerName | Out-Null
            exit $LASTEXITCODE
        }
        "stop" {
            Require-Docker
            docker stop $Cfg.containerName | Out-Null
            exit $LASTEXITCODE
        }
        "restart" {
            Require-Docker
            docker restart $Cfg.containerName | Out-Null
            exit $LASTEXITCODE
        }
        "version" {
            Write-Host "codebase-memory-mcp-ds wrapper $WrapperVersion"
            if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                Write-Host "upstream: docker not found"
            } elseif (Test-ContainerRunning) {
                docker exec $Cfg.containerName $Cfg.binInContainer --version
            } else {
                Write-Host "upstream: container is not running"
            }
        }
        "update" { Invoke-Update $Rest }
        "uninstall" { Invoke-Uninstall $Rest }
        default {
            Write-Err "unknown command: $Command"
            Write-Err "Run 'codebase-memory-mcp-ds help'."
            exit 2
        }
    }
} catch {
    Write-Err "error: $($_.Exception.Message)"
    exit 1
}
