#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Monolithic Enable Kiosk Deployment, Shell Replacement, and Audit Tool for Windows 10/11 Pro+.

.DESCRIPTION
    A 100% self-contained, single-file PowerShell deployment script designed for RMM systems
    (ImmyBot, NinjaOne, Datto, Intune) and interactive administrators.

    Architecture & Key Highlights:
      - ZERO External Dependencies & Zero 3rd-Party Binaries:
        No AutoHotkey, Ahk2Exe, or legacy KioskCore.dll required.
      - In-Box Win32 P/Invoke Profile Baking:
        Compiles inline C# (advapi32.dll!LogonUser + userenv.dll!LoadUserProfile) via Add-Type
        to headlessly initialize local user profiles and NTUSER.DAT without interactive logon.
      - Native C# Low-Level Keyboard Blocker:
        Compiles a native, lightweight (~12KB) Windows GUI executable (KioskKeyBlocker.exe) on the
        endpoint using the in-box .NET Framework compiler (Add-Type).
        Features a 30-second hook watchdog timer, single-instance mutex, and configurable hotkeys.
      - Modern, Deprecation-Proof Shell Orchestration:
        Replaces deprecated VBScript (launch.vbs / wscript.exe) and batch files with a clean,
        hidden PowerShell script (launch.ps1) targeted at the kiosk user's HKCU Winlogon Shell.
      - Safe Per-User Isolation:
        Patches ONLY the kiosk user's HKCU registry hive via direct NTUSER.DAT mounting.
        HKLM\...\Winlogon\Shell remains untouched as 'explorer.exe' so Administrators, technicians,
        and Safe Mode sessions always boot to a standard desktop.
      - Touchscreen & Kiosk Hardening:
        Configures Microsoft Edge full-screen kiosk with touch-hardening flags (--disable-pinch,
        --overscroll-history-navigation=0, --no-first-run) and disables SAS options (Ctrl+Alt+Del).
      - Robust Lifecycle Management (Setup, Teardown, Verify):
        Actively evicts active kiosk sessions (quser/logoff), cleans locks, purges leftover
        numbered profiles (e.g. Kiosk.001), and provides an audit/verify mode for RMM compliance.

.PARAMETER Mode
    Operation mode:
      - Setup    : Deploys or updates the kiosk configuration.
      - Teardown : Fully cleans the kiosk user, user profiles, files, and restores default shell.
      - Verify   : Audits and tests the current machine kiosk status (returns exit code 0 or 1).
    Alias: Action. Default: Setup.

.PARAMETER KioskUrl
    Web kiosk: Target URL opened in Microsoft Edge full-screen kiosk mode. Mutually exclusive with -KioskApp.

.PARAMETER KioskApp
    App kiosk: Path to a local executable. Mutually exclusive with -KioskUrl.

.PARAMETER KioskAppArgs
    Command-line arguments passed to -KioskApp.

.PARAMETER Username
    Local Windows user account name for the kiosk session. Default: "Kiosk User".

.PARAMETER Password
    Optional fixed password for the kiosk user. If omitted, the account is created with a
    cryptographically strong temporary password during profile baking, which is then cleared.

.PARAMETER BackgroundApps
    Array or comma-separated string of executables to launch alongside the kiosk session
    (e.g., "C:\Program Files\QZ Tray\qz-tray.exe" for church check-in label printing).

.PARAMETER AutoLogon
    Enable automatic logon as the kiosk user on system boot.

.PARAMETER Force
    When deploying, automatically evicts any active session, tears down existing accounts/profiles
    with the same username, and redeploys completely fresh.

.PARAMETER BlockedKeys
    Array or comma-separated string of key combinations swallowed by the keyboard blocker.
    Default: 'Alt+F4,Alt+Tab,Alt+Shift+Tab,LWin,RWin,Ctrl+Esc,Ctrl+Shift+Esc,Alt+Space'.

.PARAMETER EscapeKey
    Keyboard shortcut that triggers clean logoff of the kiosk session (Admin escape hatch).
    Default: 'Ctrl+Alt+Shift+K'. Pass empty string '' to disable.

.PARAMETER DisableSasOptions
    Array or comma-separated subset of Ctrl+Alt+Del screen options to disable for the kiosk user:
    'DisableTaskMgr', 'DisableLockWorkstation', 'DisableChangePassword'.
    Default: 'DisableTaskMgr'. Pass empty string '' to leave Ctrl+Alt+Del fully stock.

.PARAMETER InstallPath
    Target directory for kiosk runtime files. Default: "C:\Program Files\Enable\Apps\Kiosk".

.EXAMPLE
    # Deploy a web check-in kiosk with auto-logon:
    .\Deploy-Kiosk.ps1 -KioskUrl "https://checkin.church.org" -AutoLogon -Force

.EXAMPLE
    # Verify kiosk installation status (useful for ImmyBot Test/Detection scripts):
    .\Deploy-Kiosk.ps1 -Mode Verify -Username "Kiosk User"

