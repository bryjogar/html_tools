# Enable Monolithic Windows Kiosk Deployment Tool

A self-contained, enterprise-grade PowerShell deployment, shell replacement, and compliance audit engine for Windows 10/11 Pro, Enterprise, and Education.

Designed specifically for modern RMM platforms (**ImmyBot**, **NinjaOne**, **Datto RMM**, **ConnectWise Automate**, **Microsoft Intune**) as well as standalone administrator execution.

---

## Table of Contents

- [Overview & Architecture](#overview--architecture)
- [Key Features](#key-features)
- [Operating Modes](#operating-modes)
- [Command-Line Parameters](#command-line-parameters)
- [Deployment Recipes](#deployment-recipes)
  - [1. Web Check-in Kiosk (Church / Event / Healthcare)](#1-web-check-in-kiosk-church--event--healthcare)
  - [2. Local Desktop Application Kiosk](#2-local-desktop-application-kiosk)
  - [3. Background Companion Apps (e.g. QZ Tray Label Printing)](#3-background-companion-apps-eg-qz-tray-label-printing)
- [RMM Integration Guide (ImmyBot)](#rmm-integration-guide-immybot)
  - [ImmyBot Software Definition](#immybot-software-definition)
  - [Test / Detection Script](#test--detection-script)
  - [Install Script](#install-script)
  - [Uninstall Script](#uninstall-script)
- [Admin Escape Hatch & Maintenance](#admin-escape-hatch--maintenance)
- [Security & Hardening Reference](#security--hardening-reference)
- [Troubleshooting & Gotchas](#troubleshooting--gotchas)

---

## Overview & Architecture

Deploying reliable Windows kiosks traditionally required either rigid **Assigned Access** (which restricts touch gestures, multiple monitors, and browser extensions) or complex third-party tools (AutoHotkey scripts, compiled DLLs, unmanaged VBScript wrappers).

`Deploy-Kiosk.ps1` is a single-file, zero-dependency monolithic solution that compiles native C# components directly on the target endpoint and leverages in-box Win32 APIs for headless user profile initialization.

```
+-----------------------------------------------------------------------------------+
|                              Windows 10/11 Endpoint                               |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  [ HKLM\Winlogon\Shell: 'explorer.exe' ]  <-- Technicians/Admins boot normally    |
|                                                                                   |
|  [ Kiosk User: HKCU\Winlogon\Shell ]                                              |
|            |                                                                      |
|            +---> powershell.exe -WindowStyle Hidden -File "launch.ps1"            |
|                     |                                                             |
|                     +---> KioskKeyBlocker.exe (Native C# Low-Level Hook)          |
|                     +---> Background Companion Apps (QZ Tray, Print Services)     |
|                     +---> Microsoft Edge (--kiosk, touch-hardened) OR Local App   |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

---

## Key Features

- **Zero External Dependencies**:
  No AutoHotkey, `Ahk2Exe`, external DLLs, or third-party MSI packages required. Everything compiles on the fly using the in-box Microsoft .NET Framework compiler (`Add-Type`).
- **Headless Win32 Profile Baking**:
  Compiles inline C# calling `advapi32.dll!LogonUser` and `userenv.dll!LoadUserProfile` to initialize the user's `NTUSER.DAT` hive immediately without requiring an interactive sign-in.
- **Safe Per-User Shell Isolation**:
  Replaces **only** the kiosk user's `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell`.
  `HKLM\...\Winlogon\Shell` remains strictly untouched as `explorer.exe`. Administrators, remote support technicians, and Safe Mode sessions always boot to a stock desktop.
- **Modern Shell Orchestration**:
  Deprecation-proof architecture that avoids obsolete VBScript (`launch.vbs` / `wscript.exe`) and batch files in favor of hidden PowerShell orchestration (`launch.ps1`).
- **Compiled Low-Level Keyboard Blocker (`KioskKeyBlocker.exe`)**:
  Compiles a lightweight (~12KB) native Windows GUI executable directly into `$InstallPath`:
  - Intercepts and swallows hotkeys (`Alt+F4`, `Alt+Tab`, `LWin`, `RWin`, `Ctrl+Esc`, `Ctrl+Shift+Esc`, `Alt+Space`).
  - **30-Second Hook Watchdog Timer**: Periodically refreshes `SetWindowsHookEx` to defeat Windows hook timeout eviction.
  - **Named Mutex**: Single-instance protection.
  - **Admin Escape Hatch**: Hotkey combination (default: `Ctrl+Alt+Shift+K`) that cleanly terminates the session via `ExitWindowsEx(EWX_LOGOFF)`.
- **Touchscreen & Browser Hardening**:
  Configures Microsoft Edge full-screen kiosk with anti-tamper flags (`--disable-pinch`, `--overscroll-history-navigation=0`, `--no-first-run`, `--no-default-browser-check`).
- **Secure SAS (Ctrl+Alt+Del) Restrictions**:
  Suppresses Task Manager (`DisableTaskMgr`), Lock Workstation (`DisableLockWorkstation`), and Change Password (`DisableChangePassword`) options in the kiosk user's policy hive.
- **RMM & Orchestrator Native Lifecycle**:
  Does not trigger forced reboots. Exits with standard status codes (`0` for success) so that orchestrators like ImmyBot, Intune, or NinjaOne manage reboot policies and maintenance windows according to their native schedules.

---

## Operating Modes

Pass the `-Mode` parameter (alias: `-Action`) to select an operation:

| Mode | Exit Codes | Description |
| :--- | :---: | :--- |
| **`Setup`** *(Default)* | `0` (Success), `1` (Failure) | Deploys user accounts, bakes profiles, compiles the blocker, generates launch files, applies auto-logon, and audits compliance. |
| **`Verify`** | `0` (Compliant), `1` (Non-Compliant) | Performs a 4-point compliance audit of local files, HKLM safety, user accounts, and the HKCU Winlogon shell without modifying machine state. |
| **`Remove`** | `0` (Success), `1` (Failure) | Forcibly evicts active kiosk sessions, terminates processes, purges user accounts and CIM profiles, removes disk directories, and restores default Windows shell settings. |

---

## Command-Line Parameters

```powershell
Deploy-Kiosk.ps1
    [-Mode <Setup|Remove|Verify>]
    [-KioskUrl <String>]
    [-KioskApp <String>]
    [-KioskAppArgs <String>]
    [-Username <String>]
    [-Password <String>]
    [-BackgroundApps <Object>]
    [-AutoLogon]
    [-Force]
    [-BlockedKeys <Object>]
    [-EscapeKey <String>]
    [-DisableSasOptions <Object>]
    [-InstallPath <String>]
```

### Parameter Reference

| Parameter | Type | Default | Description |
| :--- | :---: | :--- | :--- |
| **`-Mode`** | String | `'Setup'` | Operation mode: `Setup`, `Remove`, or `Verify`. Alias: `-Action`. |
| **`-KioskUrl`** | String | *$null* | Web target URL opened in full-screen, touch-hardened Microsoft Edge. Mutually exclusive with `-KioskApp`. |
| **`-KioskApp`** | String | *$null* | Absolute path to a local executable application kiosk. Mutually exclusive with `-KioskUrl`. |
| **`-KioskAppArgs`** | String | *$null* | Command-line arguments passed to `-KioskApp`. |
| **`-Username`** | String | `'Kiosk User'` | Local Windows user account name dedicated to the kiosk session. |
| **`-Password`** | String | *$null* | Fixed password for the account. If omitted, a temporary 32-character complex password is used for profile initialization and then cleared. |
| **`-BackgroundApps`** | Array/String | `@()` | Executable(s) launched in the background prior to the primary kiosk app (e.g., label printing agents like QZ Tray). |
| **`-AutoLogon`** | Switch | `False` | Configures Windows registry AutoAdminLogon to boot directly into the kiosk user. |
| **`-Force`** | Switch | `False` | Forcibly evicts active sessions, terminates lingering processes, purges existing CIM user profiles, and redeploys from scratch. |
| **`-BlockedKeys`** | Array/String | *See list* | Keys swallowed by `KioskKeyBlocker.exe`. Defaults: `Alt+F4, Alt+Tab, Alt+Shift+Tab, LWin, RWin, Ctrl+Esc, Ctrl+Shift+Esc, Alt+Space`. |
| **`-EscapeKey`** | String | `'Ctrl+Alt+Shift+K'` | Keyboard shortcut that immediately logs off the kiosk user. Pass empty string `''` to disable. |
| **`-DisableSasOptions`** | Array/String | `'DisableTaskMgr'` | Subset of Ctrl+Alt+Del menu options to disable: `DisableTaskMgr`, `DisableLockWorkstation`, `DisableChangePassword`. Pass `''` to leave stock. |
| **`-InstallPath`** | String | `'C:\Program Files\Enable\Apps\Kiosk'` | Destination directory for runtime files (`launch.ps1`, `KioskKeyBlocker.exe`, `KioskKeyBlocker.cfg`). |

---

## Deployment Recipes

### 1. Web Check-in Kiosk (Church / Event / Healthcare)

Deploys a touch-hardened web kiosk running Microsoft Edge with automatic logon, locked Task Manager, and forced clean installation:

```powershell
.\Deploy-Kiosk.ps1 `
    -KioskUrl "https://checkin.myorganization.org" `
    -Username "KioskUser" `
    -AutoLogon `
    -Force
```

### 2. Local Desktop Application Kiosk

Locks the user into a specific desktop software application with custom command-line arguments:

```powershell
.\Deploy-Kiosk.ps1 `
    -KioskApp "C:\Program Files\MyLOBApp\App.exe" `
    -KioskAppArgs "--kiosk-mode --tenant 402" `
    -Username "AppKiosk" `
    -AutoLogon `
    -Force
```

### 3. Background Companion Apps (e.g. QZ Tray Label Printing)

Launches support daemons (like zebra label printing or hardware scanner bridge utilities) before loading the web interface:

```powershell
.\Deploy-Kiosk.ps1 `
    -KioskUrl "https://checkin.myorganization.org" `
    -Username "CheckinStation" `
    -BackgroundApps "C:\Program Files\QZ Tray\qz-tray.exe" `
    -AutoLogon `
    -Force
```

---

## RMM Integration Guide (ImmyBot)

`Deploy-Kiosk.ps1` conforms to ImmyBot's software deployment model.

### ImmyBot Software Definition

1. Navigate to **Software** > **Add Software** in ImmyBot.
2. Set **Software Name**: `Enable Kiosk`.

### Test / Detection Script
ImmyBot runs this script to audit if the endpoint is compliant. If it exits with `0`, ImmyBot skips installation; if it exits with `1`, ImmyBot triggers the Install script.

```powershell
# ImmyBot Test Script
$params = @{
    Mode     = 'Verify'
    Username = 'MPCheckin'
}
& ".\Deploy-Kiosk.ps1" @params
```

### Install Script
Executes full kiosk deployment with session teardown and automated compliance verification. Hand off reboot orchestration directly to ImmyBot's native maintenance cycle.

```powershell
# ImmyBot Install Script
$params = @{
    Mode           = 'Setup'
    KioskUrl       = 'https://checkin.myorganization.org'
    Username       = 'MPCheckin'
    BackgroundApps = @('C:\Program Files\QZ Tray\qz-tray.exe')
    AutoLogon      = $true
    Force          = $true
}
& ".\Deploy-Kiosk.ps1" @params
```

### Uninstall Script
Restores stock Windows explorer shell, deletes the local kiosk account, cleans CIM profiles from the registry, and deletes installation files.

```powershell
# ImmyBot Uninstall Script
$params = @{
    Mode     = 'Remove'
    Username = 'MPCheckin'
}
& ".\Deploy-Kiosk.ps1" @params
```

---

## Admin Escape Hatch & Maintenance

When physical maintenance is required on a machine booted into the kiosk session:

1. **Press the escape key combination**:
   `Ctrl + Alt + Shift + K` (default)
2. `KioskKeyBlocker.exe` instantly catches the combination and invokes Win32 `ExitWindowsEx(EWX_LOGOFF)`.
3. The machine returns to the Windows logon screen.
4. An administrator or technician can hold down `Shift` (to bypass auto-logon) and sign in with standard administrator credentials.
5. The administrator session boots cleanly into standard `explorer.exe` with a full desktop, start menu, and taskbar.

---

## Security & Hardening Reference

| Component | Mechanism | Security Effect |
| :--- | :--- | :--- |
| **Shell Replacement** | `HKCU\...\Winlogon\Shell` | Bypasses `explorer.exe` entirely for the kiosk user. No taskbar, Start menu, system tray, or notifications exist. |
| **Isolation** | Per-User Registry Hive | Administrative accounts and technicians maintain full stock desktop functionality. |
| **Hotkeys** | Low-Level Hook (`WH_KEYBOARD_LL`) | Traps and consumes OS switching shortcuts (`Alt+Tab`, `Alt+F4`, `LWin`, `RWin`, `Ctrl+Esc`). |
| **Ctrl+Alt+Del** | User System Policy Hive | Disables **Task Manager**, preventing end-users from killing the browser or spawning processes. |
| **Touch Hardening** | Chromium CLI Flags | Disables pinch-to-zoom (`--disable-pinch`) and horizontal swipe history navigation (`--overscroll-history-navigation=0`). |
| **Hook Timeout Defense** | Native Win32 Watchdog Timer | Windows silently unhooks unresponsive keyboard hooks. A 30s background timer continuously re-registers the hook to guarantee persistence. |

---

## Troubleshooting & Gotchas

### Error: `Kiosk HKCU Shell mismatch: 'wscript.exe ... launch.vbs'`
- **Cause**: The computer had an older legacy kiosk deployment using VBScript (`launch.vbs`). When `Deploy-Kiosk.ps1` ran without `-Force`, an active session or an orphaned user profile (`C:\Users\MPCheckin`) caused the audit to read the old shell from the lingering hive.
- **Solution**: Run with `-Force`. `Deploy-Kiosk.ps1` resolves profiles directly by user SID and actively cleans orphaned `Win32_UserProfile` entries before baking a clean profile.

### Error: Blocker Compilation Failed
- **Cause**: Outdated endpoint lacking `.NET Framework 4.5+` or endpoint protection software blocking memory compilation via `csc.exe`.
- **Solution**: Ensure `.NET Framework 4.6.2+` is present on the machine. Verify Defender/EDR is not blocking PowerShell from generating temporary assemblies in `%TEMP%`.

### Auto-Logon Not Engaging Upon Boot
- **Cause**: Windows Fast Startup or pre-existing Group Policy overriding `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.
- **Solution**: Ensure no domain GPO enforces a conflicting `AutoAdminLogon` or `LegalNoticeText` banner. Rebooting the endpoint (via ImmyBot maintenance session or manual restart) engages the newly registered AutoAdminLogon parameters cleanly.
