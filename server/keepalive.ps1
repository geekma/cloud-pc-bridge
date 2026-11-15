#requires -Version 5.1
<#
Session-level keepalive. Optional. Installed only when setup-server.ps1 is run
with -KeepAlive. Run in STA mode (the scheduled task does that for you).

What it does
  1. Creates a process-scoped POWER REQUEST (SystemRequired + DisplayRequired).
     Windows lists it in "powercfg /requests". This suppresses idle sleep and
     display blanking while the bridge is in use.
  2. Vetoes ordinary logoff / shutdown / reboot requests via
     Microsoft.Win32.SystemEvents.SessionEnding (WM_QUERYENDSESSION), with a
     visible block reason on the hidden owning window.
  3. Refreshes SetThreadExecutionState every 30 seconds and logs a heartbeat.

What it CANNOT do
  - Stop a forced shutdown, a hypervisor hard power cut, a host-level suspend,
    or a platform policy that recycles the VM. Those bypass Windows completely.
    In that case the ONLY fix is automatic recovery after the machine comes back
    (startup task + watchdog + client retry). See README section "Platform
    restarts and keepalive".
  - It also vetoes Windows Update reboots and manual shutdowns while active.
    Before planned maintenance run: powershell -File keepalive.ps1 -Allow
    Afterwards:                     powershell -File keepalive.ps1 -Deny

Usage
  powershell -Sta -ExecutionPolicy Bypass -File keepalive.ps1 -Run
  powershell -Sta -ExecutionPolicy Bypass -File keepalive.ps1 -Status
  powershell -Sta -ExecutionPolicy Bypass -File keepalive.ps1 -Allow|-Deny
#>
[CmdletBinding()]
param(
    [switch]$Run,
    [switch]$Allow,
    [switch]$Deny,
    [switch]$Status,
    [string]$StateDir = ''
)
$ErrorActionPreference = 'Continue'
if (-not $StateDir) { $StateDir = $PSScriptRoot }
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$Flag = Join-Path $StateDir 'allow-maintenance.flag'
$Log  = Join-Path $StateDir 'keepalive.log'

function Write-KLog {
    param([string]$Level = 'INFO', [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, ($Message -replace '[\r\n]+', ' ')
    try {
        if ((Test-Path -LiteralPath $Log) -and (Get-Item -LiteralPath $Log).Length -gt 1048576) {
            Move-Item -LiteralPath $Log -Destination ($Log + '.1') -Force
        }
        [System.IO.File]::AppendAllText($Log, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    if (-not $Run) { Write-Host $line }
}

if ($Allow) {
    Set-Content -LiteralPath $Flag -Value ('maintenance window opened ' + (Get-Date).ToString('o')) -Encoding UTF8
    Write-KLog INFO 'veto DISABLED (allow-maintenance.flag present)'
    return
}
if ($Deny) {
    if (Test-Path -LiteralPath $Flag) { Remove-Item -LiteralPath $Flag -Force }
    Write-KLog INFO 'veto ACTIVE'
    return
}
if ($Status) {
    Write-Host ('veto        : ' + $(if (Test-Path -LiteralPath $Flag) { 'DISABLED (maintenance)' } else { 'ACTIVE' }))
    Write-Host ('log         : ' + $Log)
    if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log -Tail 8 | ForEach-Object { Write-Host ('  ' + $_) } }
    Write-Host 'power requests:'
    & powercfg.exe /requests | Write-Host
    return
}
if (-not $Run) {
    Write-Host 'Usage: powershell -Sta -ExecutionPolicy Bypass -File keepalive.ps1 -Run|-Status|-Allow|-Deny'
    return
}

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
if (-not ('KeepAliveWin32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KeepAliveWin32 {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ShutdownBlockReasonCreate(IntPtr hWnd, string reason);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShutdownBlockReasonDestroy(IntPtr hWnd);
}
'@
}
if (-not ('KeepAlivePower' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct KeepAliveContext {
    public uint Version;
    public uint Flags;
    [MarshalAs(UnmanagedType.LPWStr)] public string SimpleReasonString;
}
public static class KeepAlivePower {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr PowerCreateRequest(ref KeepAliveContext Context);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PowerSetRequest(IntPtr Request, uint Type);
}
'@
}

$powerHandle = [IntPtr]::Zero
$form = $null
$handler = $null
try {
    $ctx = New-Object KeepAliveContext
    $ctx.Version = 0
    $ctx.Flags = 0
    $ctx.SimpleReasonString = 'Remote bridge keepalive'
    $powerHandle = [KeepAlivePower]::PowerCreateRequest([ref]$ctx)
    if ($powerHandle -ne [IntPtr]::Zero) {
        [void][KeepAlivePower]::PowerSetRequest($powerHandle, 0)  # DisplayRequired
        [void][KeepAlivePower]::PowerSetRequest($powerHandle, 1)  # SystemRequired
        Write-KLog INFO 'power request created (system + display)'
    } else {
        Write-KLog WARN 'PowerCreateRequest failed; falling back to SetThreadExecutionState'
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Remote bridge keepalive'
    $form.ShowInTaskbar = $false
    $form.WindowState = 'Minimized'
    [void]$form.Handle
    [void][KeepAliveWin32]::ShutdownBlockReasonCreate($form.Handle, 'Remote bridge is active')

    $handler = [Microsoft.Win32.SessionEndingEventHandler] {
        param($sender, $e)
        if (-not (Test-Path -LiteralPath $Flag)) {
            $e.Cancel = $true
            Write-KLog WARN ('vetoed ' + $e.Reason)
        } else {
            Write-KLog INFO ('allowed ' + $e.Reason + ' (maintenance flag)')
        }
    }
    [Microsoft.Win32.SystemEvents]::add_SessionEnding($handler)
    Write-KLog INFO ('resident started pid=' + $PID + ', veto ACTIVE')

    $lastBeat = Get-Date
    while ($true) {
        [void][KeepAliveWin32]::SetThreadExecutionState(0x80000003)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 30
        if (((Get-Date) - $lastBeat).TotalMinutes -ge 5) {
            Write-KLog INFO 'alive, idle timers suppressed, veto ACTIVE'
            $lastBeat = Get-Date
        }
        if (Test-Path -LiteralPath $Flag) { Write-KLog INFO 'maintenance flag present, veto paused' }
    }
} finally {
    if ($handler) { try { [Microsoft.Win32.SystemEvents]::remove_SessionEnding($handler) } catch { } }
    if ($form) {
        try { [void][KeepAliveWin32]::ShutdownBlockReasonDestroy($form.Handle) } catch { }
        try { $form.Dispose() } catch { }
    }
    [void][KeepAliveWin32]::SetThreadExecutionState(0x80000000)
    Write-KLog INFO 'resident stopped'
}