.EXAMPLE
    # Completely remove the kiosk and restore default Windows shell:
    .\Deploy-Kiosk.ps1 -Mode Teardown -Username "Kiosk User"
#>

[CmdletBinding()]
Param(
    [ValidateSet('Setup', 'Teardown', 'Verify')]
    [Alias('Action')]
    [string]$Mode = 'Setup',

    [string]$KioskUrl,
    [string]$KioskApp,
    [string]$KioskAppArgs,

    [string]$Username = 'Kiosk User',
    [string]$Password = $null,

    [object]$BackgroundApps = @(),

    [switch]$AutoLogon,
    [switch]$Force,

    [object]$BlockedKeys = @(
        'Alt+F4', 'Alt+Tab', 'Alt+Shift+Tab', 'LWin', 'RWin',
        'Ctrl+Esc', 'Ctrl+Shift+Esc', 'Alt+Space'
    ),

    [string]$EscapeKey = 'Ctrl+Alt+Shift+K',

    [object]$DisableSasOptions = @('DisableTaskMgr'),

    [string]$InstallPath = 'C:\Program Files\Enable\Apps\Kiosk'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# UI & Output Helpers
# ---------------------------------------------------------------------------
function Write-Step { param($Text) Write-Host "[*] $Text" -ForegroundColor White }
function Write-Ok   { param($Text) Write-Host "    [ok] $Text" -ForegroundColor Green }
function Write-Warn2{ param($Text) Write-Host "    [!] $Text" -ForegroundColor Yellow }
function Write-Fail { param($Text) Write-Host "[X] $Text" -ForegroundColor Red }

# Normalize arrays or comma-separated strings (essential for RMM UI compatibility)
function Normalize-StringList {
    param([object]$InputData)
    if ($null -eq $InputData) { return @() }
    if ($InputData -is [string]) {
        return @($InputData -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($InputData -is [System.Collections.IEnumerable]) {
        $res = @()
        foreach ($item in $InputData) {
            if ($null -ne $item -and "$item".Trim()) {
                $res += "$item".Trim()
            }
        }
        return $res
    }
    return @("$InputData".Trim())
}

# ---------------------------------------------------------------------------
# Embedded C# Win32 Profile Loader (Replaces KioskCore.dll)
# ---------------------------------------------------------------------------
function Add-KioskProfileLoader {
    if ('Enable.Kiosk.ProfileLoader' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Enable.Kiosk
{
    public static class ProfileLoader
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct PROFILEINFO
        {
            public int dwSize;
            public int dwFlags;
            public string lpUserName;
            public string lpProfilePath;
            public string lpDefaultPath;
            public string lpServerName;
            public string lpPolicyPath;
            public IntPtr hProfile;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LogonUser(string lpszUsername, string lpszDomain, string lpszPassword, int dwLogonType, int dwLogonProvider, out IntPtr phToken);

        [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LoadUserProfile(IntPtr hToken, ref PROFILEINFO lpProfileInfo);

        [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool UnloadUserProfile(IntPtr hToken, IntPtr hProfile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static void LoadProfile(string username, string password)
        {
            IntPtr token;
            if (!LogonUser(username, ".", password, 2 /* LOGON32_LOGON_INTERACTIVE */, 0, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            PROFILEINFO pi = new PROFILEINFO();
            pi.dwSize = Marshal.SizeOf(typeof(PROFILEINFO));
            pi.dwFlags = 1; // PI_NOUI
            pi.lpUserName = username;
            try
            {
                if (!LoadUserProfile(token, ref pi))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                if (pi.hProfile != IntPtr.Zero) UnloadUserProfile(token, pi.hProfile);
                CloseHandle(token);
            }
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# Embedded C# Win32 Low-Level Keyboard Blocker Source
# ---------------------------------------------------------------------------
$script:EmbeddedBlockerSource = @'
// ============================================================================
// KioskKeyBlocker.cs
// High-performance Win32 low-level keyboard blocker for Windows kiosk sessions.
// Features:
//   - Swallows key combinations specified in KioskKeyBlocker.cfg
//   - Configurable escape hotkey that cleanly logs off the kiosk user
//   - Re-registers low-level hook every 30s to defeat Windows hook timeout eviction
//   - Single-instance Named Mutex
// C# 5.0 compatible for in-box .NET Framework compiler (Add-Type)
// ============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Enable.Kiosk
{
    internal sealed class KeyRule
    {
        public uint Vk;
        public bool Ctrl, Alt, Shift, Win;
        public string Text;
    }

    internal static class Program
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int HC_ACTION = 0;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;
        private const int WM_TIMER = 0x0113;
        private const uint LLKHF_INJECTED = 0x10;

        private const uint VK_SHIFT = 0x10;
        private const uint VK_CONTROL = 0x11;
        private const uint VK_MENU = 0x12;
        private const uint VK_LWIN = 0x5B;
        private const uint VK_RWIN = 0x5C;

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int ptX;
            public int ptY;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public uint LowPart; public uint HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES
        {
            public int PrivilegeCount;
            public LUID Luid;
            public int Attributes;
        }

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr SetTimer(IntPtr hWnd, IntPtr nIDEvent, uint uElapse, IntPtr lpTimerFunc);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ExitWindowsEx(uint uFlags, uint dwReason);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LookupPrivilegeValue(string systemName, string name, out LUID luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, bool disableAllPrivileges, ref TOKEN_PRIVILEGES newState, int bufferLength, IntPtr previousState, IntPtr returnLength);

        private static IntPtr _hook = IntPtr.Zero;
        private static LowLevelKeyboardProc _proc;
        private static readonly List<KeyRule> _blockRules = new List<KeyRule>();
        private static KeyRule _escapeRule = null;
        private static bool _allowInjected = false;
        private static string _logPath = null;
        private static readonly object _logLock = new object();
        private static int _blockedCount = 0;

        static int Main(string[] args)
        {
            bool createdNew;
            using (Mutex mutex = new Mutex(true, "Enable_KioskKeyBlocker_SingleInstance", out createdNew))
            {
                if (!createdNew) return 0;

                string cfgPath = args.Length > 0
                    ? args[0]
                    : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "KioskKeyBlocker.cfg");
                LoadConfig(cfgPath);

                _proc = new LowLevelKeyboardProc(HookProc);
                if (!InstallHook()) return 3;

                // Watchdog timer: Refresh hook registration every 30s to defeat OS timeout eviction
                SetTimer(IntPtr.Zero, IntPtr.Zero, 30000, IntPtr.Zero);

                Log("KioskKeyBlocker started; " + _blockRules.Count + " block rule(s)"
                    + (_escapeRule != null ? "; escape=" + _escapeRule.Text : "; no escape rule"));

                MSG msg;
                while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
                {
                    if (msg.message == WM_TIMER) InstallHook();
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
                if (_hook != IntPtr.Zero) UnhookWindowsHookEx(_hook);
                Log("KioskKeyBlocker stopped");
                return 0;
            }
        }

        private static bool InstallHook()
        {
            if (_hook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hook);
                _hook = IntPtr.Zero;
            }
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero)
            {
                Log("FATAL: SetWindowsHookEx failed, error " + Marshal.GetLastWin32Error());
                return false;
            }
            return true;
        }

        private static IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode == HC_ACTION)
            {
                int msg = wParam.ToInt32();
                if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN || msg == WM_KEYUP || msg == WM_SYSKEYUP)
                {
                    KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                    bool injected = (k.flags & LLKHF_INJECTED) != 0;
                    if (_allowInjected || !injected)
                    {
                        bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
                        if (down && _escapeRule != null && Matches(_escapeRule, k.vkCode))
                        {
                            Log("Escape combo " + _escapeRule.Text + " -> logging off");
                            Thread worker = new Thread(DoLogoff);
                            worker.IsBackground = true;
                            worker.Start();
                            return (IntPtr)1;
                        }
                        for (int i = 0; i < _blockRules.Count; i++)
                        {
                            if (Matches(_blockRules[i], k.vkCode))
                            {
                                int n = Interlocked.Increment(ref _blockedCount);
                                if (n == 1 || n % 500 == 0) Log("Blocked " + _blockRules[i].Text + " (total " + n + ")");
                                return (IntPtr)1; // swallow key event
                            }
                        }
                    }
                }
            }
            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        private static bool Matches(KeyRule r, uint vk)
        {
            if (vk != r.Vk) return false;

            bool keyIsCtrl = (r.Vk == VK_CONTROL);
            bool keyIsAlt = (r.Vk == VK_MENU);
            bool keyIsShift = (r.Vk == VK_SHIFT);
            bool keyIsWin = (r.Vk == VK_LWIN || r.Vk == VK_RWIN);

            if (!keyIsCtrl && IsDown(VK_CONTROL) != r.Ctrl) return false;
            if (!keyIsAlt && IsDown(VK_MENU) != r.Alt) return false;
            if (!keyIsShift && IsDown(VK_SHIFT) != r.Shift) return false;
            if (!keyIsWin && ((IsDown(VK_LWIN) || IsDown(VK_RWIN)) != r.Win)) return false;
            return true;
        }

        private static bool IsDown(uint vk)
        {
            return (GetAsyncKeyState((int)vk) & 0x8000) != 0;
        }

        private static void DoLogoff()
        {
            try
            {
                IntPtr token;
                if (OpenProcessToken(GetCurrentProcess(), 0x0028, out token))
                {
                    LUID luid;
                    if (LookupPrivilegeValue(null, "SeShutdownPrivilege", out luid))
                    {
                        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                        tp.PrivilegeCount = 1;
                        tp.Luid = luid;
                        tp.Attributes = 0x2; // SE_PRIVILEGE_ENABLED
                        AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                    }
                }
            }
            catch { }
            ExitWindowsEx(0 /* EWX_LOGOFF */, 0);
        }

        private static void LoadConfig(string path)
        {
            if (!File.Exists(path))
            {
                AddBlockRule("Alt+F4");
                AddBlockRule("Alt+Tab");
                AddBlockRule("Alt+Shift+Tab");
                AddBlockRule("LWin");
                AddBlockRule("RWin");
                AddBlockRule("Ctrl+Esc");
                AddBlockRule("Ctrl+Shift+Esc");
                AddBlockRule("Alt+Space");
                _escapeRule = ParseCombo("Ctrl+Alt+Shift+K");
                return;
            }

            string[] lines = File.ReadAllLines(path);
            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].Trim();
                if (line.Length == 0 || line.StartsWith("#") || line.StartsWith(";")) continue;
                int eq = line.IndexOf('=');
                if (eq < 0) continue;
                string name = line.Substring(0, eq).Trim().ToLowerInvariant();
                string value = line.Substring(eq + 1).Trim();
                if (name == "block") AddBlockRule(value);
                else if (name == "escape") _escapeRule = ParseCombo(value);
                else if (name == "allowinjected") bool.TryParse(value, out _allowInjected);
                else if (name == "log") _logPath = value;
            }
        }

        private static void AddBlockRule(string combo)
        {
            KeyRule r = ParseCombo(combo);
            if (r != null) _blockRules.Add(r);
        }

        private static KeyRule ParseCombo(string combo)
        {
            if (string.IsNullOrEmpty(combo)) return null;
            string[] parts = combo.Split('+');
            KeyRule r = new KeyRule();
            r.Text = combo.Trim();
            for (int i = 0; i < parts.Length; i++)
            {
                string p = parts[i].Trim().ToLowerInvariant();
                if (p.Length == 0) return null;
                if (i < parts.Length - 1)
                {
                    if (p == "ctrl" || p == "control") r.Ctrl = true;
                    else if (p == "alt") r.Alt = true;
                    else if (p == "shift") r.Shift = true;
                    else if (p == "win" || p == "lwin" || p == "rwin") r.Win = true;
                    else return null;
                }
                else
                {
                    uint vk = KeyNameToVk(p);
                    if (vk == 0) return null;
                    r.Vk = vk;
                }
            }
            return r.Vk == 0 ? null : r;
        }

        private static uint KeyNameToVk(string p)
        {
            switch (p)
            {
                case "ctrl": case "control": return VK_CONTROL;
                case "alt": return VK_MENU;
                case "shift": return VK_SHIFT;
                case "lwin": return VK_LWIN;
                case "rwin": return VK_RWIN;
                case "esc": case "escape": return 0x1B;
                case "tab": return 0x09;
                case "space": return 0x20;
                case "del": case "delete": return 0x2E;
                case "enter": case "return": return 0x0D;
                case "backspace": return 0x08;
                case "apps": return 0x5D;
                case "prtsc": case "printscreen": return 0x2C;
                case "pause": return 0x13;
                case "capslock": return 0x14;
                case "numlock": return 0x90;
                case "scrolllock": return 0x91;
            }
            if (p.Length == 1)
            {
                char c = p[0];
                if (c >= 'a' && c <= 'z') return (uint)(c - 'a' + 0x41);
                if (c >= '0' && c <= '9') return (uint)(c - '0' + 0x30);
            }
            if (p.Length >= 2 && p[0] == 'f')
            {
                int n;
                if (int.TryParse(p.Substring(1), out n) && n >= 1 && n <= 24) return (uint)(0x70 + n - 1);
            }
            return 0;
        }

        private static void Log(string message)
        {
            try
            {
                string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message;
                if (_logPath != null)
                {
                    lock (_logLock) { File.AppendAllText(_logPath, line + Environment.NewLine); }
                }
            }
            catch { }
        }
    }
}
'@

# ---------------------------------------------------------------------------
# Registry Hive Mounting Helpers (Uses Native reg.exe to Prevent Provider Lock)
# ---------------------------------------------------------------------------
function Set-KioskUserHiveConfiguration {
    param(
        [string]$HivePath,
        [string]$ShellCommand,
        [string[]]$SasOptions
    )

    $mountName = "KioskHive_$([System.IO.Path]::GetRandomFileName().Replace('.', ''))"
    
    # 1. Mount Hive
    $loadRes = & reg.exe load "HKU\$mountName" "$HivePath" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg.exe load failed for $HivePath. Output: $loadRes" }

    $origEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'

        # 2. Redirect User Winlogon Shell using native reg.exe via cmd.exe (preserves inner quotes without CLI parsing corruption)
        $winlogonKey = "HKU\$mountName\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $escaped = $ShellCommand.Replace('"', '\"')
        $shellRes = cmd.exe /c "reg.exe add `"$winlogonKey`" /v Shell /t REG_SZ /d `"$escaped`" /f" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to set user HKCU Shell in ${winlogonKey}: $shellRes" }
        Write-Ok "HKCU Shell redirected -> $ShellCommand"

        # 3. Configure Ctrl+Alt+Del SAS Policies
        $policiesKey = "HKU\$mountName\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        foreach ($opt in @('DisableTaskMgr', 'DisableLockWorkstation', 'DisableChangePassword')) {
            if ($SasOptions -contains $opt) {
                & reg.exe add "$policiesKey" /v "$opt" /t REG_DWORD /d 1 /f 2>&1 | Out-Null
                Write-Ok "SAS policy: $opt = 1"
            } else {
                # Delete option if previously present (ignoring non-existent error)
                & reg.exe delete "$policiesKey" /v "$opt" /f 2>&1 | Out-Null
            }
        }

        # 4. Suppress Microsoft Edge First Run Experience in User Hive
        $edgeKey = "HKU\$mountName\Software\Policies\Microsoft\Edge"
        & reg.exe add "$edgeKey" /v "HideFirstRunExperience" /t REG_DWORD /d 1 /f 2>&1 | Out-Null
        Write-Ok "Suppressed Edge First Run Experience in user policies."
    }
    finally {
        $ErrorActionPreference = $origEAP
        # Release memory and unmount hive cleanly
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        $unmounted = $false
        for ($i = 0; $i -lt 10; $i++) {
            & reg.exe unload "HKU\$mountName" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $unmounted = $true; break }
            Start-Sleep -Milliseconds 300
        }
        if ($unmounted) {
            Write-Ok "User registry hive unmounted cleanly."
        } else {
            Write-Warn2 "Could not unmount HKU\$mountName immediately (will unmount upon reboot)."
        }
    }
}

# ---------------------------------------------------------------------------
# Session & Profile Eviction / Cleanup Helpers
# ---------------------------------------------------------------------------
function Invoke-SessionEviction {
    param([string]$TargetUser)
    try {
        $quserOutput = & quser 2>$null
        $global:LASTEXITCODE = 0
        if ($quserOutput) {
            foreach ($line in ($quserOutput -split "`r?`n" | Select-Object -Skip 1)) {
                $parts = $line.Trim() -split '\s+'
                if ($parts.Count -ge 3) {
                    $uName = $parts[0].TrimStart('>')
                    $sId = if ($parts[1] -match '^\d+$') { $parts[1] } else { $parts[2] }
                    if ($uName.ToLower() -eq $TargetUser.ToLower() -and $sId -match '^\d+$') {
                        Write-Warn2 "Logging off active session ID $sId for '$TargetUser'..."
                        & logoff $sId 2>&1 | Out-Null
                    }
                }
            }
            Start-Sleep -Seconds 2
        }
    } catch { }
}

function Remove-ProfileFolderAggressive {
    param([string]$FolderPath)
    if (-not (Test-Path $FolderPath)) { return $true }

    try {
        Remove-Item -Path $FolderPath -Recurse -Force -ErrorAction Stop
        return $true
    } catch { }

    try {
        cmd.exe /c "rmdir /s /q `"$FolderPath`"" 2>&1 | Out-Null
        if (-not (Test-Path $FolderPath)) { return $true }
    } catch { }

    try {
        takeown /f "$FolderPath" /r /d y 2>&1 | Out-Null
        icacls "$FolderPath" /grant "*S-1-5-32-544:F" /t /q 2>&1 | Out-Null
        Remove-Item -Path $FolderPath -Recurse -Force -ErrorAction Stop
        return $true
    } catch { }

    try {
        Write-Warn2 "Could not delete '$FolderPath' immediately. Scheduling deletion on next reboot."
        $pendingKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $existing = (Get-ItemProperty -Path $pendingKey -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        $newOps = @()
        if ($existing) { $newOps += $existing }
        $newOps += "\??\$FolderPath"
        $newOps += ""
        Set-ItemProperty -Path $pendingKey -Name PendingFileRenameOperations -Value $newOps -Type MultiString -Force
        return $false
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Setup Execution Routine
# ---------------------------------------------------------------------------
function Invoke-KioskSetup {
    # Resolve normalized lists
    $finalBlockedKeys = Normalize-StringList $BlockedKeys
    $finalSasOptions  = Normalize-StringList $DisableSasOptions
    $finalBgApps      = Normalize-StringList $BackgroundApps


    if ($KioskUrl -and $KioskApp) { Write-Fail "Specify -KioskUrl OR -KioskApp, not both."; exit 1 }
    if (-not $KioskUrl -and -not $KioskApp) { Write-Fail "Specify a target via -KioskUrl or -KioskApp."; exit 1 }

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  Enable Monolithic Kiosk Deployment (Standalone)" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  Mode        : Setup"
    Write-Host "  Kiosk       : $(if ($KioskUrl) { "Web -> $KioskUrl" } else { "App -> $KioskApp" })"
    Write-Host "  Username    : $Username"
    Write-Host "  BlockedKeys : $($finalBlockedKeys -join ', ')"
    Write-Host "  EscapeKey   : $(if ($EscapeKey) { $EscapeKey } else { '(disabled)' })"
    Write-Host "  SAS options : $(if ($finalSasOptions) { $finalSasOptions -join ', ' } else { '(none)' })"
    Write-Host "  AutoLogon   : $(if ($AutoLogon) { 'Enabled' } else { 'Disabled' })"
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host ""

    # -- 1: Local User Account & Profile Baking ------------------------------
    Write-Step "1/6 Kiosk user account and profile initialization"
    $userExists = [bool](Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)
    $profileDir = Join-Path (Join-Path $env:SystemDrive 'Users') $Username
    $hivePath   = Join-Path $profileDir 'NTUSER.DAT'

    if ($userExists) {
        if ($Force) {
            Write-Warn2 "User '$Username' exists and -Force was specified. Reinstalling..."
            Invoke-SessionEviction -TargetUser $Username
            Get-Process -Name 'KioskKeyBlocker','msedge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-LocalUser -Name $Username -ErrorAction SilentlyContinue
            
            # Clean CIM profile and folder to prevent orphaned .001 profile generation
            Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalPath -like "*\$Username" -or $_.LocalPath -like "*\$Username.*" } |
                Remove-CimInstance -ErrorAction SilentlyContinue
            Remove-ProfileFolderAggressive -FolderPath $profileDir | Out-Null
            
            $userExists = $false
        } else {
            Write-Warn2 "User '$Username' already exists. Updating configuration only (use -Force to reinstall)."
        }
    }

    # Clean any orphaned numbered profile folders (e.g. Username.001)
    $profilePattern = "^$([regex]::Escape($Username))(\..*|\.\d+)$"
    $leftovers = Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $profilePattern }
    foreach ($lo in $leftovers) {
        Write-Warn2 "Purging leftover profile folder: $($lo.FullName)"
        Remove-ProfileFolderAggressive -FolderPath $lo.FullName | Out-Null
    }

    if (-not $userExists) {
        Add-KioskProfileLoader

        # Generate a temporary password that satisfies all local complexity policies
        $hasPassword = [bool]$Password
        $tempPassword = if ($hasPassword) { $Password } else { "$([guid]::NewGuid().ToString('N'))K10sk!Aa" }
        $secPassword = ConvertTo-SecureString $tempPassword -AsPlainText -Force

        New-LocalUser -Name $Username -Password $secPassword -FullName $Username -AccountNeverExpires -PasswordNeverExpires | Out-Null
        Add-LocalGroupMember -Group 'Users' -Member $Username -ErrorAction SilentlyContinue

        Write-Ok "Baking user profile via Win32 LogonUser + LoadUserProfile..."
        [Enable.Kiosk.ProfileLoader]::LoadProfile($Username, $tempPassword)

        # If no explicit password was supplied, clear the password
        if (-not $hasPassword) {
            & net user "$Username" "" /y 2>&1 | Out-Null
        }
        Write-Ok "Account created and profile initialized."
    }

    # Verify NTUSER.DAT exists
    $retries = 10
    while ($retries -gt 0 -and -not (Test-Path $hivePath)) {
        Start-Sleep -Milliseconds 300
        $retries--
    }
    if (-not (Test-Path $hivePath)) { throw "NTUSER.DAT was not found at $hivePath." }

    # -- 2: System Auto-Logon Configuration ----------------------------------
    if ($AutoLogon) {
        Write-Step "2/6 Auto-logon configuration"
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1' -Type String -Force
        Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $Username -Type String -Force
        Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value '.' -Type String -Force
        Set-ItemProperty -Path $winlogon -Name ForceAutoLogon -Value '1' -Type String -Force
        if ($Password) {
            Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value $Password -Type String -Force
        } else {
            Remove-ItemProperty -Path $winlogon -Name DefaultPassword -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Auto-logon configured in HKLM."
    }

    # -- 3: Patch Kiosk User Registry (HKCU via Hive Mount) -------------------
    Write-Step "3/6 Kiosk user registry (HKCU isolation via hive mount)"
    $shellValue = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallPath\launch.ps1`""
    Set-KioskUserHiveConfiguration -HivePath $hivePath -ShellCommand $shellValue -SasOptions $finalSasOptions

    # -- 4: Generate Launch Files (launch.ps1) --------------------------------
    Write-Step "4/6 Generating launch files"
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

    $launchPs1 = New-Object System.Collections.Generic.List[string]
    $launchPs1.Add('$ErrorActionPreference = "Stop"')
    $launchPs1.Add('$dir = Split-Path -Parent $MyInvocation.MyCommand.Path')
    $launchPs1.Add('Start-Process -FilePath (Join-Path $dir "KioskKeyBlocker.exe") -WorkingDirectory $dir')

    if ($finalBgApps.Count -gt 0) {
        foreach ($app in $finalBgApps) {
            $launchPs1.Add("Start-Process -FilePath `"$app`"")
        }
    }

    if ($KioskUrl) {
        # Touchscreen-hardened Microsoft Edge invocation
        $edgePath = @(
            "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $edgePath) { $edgePath = 'msedge.exe' }

        $launchPs1.Add(@"
Start-Process -FilePath '$edgePath' -ArgumentList @(
    '--kiosk',
    '$KioskUrl',
    '--edge-kiosk-type=fullscreen',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-pinch',
    '--overscroll-history-navigation=0'
) -Wait
"@)
    } else {
        if ($KioskAppArgs) {
            $launchPs1.Add("Start-Process -FilePath `"$KioskApp`" -ArgumentList '$KioskAppArgs' -Wait")
        } else {
            $launchPs1.Add("Start-Process -FilePath `"$KioskApp`" -Wait")
        }
    }

    $launchPs1 | Out-File -FilePath (Join-Path $InstallPath 'launch.ps1') -Encoding ASCII -Force
    Write-Ok "launch.ps1 written -> $InstallPath\launch.ps1"

    # -- 5: Compile Native C# Key Blocker on Endpoint -------------------------
    Write-Step "5/6 Native keyboard blocker compilation"
    $cfgLines = New-Object System.Collections.Generic.List[string]
    $cfgLines.Add('# KioskKeyBlocker config - generated by Deploy-Kiosk.ps1')
    foreach ($k in $finalBlockedKeys) {
        if ($k) { $cfgLines.Add("block=$k") }
    }
    if ($EscapeKey) { $cfgLines.Add("escape=$EscapeKey") }
    $cfgLines.Add("log=$InstallPath\KioskKeyBlocker.log")
    $cfgLines | Out-File -FilePath (Join-Path $InstallPath 'KioskKeyBlocker.cfg') -Encoding ASCII -Force
    Write-Ok "KioskKeyBlocker.cfg generated ($($finalBlockedKeys.Count) block rules)."

    $blockerExe = Join-Path $InstallPath 'KioskKeyBlocker.exe'
    Get-Process -Name 'KioskKeyBlocker' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item $blockerExe -Force -ErrorAction SilentlyContinue

    Add-Type -TypeDefinition $script:EmbeddedBlockerSource -OutputAssembly $blockerExe -OutputType WindowsApplication
    if (-not (Test-Path $blockerExe)) { throw "Blocker compilation failed: $blockerExe not generated." }
    Write-Ok "KioskKeyBlocker.exe compiled successfully -> $blockerExe"

    # -- 6: Verification Audit ------------------------------------------------
    Write-Step "6/6 Verification Audit"
    $verified = Invoke-KioskVerify -Quiet

    if (-not $verified) {
        Write-Fail "Deployment verification checks failed."
        exit 1
    }

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  KIOSK SETUP COMPLETE" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  Next Step : $(if ($AutoLogon) { 'Reboot endpoint to test auto-logon.' } else { "Log out and sign in as '$Username'." })"
    Write-Host "  Admin Exit: Press $EscapeKey in the kiosk session to log off."
    Write-Host "  Teardown  : .\Deploy-Kiosk.ps1 -Mode Teardown -Username '$Username'"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Teardown Execution Routine
# ---------------------------------------------------------------------------
function Invoke-KioskTeardown {
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  Enable Kiosk Teardown" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  Target User : $Username"
    Write-Host "  Target Path : $InstallPath"
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host ""

    # 1. Evict active sessions and kill processes
    Write-Step "1/5 Evicting active kiosk sessions and terminating processes"
    Invoke-SessionEviction -TargetUser $Username
    $kioskProcs = @('KioskKeyBlocker', 'msedge')
    foreach ($p in $kioskProcs) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "Sessions evicted and processes terminated."

    # 2. Restore HKLM Shell and remove AutoLogon
    Write-Step "2/5 Restoring default Windows shell and purging auto-logon"
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name Shell -Value 'explorer.exe' -Force -ErrorAction SilentlyContinue
    foreach ($k in @('AutoAdminLogon', 'DefaultUserName', 'DefaultPassword', 'DefaultDomainName', 'ForceAutoLogon')) {
        Remove-ItemProperty -Path $winlogon -Name $k -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "HKLM Shell restored to explorer.exe."

    # 3. Remove local user account
    Write-Step "3/5 Removing local user account '$Username'"
    if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
        try {
            Remove-LocalUser -Name $Username -ErrorAction Stop
            Write-Ok "Local user '$Username' removed."
        } catch {
            & net user "$Username" /delete /y 2>&1 | Out-Null
            Write-Ok "Local user '$Username' removed via net user."
        }
    } else {
        Write-Ok "User '$Username' does not exist."
    }

    # 4. Remove user profile via CIM/WMI
    Write-Step "4/5 Removing user profiles and cleaning folders"
    $profilePath = Join-Path (Join-Path $env:SystemDrive 'Users') $Username
    $wmiProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -like "*\$Username" -or $_.LocalPath -like "*\$Username.*" }
    foreach ($wp in $wmiProfiles) {
        Write-Ok "Removing CIM profile: $($wp.LocalPath)"
        $wp | Remove-CimInstance -ErrorAction SilentlyContinue
    }

    # Purge profile directories on disk
    Remove-ProfileFolderAggressive -FolderPath $profilePath | Out-Null
    $pattern = "^$([regex]::Escape($Username))(\..*|\.\d+)$"
    $leftovers = Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern }
    foreach ($lo in $leftovers) {
        Write-Ok "Removing leftover folder: $($lo.FullName)"
        Remove-ProfileFolderAggressive -FolderPath $lo.FullName | Out-Null
    }

    # 5. Remove kiosk installation files
    Write-Step "5/5 Removing kiosk installation files"
    if (Test-Path $InstallPath) {
        try {
            Remove-Item -Path $InstallPath -Recurse -Force -ErrorAction Stop
            Write-Ok "Removed directory $InstallPath"
        } catch {
            $sm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
            $pending = (Get-ItemProperty -Path $sm -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
            $newOps = @("\??\$InstallPath", "")
            if ($pending) { $newOps = @($pending) + $newOps }
            Set-ItemProperty -Path $sm -Name PendingFileRenameOperations -Value $newOps -Type MultiString -Force
            Write-Warn2 "Scheduled $InstallPath deletion on next reboot."
        }
    }

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  TEARDOWN COMPLETE" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Verification / Compliance Audit Routine
# ---------------------------------------------------------------------------
function Invoke-KioskVerify {
    param([switch]$Quiet)

    $allPassed = $true

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host "  Kiosk Deployment Compliance Audit" -ForegroundColor Cyan
        Write-Host "======================================================" -ForegroundColor Cyan
    }

    # 1. Check Files
    foreach ($f in @('launch.ps1', 'KioskKeyBlocker.cfg', 'KioskKeyBlocker.exe')) {
        $full = Join-Path $InstallPath $f
        if (Test-Path $full) {
            if (-not $Quiet) { Write-Ok "File present: $f" }
        } else {
            if (-not $Quiet) { Write-Fail "MISSING: $full" }
            $allPassed = $false
        }
    }

    # 2. Check HKLM Shell Safety
    try {
        $hklmShell = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Shell -ErrorAction SilentlyContinue).Shell
        if ($hklmShell -eq 'explorer.exe') {
            if (-not $Quiet) { Write-Ok "HKLM Shell untouched (explorer.exe)" }
        } else {
            if (-not $Quiet) { Write-Warn2 "HKLM Shell = '$hklmShell' (expected explorer.exe)" }
        }
    } catch { }

    # 3. Check User Account
    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if ($user) {
        if (-not $Quiet) { Write-Ok "User account '$Username' exists" }
    } else {
        if (-not $Quiet) { Write-Fail "User account '$Username' NOT found" }
        $allPassed = $false
    }

    # 4. Check HKCU Shell in NTUSER.DAT
    $hivePath = Join-Path (Join-Path $env:SystemDrive 'Users') "$Username\NTUSER.DAT"
    if (Test-Path $hivePath) {
        $mountName = "AuditHive_$([System.IO.Path]::GetRandomFileName().Replace('.', ''))"
        $loaded = (& reg.exe load "HKU\$mountName" "$hivePath" 2>&1)
        if ($LASTEXITCODE -eq 0) {
            try {
                $userShell = (Get-ItemProperty -Path "Registry::HKEY_USERS\$mountName\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name Shell -ErrorAction SilentlyContinue).Shell
                if ($userShell -like '*launch.ps1*') {
                    if (-not $Quiet) { Write-Ok "Kiosk HKCU Shell correctly configured" }
                } else {
                    if (-not $Quiet) { Write-Fail "Kiosk HKCU Shell mismatch: '$userShell'" }
                    $allPassed = $false
                }
            } finally {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                & reg.exe unload "HKU\$mountName" 2>&1 | Out-Null
            }
        }
    } else {
        if (-not $Quiet) { Write-Fail "NTUSER.DAT not found on disk ($hivePath)" }
        $allPassed = $false
    }

    if (-not $Quiet) {
        Write-Host "======================================================" -ForegroundColor Cyan
        if ($allPassed) {
            Write-Host "  AUDIT RESULT: COMPLIANT" -ForegroundColor Green
        } else {
            Write-Host "  AUDIT RESULT: NON-COMPLIANT" -ForegroundColor Red
        }
        Write-Host ""
    }

    return $allPassed
}

# ---------------------------------------------------------------------------
# Main Entry Point
# ---------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "This script must be executed as Administrator or NT AUTHORITY\SYSTEM."
    exit 1
}

switch ($Mode) {
    'Setup' {
        Invoke-KioskSetup
        exit 0
    }
    'Teardown' {
        Invoke-KioskTeardown
        exit 0
    }
    'Verify' {
        $ok = Invoke-KioskVerify
        exit (if ($ok) { 0 } else { 1 })
    }
}
