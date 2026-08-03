<#
.SYNOPSIS
    Installs the Simplified Chinese language pack for Claude Desktop.

.DESCRIPTION
    Claude Desktop's main process loads "<resourcesPath>\<locale>.json" and picks
    the locale from its electron-store config. That config is NOT the source of
    truth: the remote claude.ai renderer is authorised (see the origin check on
    the DesktopIntl IPC interface) to call requestLocaleChange, and it pushes the
    account's language preference down a few seconds after launch, overwriting
    whatever the config said.

    Simplified Chinese is not in claude.ai's language list, so a freshly added
    zh-CN.json is never requested and never loads. The only approach that sticks
    is to overwrite a stock locale file that claude.ai actually asks for.

    Default target is ja-JP. That leaves en-US untouched, so the app's own
    language setting becomes a toggle: pick 日本語 for the Chinese shell, pick
    English to get the stock English build back — no reinstall needed. Use
    -TargetLocale en-US instead if you would rather not touch the setting at all.

    The original file is backed up outside the package before being replaced.

.PARAMETER Uninstall
    Restores the original locale file from the backup.

.PARAMETER TargetLocale
    Which stock locale file to overwrite. Defaults to ja-JP.

.PARAMETER Restart
    Relaunch Claude Desktop when finished. Off by default.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Restart,
    [switch]$DryRun,
    [string]$TargetLocale = 'ja-JP',

    # Internal: set when the script relaunches itself elevated.
    [switch]$Elevated,
    [string]$ConfigPath,
    [string]$PayloadPath,
    [string]$ResourcePath,
    [string]$BackupDir,
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
# Start-Process joins -ArgumentList with plain spaces and quotes nothing, so any
# argument containing a space (C:\Program Files\..., "NT AUTHORITY\SYSTEM")
# silently splits into two. Quote per CommandLineToArgvW rules before handing off.
function ConvertTo-NativeArg([string]$a) {
    if ($null -eq $a -or $a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    # Double any backslashes that precede a quote, and any trailing run of them.
    $e = [regex]::Replace($a, '(\\*)"', '$1$1\"')
    $e = [regex]::Replace($e, '(\\+)$', '$1$1')
    return '"' + $e + '"'
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )
    $quoted = @($Arguments | ForEach-Object { ConvertTo-NativeArg $_ })
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList $quoted -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $so = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        $se = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)

        Write-Log "    [$Exe $($quoted -join ' ')] exit=$($proc.ExitCode)"
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

<#
    Handing ownership back to NT AUTHORITY\SYSTEM needs SeRestorePrivilege.
    An elevated token *holds* it but it is disabled by default, so icacls
    /setowner fails with "Access is denied" (exit 5) — which is exactly what
    happened before this was added. Enable it explicitly on our own token.
#>
$script:PrivTypeLoaded = $false
function Enable-Privilege([string]$Name) {
    if (-not $script:PrivTypeLoaded) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZhCnPriv {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static bool Enable(string name) {
        IntPtr token;
        // TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) return false;
        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return false;
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Privileges.Luid = luid;
            tp.Privileges.Attributes = 0x00000002; // SE_PRIVILEGE_ENABLED
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return Marshal.GetLastWin32Error() == 0; // ERROR_NOT_ALL_ASSIGNED == 1300
        } finally { CloseHandle(token); }
    }
}
'@
        $script:PrivTypeLoaded = $true
    }
    $ok = [ZhCnPriv]::Enable($Name)
    Write-Log "    [privilege] $Name enabled=$ok"
    return $ok
}

function Get-AceSet($path) {
    try {
        return @((Get-Acl -LiteralPath $path).Access |
            ForEach-Object { "$($_.IdentityReference)|$($_.FileSystemRights)|$($_.AccessControlType)" }) | Sort-Object
    } catch { return @() }
}

# Reassigning an object to SYSTEM/TrustedInstaller needs SeRestorePrivilege.
function Set-OwnerTo($path, $owner) {
    if (-not $owner) { return $false }
    Enable-Privilege 'SeRestorePrivilege' | Out-Null
    Enable-Privilege 'SeTakeOwnershipPrivilege' | Out-Null

    Invoke-Native -Exe 'icacls.exe' -Arguments @($path, '/setowner', $owner) -IgnoreExitCode | Out-Null
    if ((Get-Acl -LiteralPath $path).Owner -eq $owner) { return $true }

    # icacls can still refuse; the .NET path honours the privilege we enabled.
    try {
        $acl = Get-Acl -LiteralPath $path
        $acl.SetOwner([System.Security.Principal.NTAccount]$owner)
        Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop
        Write-Log "    [setowner] $path -> $owner (.NET fallback)"
    } catch {
        Write-Log "    [setowner] $path -> $owner FAILED: $($_.Exception.Message)"
        return $false
    }
    return ((Get-Acl -LiteralPath $path).Owner -eq $owner)
}

