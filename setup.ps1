<#
.SYNOPSIS
  Discovers the keyboard and mouse HID device paths on this machine and
  installs watcher.ps1 as a hidden, auto-starting Scheduled Task.

.DESCRIPTION
  Requires the keyboard and mouse to be currently connected over Bluetooth
  to this machine (i.e. on the host channel you want this machine to own).

  No admin rights required - the task is registered for the current user
  only, triggered at logon.

.PARAMETER Uninstall
  Remove the Scheduled Task instead of installing.

.PARAMETER RemoveFiles
  Combined with -Uninstall: also delete the installed copy and log file
  under %LocalAppData%\LogitechEasySwitchSync.

.EXAMPLE
  .\setup.ps1
  .\setup.ps1 -Uninstall
  .\setup.ps1 -Uninstall -RemoveFiles
#>

param(
    [switch]$Uninstall,
    [switch]$RemoveFiles,

    [string]$KeyboardVendorId  = "0x046D",
    [string]$KeyboardProductId = "0xB378",
    [string]$MouseVendorId     = "0x046D",
    [string]$MouseProductId    = "0xB025",
    [int]$UsagePage = 0xFF43,
    [int]$Usage     = 0x0202,

    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "LogitechEasySwitchSync"),
    [string]$TaskName   = "LogitechEasySwitchSync"
)

function Stop-ExistingWatcherProcesses {
    # Stop-ScheduledTask/Unregister-ScheduledTask only clean up the Task
    # Scheduler registration - they don't touch a process left running from
    # a previous install. Kill those explicitly so we never end up with two
    # watchers holding the keyboard handle at once.
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'run\.ps1' } |
        ForEach-Object {
            Write-Host "Stopping existing watcher process (PID $($_.ProcessId))..." -ForegroundColor DarkGray
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
    }
    else {
        Write-Host "Task '$TaskName' does not exist (already uninstalled?)." -ForegroundColor DarkGray
    }
    $startupVbs = Join-Path ([Environment]::GetFolderPath('Startup')) "$TaskName.vbs"
    if (Test-Path $startupVbs) {
        Remove-Item -Path $startupVbs -Force
        Write-Host "Startup-folder shortcut removed." -ForegroundColor Green
    }
    Stop-ExistingWatcherProcesses
    if ($RemoveFiles -and (Test-Path $InstallDir)) {
        # Stop-Process doesn't release the log file handle instantaneously -
        # a couple of short retries covers that race.
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop
                break
            }
            catch {
                Start-Sleep -Milliseconds 300
            }
        }
        if (Test-Path $InstallDir) {
            Write-Host "Could not fully remove '$InstallDir' (file still in use) - try again in a moment." -ForegroundColor Yellow
        }
        else {
            Write-Host "Install directory '$InstallDir' removed." -ForegroundColor Green
        }
    }
    exit 0
}

$csharp = @'
using System;
using System.Runtime.InteropServices;

public static class HidNative {
    [DllImport("hid.dll")]
    public static extern void HidD_GetHidGuid(out Guid gHid);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, int Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData, ref Guid InterfaceClassGuid, int MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData, ref SP_DEVICE_INTERFACE_DETAIL_DATA DeviceInterfaceDetailData, int DeviceInterfaceDetailDataSize, ref int RequiredSize, IntPtr DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite, out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(IntPtr HidDeviceObject, ref HIDD_ATTRIBUTES Attributes);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetPreparsedData(IntPtr HidDeviceObject, out IntPtr PreparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_FreePreparsedData(IntPtr PreparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern int HidP_GetCaps(IntPtr PreparsedData, ref HIDP_CAPS Capabilities);

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct SP_DEVICE_INTERFACE_DETAIL_DATA {
        public int cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)]
        public string DevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ = 1;
    public const uint FILE_SHARE_WRITE = 2;
    public const uint OPEN_EXISTING = 3;
    public const int DIGCF_PRESENT = 0x2;
    public const int DIGCF_DEVICEINTERFACE = 0x10;
}
'@
Add-Type -TypeDefinition $csharp

function Find-HidDevicePath {
    param([int]$VendorId, [int]$ProductId, [int]$WantUsagePage, [int]$WantUsage)

    $guid = [Guid]::Empty
    [HidNative]::HidD_GetHidGuid([ref]$guid)
    $hDevInfo = [HidNative]::SetupDiGetClassDevs([ref]$guid, [IntPtr]::Zero, [IntPtr]::Zero, [HidNative]::DIGCF_PRESENT -bor [HidNative]::DIGCF_DEVICEINTERFACE)

    $result = $null
    $index = 0
    while ($true) {
        $ifData = New-Object HidNative+SP_DEVICE_INTERFACE_DATA
        $ifData.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"HidNative+SP_DEVICE_INTERFACE_DATA")
        if (-not [HidNative]::SetupDiEnumDeviceInterfaces($hDevInfo, [IntPtr]::Zero, [ref]$guid, $index, [ref]$ifData)) { break }
        $index++

        $detail = New-Object HidNative+SP_DEVICE_INTERFACE_DETAIL_DATA
        $detail.cbSize = if ([IntPtr]::Size -eq 8) { 8 } else { 6 }
        $required = 0
        if (-not [HidNative]::SetupDiGetDeviceInterfaceDetail($hDevInfo, [ref]$ifData, [ref]$detail, 512, [ref]$required, [IntPtr]::Zero)) { continue }
        $path = $detail.DevicePath

        $h = [HidNative]::CreateFile($path, [HidNative]::GENERIC_READ -bor [HidNative]::GENERIC_WRITE, [HidNative]::FILE_SHARE_READ -bor [HidNative]::FILE_SHARE_WRITE, [IntPtr]::Zero, [HidNative]::OPEN_EXISTING, 0, [IntPtr]::Zero)
        if ($h -eq [IntPtr]-1) { continue }

        $attrs = New-Object HidNative+HIDD_ATTRIBUTES
        $attrs.Size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"HidNative+HIDD_ATTRIBUTES")
        if ([HidNative]::HidD_GetAttributes($h, [ref]$attrs) -and $attrs.VendorID -eq $VendorId -and $attrs.ProductID -eq $ProductId) {
            $pp = [IntPtr]::Zero
            if ([HidNative]::HidD_GetPreparsedData($h, [ref]$pp)) {
                $caps = New-Object HidNative+HIDP_CAPS
                [HidNative]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
                [HidNative]::HidD_FreePreparsedData($pp) | Out-Null
                if ($caps.UsagePage -eq $WantUsagePage -and $caps.Usage -eq $WantUsage) {
                    $result = $path
                }
            }
        }
        [HidNative]::CloseHandle($h) | Out-Null
        if ($result) { break }
    }
    [HidNative]::SetupDiDestroyDeviceInfoList($hDevInfo) | Out-Null
    return $result
}

