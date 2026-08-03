<#
.SYNOPSIS
    Removes the Simplified Chinese language pack and restores the previous locale.
.DESCRIPTION
    Thin wrapper around install.ps1 -Uninstall. See that script for details.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$NoRestart,
    [string]$Locale = 'zh-CN'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $here 'install.ps1'
if (-not (Test-Path $installer)) { throw "install.ps1 not found next to this script" }

$splat = @{ Uninstall = $true; Locale = $Locale }
if ($NoRestart) { $splat['NoRestart'] = $true }
& $installer @splat
