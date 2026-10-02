<#
.SYNOPSIS
  Makes a Logitech mouse follow a Logitech keyboard across Easy-Switch
  Bluetooth host channels, in near real time.

.DESCRIPTION
  Designed for setups where Logi Options+ only supports cross-device
  Easy-Switch sync for matching device generations (e.g. an "S" keyboard
  with a non-"S" mouse falls outside that support matrix).

  Opens a direct Windows HID handle (CreateFile/ReadFile/WriteFile via
  P/Invoke) to the keyboard and blocks on ReadFile. Logitech's HID++ 2.0
  CHANGE_HOST feature sends an unsolicited notification (softwareId 0)
  just before the keyboard tears down its link to switch host - and that
  notification's payload includes the *target* host index. We read it and
  immediately issue the matching "set host" command to the mouse over its
  own HID handle, so the mouse follows within milliseconds instead of
  waiting for the full radio disconnect to complete.

  Deliberately avoids spawning any external process (e.g. hidapitester) in
  the hot path: on machines with endpoint security agents that intercept
  process creation (common in corporate environments), spawning a new
  process can itself cost several hundred milliseconds - more than the
  rest of this script's entire logic combined.

.PARAMETER KeyboardPath
  Windows HID device path for the keyboard's vendor-specific HID++
  collection (usagePage 0xFF43, usage 0x0202 for BLE-direct devices).
  Obtained via setup.ps1's discovery step.

.PARAMETER MousePath
  Same, for the mouse.

.PARAMETER KeyboardChangeHostFeatureIndex
  The keyboard's CHANGE_HOST (0x1814) HID++ feature index, as resolved by
  IRoot.getFeature during discovery. Feature indices are assigned per
  device firmware and are not a protocol constant - do not assume 0x0A
  for devices other than the ones setup.ps1 discovered this for.

.PARAMETER MouseChangeHostFeatureIndex
  Same, for the mouse.

.PARAMETER RetryWaitMs
  Poll interval while waiting for the keyboard to (re)appear on this host.
  Only affects how quickly the watcher re-arms after a reconnect, not how
  fast it reacts to a disconnect (that part is a blocking read, not
  polled).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$KeyboardPath,

    [Parameter(Mandatory = $true)]
    [string]$MousePath,

    [byte]$KeyboardChangeHostFeatureIndex = 0x0A,
    [byte]$MouseChangeHostFeatureIndex    = 0x0A,

    [int]$RetryWaitMs = 300
)

$csharp = @'
using System;
using System.Runtime.InteropServices;

public static class HidRaw {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr CreateFile(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite, out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ = 1;
    public const uint FILE_SHARE_WRITE = 2;
    public const uint OPEN_EXISTING = 3;
}
'@
Add-Type -TypeDefinition $csharp

function Open-Hid {
    param([string]$Path)
    $h = [HidRaw]::CreateFile($Path, [HidRaw]::GENERIC_READ -bor [HidRaw]::GENERIC_WRITE, [HidRaw]::FILE_SHARE_READ -bor [HidRaw]::FILE_SHARE_WRITE, [IntPtr]::Zero, [HidRaw]::OPEN_EXISTING, 0, [IntPtr]::Zero)
    if ($h -eq [IntPtr]-1) { return $null }
    return $h
}

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    Write-Host "$(Get-Date -Format 'HH:mm:ss.fff')  $Message" -ForegroundColor $Color
}

function Send-MouseHost {
    param([int]$TargetHost)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $h = Open-Hid -Path $MousePath
    if ($null -eq $h) {
        Write-Log "mouse unavailable, could not send host switch" "Magenta"
        return
    }
    $buf = New-Object byte[] 20
    $buf[0] = 0x11; $buf[1] = 0xFF; $buf[2] = $MouseChangeHostFeatureIndex; $buf[3] = 0x11; $buf[4] = [byte]$TargetHost
    $written = 0
    [HidRaw]::WriteFile($h, $buf, [uint32]$buf.Length, [ref]$written, [IntPtr]::Zero) | Out-Null
    [HidRaw]::CloseHandle($h) | Out-Null
    $sw.Stop()
    Write-Log "-> setCurrentHost($TargetHost) sent to mouse ($($sw.ElapsedMilliseconds) ms)" "Cyan"
}

Write-Log "Watcher started (no external process spawning). Ctrl+C to stop." "Yellow"

while ($true) {
    $kh = Open-Hid -Path $KeyboardPath
    if ($null -eq $kh) {
        Start-Sleep -Milliseconds $RetryWaitMs
        continue
    }
    Write-Log "Keyboard present - armed" "DarkGray"

    $buf = New-Object byte[] 20
    $bytesRead = 0
    $triggered = $false
    # Blocks here until the read errors out - that's the moment the keyboard
    # actually disconnects from this host.
    while ([HidRaw]::ReadFile($kh, $buf, 20, [ref]$bytesRead, [IntPtr]::Zero)) {
        # Early signal: an unsolicited CHANGE_HOST notification has softwareId 0
        # (the full byte is 0x00) - as opposed to a response to someone else's
        # query on the same feature index, which carries a non-zero softwareId.
        # Measured to arrive ~500-600ms before the actual disconnect. Byte 5 is
        # the target host index - read it instead of guessing.
        if ((-not $triggered) -and $buf[2] -eq $KeyboardChangeHostFeatureIndex -and $buf[3] -eq 0x00) {
            $targetHost = [int]$buf[5]
            Write-Log "Early CHANGE_HOST signal from keyboard (target: host $targetHost) -> switching mouse NOW" "Red"
            Send-MouseHost -TargetHost $targetHost
            $triggered = $true
        }
    }

    [HidRaw]::CloseHandle($kh) | Out-Null
    if ($triggered) {
        Write-Log "Keyboard actually disconnected (confirms early signal)" "DarkGray"
    }
    else {
        # No early notification arrived (it always has in testing so far) - without
        # it we don't know the target host, so we don't guess. The mouse won't
        # follow this time; the next switch gets another chance to catch it.
        Write-Log "Keyboard disconnected with no early signal - target unknown, skipping" "Yellow"
    }
    Start-Sleep -Milliseconds 200
}
