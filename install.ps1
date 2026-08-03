<#
.SYNOPSIS
    Installs the Simplified Chinese language pack for Claude Desktop.

.DESCRIPTION
    Claude Desktop ships a built-in i18n system: the main process reads
    "<resourcesPath>\<locale>.json" and discovers available locales by scanning
    that directory for files matching /[a-z]{2}-[A-Z]{2}/. There is no hardcoded
    allowlist, so dropping zh-CN.json in makes it a first-class locale.

    This script therefore ADDS ONE FILE and FLIPS ONE SETTING. It never modifies
    app.asar or any file shipped and signed by Anthropic.

.PARAMETER Uninstall
    Removes zh-CN.json and restores the previous locale.

.PARAMETER NoRestart
    Do not relaunch Claude Desktop after applying changes.

.PARAMETER Locale
    Locale to switch to. Defaults to zh-CN.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoRestart,
    [string]$Locale = 'zh-CN',

    # Internal: set when the script relaunches itself elevated.
    [switch]$Elevated,
    [string]$ConfigPath,
    [string]$PayloadPath,
    [string]$ResourcePath,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = $LogPath

function Write-Log($msg) {
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $msg -Encoding UTF8 } catch {}
    }
}
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan; Write-Log "==> $msg" }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green; Write-Log "    $msg" }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow; Write-Log "    ! $msg" }

# The elevated child runs in its own window that vanishes on exit, so every
# terminating error has to reach the log before we go.
trap {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Log "$($_.ScriptStackTrace)"
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

<#
    Runs a console executable without PowerShell's stderr plumbing.

    `& exe args 2>&1` looks harmless but in Windows PowerShell 5.1 it wraps each
    stderr line in a NativeCommandError record; combined with
    $ErrorActionPreference='Stop' that terminates the script even when the
    process exited 0. takeown and icacls both write informational text to
    stderr, so this cost us a working installer. Redirect at the OS level
    instead and judge success by exit code alone.
#>
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $so = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        $se = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)

        Write-Log "    [$Exe $($Arguments -join ' ')] exit=$($proc.ExitCode)"
        if ($so) { Write-Log "      out: $($so.Trim())" }
        if ($se) { Write-Log "      err: $($se.Trim())" }

        if (-not $IgnoreExitCode -and $proc.ExitCode -ne 0) {
            $detail = (($se, $so) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' | '
            throw "$Exe exited with $($proc.ExitCode). $detail"
        }
        return $proc.ExitCode
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# UTF-8 without BOM. Node's JSON.parse chokes on a BOM, and Set-Content/Out-File
# add one by default on Windows PowerShell.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, $script:Utf8NoBom)
}

# ---------------------------------------------------------------- discovery --

function Find-ClaudeResources {
    # 1. MSIX / packaged install (current Windows distribution)
    $pkg = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) {
        $p = Join-Path $pkg.InstallLocation 'app\resources'
        if (Test-Path (Join-Path $p 'en-US.json')) {
            return [pscustomobject]@{
                Path = $p; Kind = 'MSIX'; Version = $pkg.Version; Root = $pkg.InstallLocation
            }
        }
    }

    # 2. Classic Electron install (per-user, no elevation needed)
    $candidates = @()
    foreach ($glob in @(
            "$env:LOCALAPPDATA\AnthropicClaude\app-*\resources",
            "$env:LOCALAPPDATA\Programs\Claude\resources",
            "$env:PROGRAMFILES\Claude\resources")) {
        $candidates += Get-Item -Path $glob -ErrorAction SilentlyContinue
    }
    foreach ($c in ($candidates | Sort-Object FullName -Descending)) {
        if (Test-Path (Join-Path $c.FullName 'en-US.json')) {
            return [pscustomobject]@{
                Path = $c.FullName; Kind = 'Classic'; Version = 'unknown'
                Root = (Split-Path $c.FullName -Parent)
            }
        }
    }
    return $null
}

function Find-ConfigPath {
    # %APPDATA%\Claude is a reparse point into the package's LocalCache on MSIX
    # installs, so this single path is correct for both distributions.
    $p = Join-Path $env:APPDATA 'Claude\config.json'
    if (Test-Path $p) { return $p }
    $p2 = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\config.json'
    if (Test-Path $p2) { return $p2 }
    return $p  # will be created on first launch; we still report it
}