function Open-Hid {
    param([string]$Path)
    $h = [HidNative]::CreateFile($Path, [HidNative]::GENERIC_READ -bor [HidNative]::GENERIC_WRITE, [HidNative]::FILE_SHARE_READ -bor [HidNative]::FILE_SHARE_WRITE, [IntPtr]::Zero, [HidNative]::OPEN_EXISTING, 0, [IntPtr]::Zero)
    if ($h -eq [IntPtr]-1) { return $null }
    return $h
}

function Find-ChangeHostFeatureIndex {
    param([IntPtr]$Handle)
    # IRoot.getFeature(0x1814) - returns this specific device's feature index
    # for CHANGE_HOST. Feature indices are per-device-firmware, not a
    # protocol-wide constant, so this must be looked up rather than assumed.
    $req = New-Object byte[] 20
    $req[0]=0x11; $req[1]=0xFF; $req[2]=0x00; $req[3]=0x01; $req[4]=0x18; $req[5]=0x14
    $w = 0
    [HidNative]::WriteFile($Handle, $req, 20, [ref]$w, [IntPtr]::Zero) | Out-Null
    $resp = New-Object byte[] 20
    $r = 0
    if (-not [HidNative]::ReadFile($Handle, $resp, 20, [ref]$r, [IntPtr]::Zero)) { return $null }
    if ($resp[4] -eq 0) { return $null }  # featureIndex 0 = feature not present on this device
    return [int]$resp[4]
}

function Get-HostInfo {
    param([IntPtr]$Handle, [int]$FeatureIndex)
    $req = New-Object byte[] 20
    $req[0]=0x11; $req[1]=0xFF; $req[2]=[byte]$FeatureIndex; $req[3]=0x01
    $w = 0
    [HidNative]::WriteFile($Handle, $req, 20, [ref]$w, [IntPtr]::Zero) | Out-Null
    $resp = New-Object byte[] 20
    $r = 0
    if (-not [HidNative]::ReadFile($Handle, $resp, 20, [ref]$r, [IntPtr]::Zero)) { return $null }
    return [PSCustomObject]@{ NumHosts = [int]$resp[4]; CurrentHost = [int]$resp[5] }
}

function Find-DeviceInfo {
    param([string]$Label, [int]$VendorId, [int]$ProductId)

    $path = Find-HidDevicePath -VendorId $VendorId -ProductId $ProductId -WantUsagePage $UsagePage -WantUsage $Usage
    if (-not $path) {
        Write-Host "$Label (VID $('{0:X4}' -f $VendorId):PID $('{0:X4}' -f $ProductId)) : NOT FOUND - is it currently connected over Bluetooth to this machine?" -ForegroundColor Red
        return $null
    }
    Write-Host "$Label found: $path" -ForegroundColor Green

    $h = Open-Hid -Path $path
    $currentHost = $null
    $featIdx = $null
    if ($h) {
        $featIdx = Find-ChangeHostFeatureIndex -Handle $h
        if ($featIdx) {
            $info = Get-HostInfo -Handle $h -FeatureIndex $featIdx
            if ($info) {
                Write-Host "  CHANGE_HOST feature index=0x$('{0:X2}' -f $featIdx), numHosts=$($info.NumHosts), currentHost=$($info.CurrentHost)" -ForegroundColor Cyan
                $currentHost = $info.CurrentHost
            }
        }
        [HidNative]::CloseHandle($h) | Out-Null
    }
    return [PSCustomObject]@{ Path = $path; CurrentHost = $currentHost; FeatureIndex = $featIdx }
}