<#
    Writes a file inside the package.

    Full Control on the *directory* is not enough to overwrite a file that is
    already there. Package files are owned by SYSTEM and their DACL grants
    Administrators nothing, and the inheritable ACE we add to the directory
    never reaches them: propagating an inherited ACE requires WRITE_DAC on each
    child, which we do not have. Deleting instead of overwriting does not help
    either — that is refused for the same reason.

    So take ownership of the target file itself, grant, write, then put it back.
    Package locale files carry no explicit ACEs (AreAccessRulesProtected is
    false — everything is inherited), so removing the one ACE we add restores
    the stock ACL exactly.
#>
function Write-ProtectedFile($path, $content) {
    try {
        Write-Utf8NoBom $path $content
        Write-Log "    [write] $path (直接覆盖)"
        return
    } catch [System.UnauthorizedAccessException] {
        Write-Log "    [write] 直接覆盖被拒绝，改为接管该文件"
    }

    $acl0 = Get-Acl -LiteralPath $path
    $origOwner = $acl0.Owner
    $before = Get-AceSet $path

    # /remove:g strips every granted ACE for the principal, so it is only safe
    # when the principal has none to begin with. Package locale files list
    # Users/SYSTEM/TrustedInstaller and no Administrators entry, which is the
    # case this relies on — verified against the restored ACL further down.
    if (@($before | Where-Object { $_ -match 'Administrators' }).Count -gt 0) {
        Write-Warn2 "注意：$path 已存在 Administrators 权限项，还原后可能与出厂不一致"
    }

    Invoke-Native -Exe 'takeown.exe' -Arguments @('/F', $path, '/A') -IgnoreExitCode | Out-Null
    Invoke-Native -Exe 'icacls.exe' -Arguments @($path, '/grant', "*$($script:AdminsSid):F") | Out-Null

    try {
        Write-Utf8NoBom $path $content
        Write-Log "    [write] $path (接管文件后覆盖)"
    } finally {
        # Drop our explicit ACE and hand the file back, even if the write failed.
        Invoke-Native -Exe 'icacls.exe' -Arguments @($path, '/remove:g', "*$($script:AdminsSid)") -IgnoreExitCode | Out-Null
        if ($origOwner) { Set-OwnerTo $path $origOwner | Out-Null }

        # Compare against an untouched sibling locale file rather than the
        # snapshot: that is the real ground truth for "stock", and it avoids
        # false alarms from ACL reads taken mid-operation.
        $after = Get-AceSet $path
        $nowOwner = try { (Get-Acl -LiteralPath $path).Owner } catch { '<无法读取>' }
        $reference = Get-ChildItem (Split-Path $path -Parent) -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $path } | Select-Object -First 1
        $refAces = if ($reference) { Get-AceSet $reference.FullName } else { $before }

        if (($refAces -join ';') -eq ($after -join ';') -and $nowOwner -eq $origOwner) {
            Write-Ok "文件权限已精确还原（属主：$nowOwner）"
        } else {
            Write-Warn2 "文件权限可能未完全还原：属主 $origOwner -> $nowOwner"
            Write-Log "    [acl] reference($($reference.Name)): $($refAces -join ' / ')"
            Write-Log "    [acl] actual                       : $($after -join ' / ')"
        }
    }
}