function Test-DirWritable($dir) {
    $probe = Join-Path $dir ('.probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

# --------------------------------------------------------------------- ACLs --

# BUILTIN\Administrators
$script:AdminsSid = 'S-1-5-32-544'

function Grant-TempWrite($dir) {
    $prevOwner = (Get-Acl -LiteralPath $dir).Owner
    Write-Warn2 "临时接管目录所有权：$dir（当前属主：$prevOwner）"

    # takeown reports "SUCCESS" on stdout but also chatters on stderr; only the
    # exit code is meaningful. Tolerate a non-zero code here and let the
    # writability probe below be the real verdict.
    Invoke-Native -Exe 'takeown.exe' -Arguments @('/F', $dir, '/A') -IgnoreExitCode | Out-Null
    Invoke-Native -Exe 'icacls.exe' -Arguments @($dir, '/grant', "*$($script:AdminsSid):(OI)(CI)F") | Out-Null

    if (-not (Test-DirWritable $dir)) {
        throw "已取得所有权，但 $dir 仍不可写。"
    }
    Write-Ok "已获得写入权限"
    return $prevOwner
}

function Revoke-TempWrite($dir, $prevOwner) {
    # Drop the explicit ACE we added; inherited ACEs are untouched.
    Invoke-Native -Exe 'icacls.exe' -Arguments @($dir, '/remove:g', "*$($script:AdminsSid)") -IgnoreExitCode | Out-Null
    if ($prevOwner) {
        Invoke-Native -Exe 'icacls.exe' -Arguments @($dir, '/setowner', $prevOwner) -IgnoreExitCode | Out-Null
    }
    $stillWritable = Test-DirWritable $dir
    if ($stillWritable) {
        Write-Warn2 "警告：$dir 仍可写，权限可能未完全还原"
    } else {
        Write-Ok "已还原原始权限与属主（属主：$prevOwner）"
    }
}

# ---------------------------------------------------------------- processes --

function Stop-ClaudeDesktop($installRoot) {
    # Match only the desktop app; the Claude Code CLI also runs as claude.exe.
    $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($installRoot, 'OrdinalIgnoreCase') })
    if ($procs.Count -eq 0) { return $false }

    Write-Step "Claude Desktop 正在运行（$($procs.Count) 个进程），正在关闭"
    $procs | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $still = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($installRoot, 'OrdinalIgnoreCase') })
        if ($still.Count -eq 0) { Write-Ok "已正常退出"; return $true }
    }
    Write-Warn2 "未能在超时前退出，强制结束进程"
    Get-Process -Name claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($installRoot, 'OrdinalIgnoreCase') } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    return $true
}

function Start-ClaudeDesktop($res) {
    if ($res.Kind -eq 'MSIX') {
        $pkg = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            $appId = (Get-AppxPackageManifest $pkg).Package.Applications.Application.Id
            if ($appId) {
                Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!$appId"
                return $true
            }
        }
    }
    $exe = Join-Path (Split-Path $res.Path -Parent) 'claude.exe'
    if (Test-Path $exe) { Start-Process $exe; return $true }
    return $false
}

# ------------------------------------------------------------------- config --

function Set-ConfigLocale($cfgPath, $newLocale) {
    if (-not (Test-Path $cfgPath)) {
        $dir = Split-Path $cfgPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-Utf8NoBom $cfgPath (@{ locale = $newLocale } | ConvertTo-Json)
        Write-Ok "已创建 $cfgPath，locale = $newLocale"
        return $null
    }

    $raw = [System.IO.File]::ReadAllText($cfgPath)   # strips BOM if present
    $cfg = $raw | ConvertFrom-Json
    $previous = $null
    if ($cfg.PSObject.Properties.Name -contains 'locale') { $previous = $cfg.locale }

    $backup = "$cfgPath.bak-zhcn"
    if (-not (Test-Path $backup)) {
        Write-Utf8NoBom $backup $raw
        Write-Ok "已备份配置到 $backup"
    }

    if ($null -eq $previous) {
        $cfg | Add-Member -NotePropertyName 'locale' -NotePropertyValue $newLocale
    } else {
        $cfg.locale = $newLocale
    }
    Write-Utf8NoBom $cfgPath ($cfg | ConvertTo-Json -Depth 100)
    Write-Ok "语言设置：$previous -> $newLocale"
    return $previous
}

# --------------------------------------------------------------------- main --

Write-Host ""
Write-Host "  Claude Desktop 简体中文语言包" -ForegroundColor White
Write-Host "  ================================" -ForegroundColor DarkGray