Write-Host "=== Step 1/2: looking for keyboard and mouse on this machine ===" -ForegroundColor Yellow
$kb = Find-DeviceInfo -Label "Keyboard" -VendorId ([Convert]::ToInt32($KeyboardVendorId,16)) -ProductId ([Convert]::ToInt32($KeyboardProductId,16))
$ms = Find-DeviceInfo -Label "Mouse"    -VendorId ([Convert]::ToInt32($MouseVendorId,16))    -ProductId ([Convert]::ToInt32($MouseProductId,16))

if (-not ($kb -and $ms)) {
    Write-Host ""
    Write-Host "Could not find both devices - make sure they are CONNECTED to this machine over Bluetooth and try again." -ForegroundColor Red
    exit 1
}
if (-not ($kb.FeatureIndex -and $ms.FeatureIndex)) {
    Write-Host ""
    Write-Host "Found the devices but could not resolve their CHANGE_HOST feature index - do they support multi-host Easy-Switch?" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Step 2/2: installing watcher as a Scheduled Task ===" -ForegroundColor Yellow
Stop-ExistingWatcherProcesses

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -Path (Join-Path $PSScriptRoot "watcher.ps1") -Destination $InstallDir -Force
Write-Host "Watcher copied to: $InstallDir" -ForegroundColor Green

$psExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
if (-not $psExe) { throw "Neither pwsh.exe nor powershell.exe was found on PATH." }

$scriptPath = Join-Path $InstallDir "watcher.ps1"
$logPath    = Join-Path $InstallDir "watcher.log"
$runnerPath = Join-Path $InstallDir "run.ps1"

# A plain wrapper script, rather than threading the whole invocation through
# -Command string quoting, keeps both the Scheduled Task action and the
# Startup-folder fallback below simple (single quoted path each, no nested
# quote escaping to get wrong twice).
$runnerContent = "& '$scriptPath' -KeyboardPath '$($kb.Path)' -MousePath '$($ms.Path)' -KeyboardChangeHostFeatureIndex $($kb.FeatureIndex) -MouseChangeHostFeatureIndex $($ms.FeatureIndex) *>> '$logPath'"
Set-Content -Path $runnerPath -Value $runnerContent -Encoding UTF8
$taskArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`""

function Install-StartupFolderFallback {
    # Some corporate security policies deny standard users Register-ScheduledTask
    # (HRESULT 0x80070005) even for their own per-user logon tasks. The Startup
    # folder is a much more universally-permitted mechanism - it's just a file
    # drop, not a Task Scheduler API call - so fall back to it instead of
    # leaving the user with no autostart at all. Uses a .vbs wrapper (same
    # trick the upstream input-switcher project uses) so nothing flashes a
    # console window at logon.
    $startupDir = [Environment]::GetFolderPath('Startup')
    $vbsPath    = Join-Path $startupDir "$TaskName.vbs"
    # $taskArgs already contains its own quotes around $runnerPath - escape the
    # *whole* Windows command line generically for VBS (every " doubled, then
    # wrapped once) rather than hand-counting quote pairs, which is how the
    # first version of this got the nesting wrong.
    $winCommandLine = "`"$psExe`" $taskArgs"
    $vbsEscaped = $winCommandLine -replace '"', '""'
    $vbsContent = "Set WshShell = CreateObject(`"WScript.Shell`")`r`nWshShell.Run `"$vbsEscaped`", 0, False`r`nSet WshShell = Nothing`r`n"
    Set-Content -Path $vbsPath -Value $vbsContent -Encoding ASCII
    Write-Host "Installed a Startup-folder shortcut instead: $vbsPath" -ForegroundColor Yellow

    $wsh = New-Object -ComObject WScript.Shell
    $wsh.Run("`"$psExe`" $taskArgs", 0, $false) | Out-Null
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName' before re-registering..." -ForegroundColor DarkGray
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$usedFallback = $false
try {
    $action    = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "Scheduled task '$TaskName' registered (will also start at next logon)." -ForegroundColor Green
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
}
catch {
    Write-Host "Scheduled Task registration failed (often a security-policy restriction on this machine): $($_.Exception.Message)" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Install-StartupFolderFallback
    $usedFallback = $true
}

Start-Sleep -Milliseconds 500

Write-Host ""
Write-Host "Watcher is running in the background (hidden window)." -ForegroundColor Cyan
Write-Host "Live log:    Get-Content '$logPath' -Wait -Tail 20" -ForegroundColor Cyan
if ($usedFallback) {
    Write-Host "Stop:        Get-Process pwsh,powershell -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq '$psExe' } | Stop-Process" -ForegroundColor Cyan
}
else {
    Write-Host "Stop:        Stop-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
}
Write-Host "Uninstall:   .\setup.ps1 -Uninstall" -ForegroundColor Cyan