function Grant-TempWrite($dir) {
    $prevOwner = (Get-Acl -LiteralPath $dir).Owner

    # BUILTIN\Administrators is never the stock owner of a WindowsApps package
    # directory; seeing it means an earlier run failed to hand ownership back.
    # Restoring "what we found" would make that permanent, so correct it.
    if ($prevOwner -eq 'BUILTIN\Administrators' -and $dir -like '*\WindowsApps\*') {
        Write-Warn2 "检测到目录属主为 BUILTIN\Administrators，这不是 WindowsApps 的出厂值"
        Write-Warn2 "（应为 NT AUTHORITY\SYSTEM，多半是先前失败残留），本次将按出厂值还原"
        $prevOwner = 'NT AUTHORITY\SYSTEM'
    }

    Write-Warn2 "临时接管目录所有权：$dir（还原目标属主：$prevOwner）"

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
    # Order matters: hand ownership back FIRST, while we still hold the explicit
    # Full Control ACE. Doing /remove:g first strips the rights needed to change
    # the owner, which is how the folder previously ended up stuck on
    # BUILTIN\Administrators.
    if ($prevOwner) { Set-OwnerTo $dir $prevOwner | Out-Null }

    # Then drop the explicit ACE we added; inherited ACEs are untouched.
    Invoke-Native -Exe 'icacls.exe' -Arguments @($dir, '/remove:g', "*$($script:AdminsSid)") -IgnoreExitCode | Out-Null
    # Report what actually happened rather than what we asked for: /setowner
    # needs SeRestorePrivilege and can fail even elevated.
    $nowOwner = try { (Get-Acl -LiteralPath $dir).Owner } catch { '<无法读取>' }
    $stillWritable = Test-DirWritable $dir

    if ($nowOwner -ne $prevOwner) {
        Write-Warn2 "警告：属主未能还原（当前 $nowOwner，原为 $prevOwner）"
        Write-Warn2 "可手动还原： icacls `"$dir`" /setowner `"$prevOwner`""
    }
    if ($stillWritable) {
        Write-Warn2 "警告：$dir 仍可写，附加的权限项可能未完全移除"
    }
    if ($nowOwner -eq $prevOwner -and -not $stillWritable) {
        Write-Ok "已还原原始权限与属主（属主：$nowOwner）"
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
    # $BackupDir arrives from the parent so an admin account with a different
    # profile still writes the backup where the invoking user can find it.
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

    $BackupDir = Join-Path $env:LOCALAPPDATA 'claude-desktop-zh-CN'
    Write-Ok "备份目录：$BackupDir"
    Write-Ok "覆盖目标：$TargetLocale.json"

    $payload = Join-Path $script:ScriptDir 'src\zh-CN.json'
    if (-not $Uninstall -and -not (Test-Path $payload)) {
        throw "语言包不存在：$payload"
    }
}

$target = Join-Path $res.Path "$TargetLocale.json"

# Report the plan and stop before touching anything. Everything above this point
# is read-only, so this is safe to run at any time.
if ($DryRun) {
    Write-Host ""
    Write-Step "预演模式，以下操作不会执行"
    $running = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($res.Root, 'OrdinalIgnoreCase') }).Count
    Write-Ok "会关闭的 Claude Desktop 进程数：$running"
    Write-Ok "需要提权：$(-not (Test-DirWritable $res.Path))"
    if ($Uninstall) {
        Write-Ok "将从 $BackupDir 还原原始语言文件"
    } else {
        Write-Ok "将备份 $target"
        Write-Ok "        -> $(Join-Path $BackupDir "$TargetLocale.json.orig")"
        Write-Ok "将用 $payload 覆盖 $target"
        $src = [System.IO.File]::ReadAllText($payload) | ConvertFrom-Json
        Write-Ok "语言包字符串数：$(($src.PSObject.Properties | Measure-Object).Count)"
    }
    Write-Ok "安装后是否自动启动应用：$Restart"
    Write-Host ""
    Write-Host "  预演结束，未做任何更改。" -ForegroundColor Green
    exit 0
}

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
        '-TargetLocale', $TargetLocale,
        '-ConfigPath', "`"$cfgPath`"",
        '-ResourcePath', "`"$($res.Path)`"",
        '-PayloadPath', "`"$payload`"",
        '-BackupDir', "`"$BackupDir`"",
        '-LogPath', "`"$childLog`""
    )
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($Restart) { $argList += '-Restart' }

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

$statePath = Join-Path $BackupDir 'state.json'
$prevOwner = $null
try {
    if ($needsAcl) { $prevOwner = Grant-TempWrite $res.Path }

    if ($Uninstall) {
        Write-Step "正在还原原始语言文件"

        if (-not (Test-Path $statePath)) {
            Write-Warn2 "找不到安装记录 $statePath，无法自动还原"
            Write-Warn2 "若界面异常，重装 Claude Desktop 即可恢复出厂语言文件"
        } else {
            $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
            $orig = Join-Path $BackupDir "$($state.targetLocale).json.orig"
            $dest = Join-Path $res.Path "$($state.targetLocale).json"
            if (Test-Path $orig) {
                Write-ProtectedFile $dest ([System.IO.File]::ReadAllText($orig))
                Write-Ok "已还原 $dest"
                Remove-Item $orig -Force
            } else {
                Write-Warn2 "备份文件缺失：$orig"
            }
            Remove-Item $statePath -Force
        }

        # Clean up the stray zh-CN.json that earlier versions of this script left
        # behind. It was never loaded, but there is no reason to leave it there.
        $stray = Join-Path $res.Path 'zh-CN.json'
        if (Test-Path $stray) {
            Remove-Item $stray -Force
            Write-Ok "已清理无效的 zh-CN.json"
        }

        $cfgBak = "$cfgPath.bak-zhcn"
        if (Test-Path $cfgBak) {
            $prev = ([System.IO.File]::ReadAllText($cfgBak) | ConvertFrom-Json).locale
            if (-not $prev) { $prev = 'en-US' }
            Set-ConfigLocale $cfgPath $prev | Out-Null
            Remove-Item $cfgBak -Force
        }
    } else {
        Write-Step "正在安装语言包（覆盖 $TargetLocale）"

        if (-not (Test-Path $target)) {
            throw "目标语言文件不存在：$target"
        }

        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
        $orig = Join-Path $BackupDir "$TargetLocale.json.orig"

        # Only capture a backup the first time, so re-running after an app update
        # never overwrites the pristine copy with our own translated file.
        if (-not (Test-Path $orig)) {
            Write-Utf8NoBom $orig ([System.IO.File]::ReadAllText($target))
            Write-Ok "已备份原始 $TargetLocale.json 到 $orig"
        } else {
            Write-Ok "沿用已有备份 $orig"
        }

        # Guard the delete-and-recreate path: never destroy the stock file
        # unless a readable, parseable backup is already on disk.
        $verify = [System.IO.File]::ReadAllText($orig) | ConvertFrom-Json
        if (($verify.PSObject.Properties | Measure-Object).Count -lt 400) {
            throw "备份文件校验失败，安装中止：$orig"
        }

        # Normalise to UTF-8 without BOM regardless of how the source was saved.
        Write-ProtectedFile $target ([System.IO.File]::ReadAllText($payload))
        Write-Ok "已写入 $target"

        # Sanity check: the app will readFileSync + JSON.parse this file.
        $check = [System.IO.File]::ReadAllText($target) | ConvertFrom-Json
        $n = ($check.PSObject.Properties | Measure-Object).Count
        Write-Ok "校验通过：$n 条字符串可被正常解析"
        if ($n -lt 400) { throw "字符串数量异常（$n），安装中止" }

        @{
            targetLocale = $TargetLocale
            appVersion   = $res.Version
            resourcePath = $res.Path
            installedAt  = (Get-Date).ToString('s')
        } | ConvertTo-Json | ForEach-Object { Write-Utf8NoBom $statePath $_ }

        # Nudge the cached locale to match; claude.ai will confirm it on launch.
        Set-ConfigLocale $cfgPath $TargetLocale | Out-Null
    }
} finally {
    if ($needsAcl -and $prevOwner) { Revoke-TempWrite $res.Path $prevOwner }
}

# Off by default: relaunching immediately makes it harder to tell whether the
# change took, and the caller may want to inspect things first.
if ($Restart) {
    Write-Step "正在重新启动 Claude Desktop"
    if (Start-ClaudeDesktop $res) { Write-Ok "已启动" } else { Write-Warn2 "无法自动启动，请手动打开" }
}

Write-Host ""
if ($Uninstall) {
    Write-Host "  卸载完成，已还原原始语言文件。" -ForegroundColor Green
} else {
    Write-Host "  安装完成。请手动启动 Claude Desktop。" -ForegroundColor Green
    Write-Host ""
    if ($TargetLocale -ne 'en-US') {
        # The shell only loads our file once claude.ai asks for this locale, and
        # claude.ai only asks for what the account language says.
        $display = switch ($TargetLocale) {
            'ja-JP' { '日本語' }; 'ko-KR' { '한국어' }; 'de-DE' { 'Deutsch' }
            'fr-FR' { 'Français' }; 'it-IT' { 'Italiano' }; 'pt-BR' { 'Português' }
            'id-ID' { 'Bahasa Indonesia' }; 'hi-IN' { 'हिन्दी' }
            default { $TargetLocale }
        }
        Write-Host "  最后一步：在 Claude 设置里把语言切换为「$display」" -ForegroundColor Cyan
        Write-Host "  界面语言由 claude.ai 账号设置决定，不切换则不会生效。" -ForegroundColor Cyan
        Write-Host "  想看回英文原版，把语言切回 English 即可（en-US.json 未被改动）。" -ForegroundColor DarkGray
    }
    Write-Host "  注意：应用更新会替换安装目录，届时请重新运行本程序。" -ForegroundColor Yellow
}
exit 0