# Elevated re-entry uses paths handed down from the original (non-elevated) run,
# so an admin account with a different profile still patches the right config.
if ($Elevated) {
    $res = [pscustomobject]@{
        Path = $ResourcePath; Kind = 'MSIX'; Version = 'n/a'
        Root = (Split-Path (Split-Path $ResourcePath -Parent) -Parent)
    }
    $cfgPath = $ConfigPath
    $payload = $PayloadPath
} else {
    Write-Step "正在定位 Claude Desktop"
    $res = Find-ClaudeResources
    if (-not $res) {
        throw "未找到 Claude Desktop。请先从 https://claude.com/download 安装。"
    }
    Write-Ok "安装方式：$($res.Kind)，版本 $($res.Version)"
    Write-Ok "资源目录：$($res.Path)"

    $cfgPath = Find-ConfigPath
    Write-Ok "配置文件：$cfgPath"

    $payload = Join-Path $script:ScriptDir "src\$Locale.json"
    if (-not $Uninstall -and -not (Test-Path $payload)) {
        throw "语言包不存在：$payload"
    }
}

$target = Join-Path $res.Path "$Locale.json"

# Claude rewrites config.json on exit, which would clobber our change.
Stop-ClaudeDesktop $res.Root | Out-Null

# Elevate only if the resources directory is not already writable.
$needsAcl = -not (Test-DirWritable $res.Path)
if ($needsAcl -and -not (Test-Admin)) {
    Write-Step "需要管理员权限才能向资源目录写入文件，即将弹出 UAC 提示"

    $childLog = Join-Path ([System.IO.Path]::GetTempPath()) "claude-zhcn-install-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$($MyInvocation.MyCommand.Path)`"",
        '-Elevated',
        '-Locale', $Locale,
        '-ConfigPath', "`"$cfgPath`"",
        '-ResourcePath', "`"$($res.Path)`"",
        '-PayloadPath', "`"$payload`"",
        '-LogPath', "`"$childLog`""
    )
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($NoRestart) { $argList += '-NoRestart' }

    Write-Ok "日志：$childLog"
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait

    # Surface whatever the elevated window printed before it disappeared.
    if (Test-Path $childLog) {
        Write-Host ""
        Write-Host "--- 提权步骤输出 ---" -ForegroundColor DarkGray
        Get-Content -LiteralPath $childLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host "--------------------" -ForegroundColor DarkGray
    }
    if ($p.ExitCode -ne 0) {
        throw "提权步骤失败，退出码 $($p.ExitCode)。详见 $childLog"
    }
    Write-Host ""
    Write-Host "  完成。" -ForegroundColor Green
    exit 0
}

$prevOwner = $null
try {
    if ($needsAcl) { $prevOwner = Grant-TempWrite $res.Path }

    if ($Uninstall) {
        Write-Step "正在移除语言包"
        if (Test-Path $target) {
            Remove-Item $target -Force
            Write-Ok "已删除 $target"
        } else {
            Write-Warn2 "$target 不存在，跳过"
        }

        $backup = "$cfgPath.bak-zhcn"
        if (Test-Path $backup) {
            $prev = ([System.IO.File]::ReadAllText($backup) | ConvertFrom-Json).locale
            if (-not $prev) { $prev = 'en-US' }
            Set-ConfigLocale $cfgPath $prev | Out-Null
            Remove-Item $backup -Force
        } else {
            Set-ConfigLocale $cfgPath 'en-US' | Out-Null
        }
    } else {
        Write-Step "正在安装语言包"
        # Normalise to UTF-8 without BOM regardless of how the source was saved.
        Write-Utf8NoBom $target ([System.IO.File]::ReadAllText($payload))
        Write-Ok "已写入 $target"

        # Sanity check: the app will readFileSync + JSON.parse this file.
        $check = [System.IO.File]::ReadAllText($target) | ConvertFrom-Json
        Write-Ok "校验通过：$(($check.PSObject.Properties | Measure-Object).Count) 条字符串可被正常解析"

        Set-ConfigLocale $cfgPath $Locale | Out-Null
    }
} finally {
    if ($needsAcl -and $prevOwner) { Revoke-TempWrite $res.Path $prevOwner }
}

if (-not $NoRestart) {
    Write-Step "正在重新启动 Claude Desktop"
    if (Start-ClaudeDesktop $res) { Write-Ok "已启动" } else { Write-Warn2 "无法自动启动，请手动打开" }
}

Write-Host ""
if ($Uninstall) {
    Write-Host "  卸载完成，Claude Desktop 已恢复英文界面。" -ForegroundColor Green
} else {
    Write-Host "  安装完成，Claude Desktop 已切换为简体中文。" -ForegroundColor Green
    Write-Host "  注意：应用更新会替换安装目录，届时请重新运行本程序。" -ForegroundColor Yellow
}
exit 0
