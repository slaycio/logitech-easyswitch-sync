# Logitech Easy-Switch Mouse Follow

Makes a Logitech mouse follow a Logitech keyboard across Bluetooth Easy-Switch host channels, in near real time — without needing the mouse to support Logi Options+'s built-in cross-device sync.

## Why

Logi Options+ can keep a keyboard and mouse in sync when you press Easy-Switch on the keyboard, but only for matching device generations (e.g. an MX Keys **S** keyboard paired with an MX Keys **S**-era mouse). Pair it with an older/non-"S" mouse and that sync silently doesn't apply — pressing Easy-Switch on the keyboard switches the keyboard only, leaving the mouse behind on the old host.

This tool watches the keyboard directly over HID++ and re-issues the same "switch host" command to the mouse the instant the keyboard does it — on its own, with no vendor software involved.

## How it works

Logitech's HID++ 2.0 protocol exposes a `CHANGE_HOST` feature (`0x1814`) that lets software tell a device "switch to host N". Normally, pressing the physical Easy-Switch button just does this in firmware with no visible trace to connected hosts — the keyboard simply disconnects from the current host and reconnects to the next one.

Empirically (verified via a raw HID sniff against an MX Keys S), the keyboard also emits an **unsolicited HID++ notification** on this same feature right before it disconnects, and that notification's payload includes the *target host index*. `watcher.ps1` opens a direct HID handle to the keyboard, blocks on `ReadFile`, and the moment that notification arrives it reads the target channel and immediately sends the matching `CHANGE_HOST` command to the mouse — typically within single-digit milliseconds, roughly half a second before the keyboard's own disconnect would otherwise have completed.

Two design choices worth calling out:

- **No external process is spawned in the hot path.** Everything (`CreateFile`/`ReadFile`/`WriteFile`, and the one-time `SetupDiGetClassDevs` device enumeration in `setup.ps1`) goes through direct Windows API P/Invoke calls from a single long-running PowerShell process. On machines with endpoint security agents that intercept process creation (common in managed corporate environments), spawning even a trivial helper process can itself cost several hundred milliseconds — more than the rest of this script's logic combined.
- **The target host is read live, never hardcoded.** If the early notification is ever missed for some reason, the watcher logs it and skips that switch rather than guessing a channel — in testing, the notification arrived before every single disconnect.

## Requirements

- Windows 10/11
- PowerShell 5.1 or PowerShell 7+ (auto-detected)
- A Logitech keyboard and mouse with Easy-Switch / multi-host support, paired directly over Bluetooth (not via a Unifying/Bolt receiver) to the same two (or more) machines
- No admin rights needed

Defaults target an MX Keys S (`046D:B378`) + MX Anywhere 3 (`046D:B025`). Other Logitech multi-host devices will likely work too — pass their VID/PID to `setup.ps1` (see parameters below).

## Install

On each machine, with both devices currently connected to it over Bluetooth:

```powershell
git clone <this-repo-url>
cd logitech-easyswitch-sync
.\setup.ps1
```

This discovers both devices' HID paths and their `CHANGE_HOST` feature index, then registers a hidden, auto-starting Scheduled Task (current user, no elevation) that runs `watcher.ps1` in the background from then on.

Repeat on the second machine — paths and feature indices are resolved independently per machine, there's nothing to copy between them.

### Custom devices

```powershell
.\setup.ps1 -KeyboardVendorId 0x046D -KeyboardProductId 0xB378 -MouseVendorId 0x046D -MouseProductId 0xB025
```

## Manage

```powershell
# live log
Get-Content "$env:LOCALAPPDATA\LogitechEasySwitchSync\watcher.log" -Wait -Tail 20

# stop until next logon
Stop-ScheduledTask -TaskName 'LogitechEasySwitchSync'

# restart manually
Start-ScheduledTask -TaskName 'LogitechEasySwitchSync'

# uninstall
.\setup.ps1 -Uninstall              # just the scheduled task
.\setup.ps1 -Uninstall -RemoveFiles # also delete the installed copy + log
```

## Troubleshooting

- **Devices not found during setup**: make sure both are actively connected (not just paired) to the machine you're running `setup.ps1` on.
- **Mouse stopped following after re-pairing**: HID device paths are tied to the Bluetooth link identity and can change if you unpair/re-pair. Just re-run `.\setup.ps1`.
- **Nothing happens on switch**: check the log — if you see `"target unknown, skipping"`, the early notification wasn't caught for that switch; this hasn't recurred in testing but isn't architecturally guaranteed.

## Credits

The underlying idea of sending raw HID++ `CHANGE_HOST` commands came from [marcelhoffs/input-switcher](https://github.com/marcelhoffs/input-switcher), which uses [hidapitester](https://github.com/todbot/hidapitester) and per-key scripts on each machine. This project reimplements the device communication directly against the Windows HID API (no external binaries) and adds automatic, live-triggered mouse following instead of a manually bound hotkey per device.
