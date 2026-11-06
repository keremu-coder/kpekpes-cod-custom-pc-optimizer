# Kpekpes COD Custom PC Optimizer

**By Jesus Kpekpes**

A maximum-performance Windows setup for Call of Duty on PC, plus a DS4Windows controller optimizer.
Both parts keep a journal of every change they make, so each one can be undone on its own.

---

## Two modules

| Module | What it does | Undo |
|---|---|---|
| **PC** | Windows tuning for Call of Duty: power plan, Game Mode off, scheduling, network, services, debloat, game-process priority | Undo PC |
| **Controller** | DS4Windows helper: 0.5 ms timer, High priority for DS4Windows, strafe-boost profile (left stick X only) | Undo Controller |

Run either one, or both one after the other (PC first, then Controller). Undo is separate for each.

## Quick start

1. Download the ZIP and extract the whole folder.
2. Run **`Run_Kpekpes.bat`**. It opens the menu in an Administrator window.
3. Pick **1** (PC), **2** (Controller) or **3** (both).
4. Restart Windows once.

Run it from the Windows account you actually play on. Several settings are per-user.

```
1) Optimize PC                     5) Undo PC
2) Optimize Controller (DS4Windows) 6) Undo Controller
3) Optimize BOTH                   7) Undo BOTH
4) Verify (read-only)              8) Compare two frame captures
```

Command line (Administrator PowerShell):

```powershell
.\Kpekpes.ps1 -Action Optimize -Module Both
.\Kpekpes.ps1 -Action Verify -Detailed
.\Kpekpes.ps1 -Action Undo -Module Controller
.\Kpekpes.ps1 -Action Optimize -Module PC -WhatIf      # shows what it would do, changes nothing
.\Kpekpes.ps1 -Action Compare -Before before.csv -After after.csv
```

---

## How undo works

Before anything is changed, its original state is written to a journal on disk
(`C:\ProgramData\KpekpesCODCustom\<module>\journal.json`). That includes "this value did not exist", so undo
deletes it instead of leaving it behind. The first recorded state is kept forever. Running the tool twice, or
letting the logon task re-apply it, never turns the tweaked state into the "original".

Undo puts back: registry values and keys, service start types, boot options, power plan, TCP settings, adapter
settings, Defender exclusions, scheduled tasks, files the tool created, and your DS4Windows profile's
`LaunchProgram` line. It then re-reads what it restored and reports `restored X of Y`. Anything it could not
restore is listed and the journal is kept so you can run Undo again.

One exception: the Xbox / Game Bar apps are removed from Windows. Windows cannot bring a removed app back
by itself, so Undo opens the Microsoft Store search for you to reinstall them.

A System Restore point is also created first. The module repairs the usual reasons it fails (shadow copy
services, System Protection, storage size) and retries. If a restore point still cannot be made, the run
continues because the journal is the real undo. If the journal cannot be written, nothing is changed.

---

## PC module (maximum profile)

There is one profile: maximum. Each group can be switched off in `C:\ProgramData\KpekpesCODCustom\config.json`.

- **Power plan:** its own plan ("Kpekpes COD Custom Max"), 100% min/max processor state, aggressive boost,
  performance energy preference, USB/PCIe power saving off, hibernate and fast startup off.
- **Game Mode off**, Game Bar and Game DVR off, MPO off, Auto HDR off, hardware GPU scheduling on.
- **Timer:** 0.5 ms resolution held by a small background task, dynamic tick off. (Platform tick is opt-in: `UsePlatformTick`.)
- **Network:** Nagle off, TCP tuned, wired-adapter power saving, interrupt moderation and flow control off, QoS tag for `cod.exe`.
- **Services:** SysMain, DiagTrack, Windows Search and a few more disabled.
- **Windows Update control:** no driver updates from Windows Update, no auto-reboot while you are logged in, no Store auto-download.
- **Xbox apps removed**, Copilot / widgets / suggestions off. (Toast notifications off is opt-in: `DisableToastNotifications`, because it can hide Windows Security alerts.)
- **Memory integrity / VBS / hypervisor off: opt-in only** (`HvciOff`, default false). Back up your BitLocker recovery key before turning it on.
- **Game process:** High CPU and I/O priority entries for the game and DS4Windows, high-performance GPU preference, fullscreen optimizations off.
- **Defender exclusions for exact paths** (the game, Battle.net, DS4Windows). Not bare file names.
- **Logon re-apply:** re-applies the PC tweaks at every logon, since Windows updates can undo them.
  Create an empty file named `PAUSE` in `C:\ProgramData\KpekpesCODCustom` to skip it. By default it leaves your mouse / visual / input choices alone (`ReapplyUserPreferences`: false).

The GPU driver's own registry key is not written to.

### Do this by hand once (NVIDIA)

NVIDIA Control Panel, Manage 3D settings, Program Settings, add `cod.exe`, **Power management mode = Prefer
maximum performance**. A script cannot read back or undo per-app driver profiles safely, so this one stays manual.

### Honest notes

- **Some tweaks are applied but give no FPS.** The MMCSS "Games" values, `NetworkThrottlingIndex`,
  `SystemResponsiveness`, `Win32PrioritySeparation` (2 is the Windows default) and the Nagle/TCP values (Call
  of Duty uses UDP) are marked "no FPS gain expected" in the report. They are harmless. Measure for yourself with the frame comparison below.
- **What lowers security:** Defender exclusions and driver updates blocked in Windows Update (plus memory integrity / VBS off, only if you opt in). Secure Boot, TPM, UAC and Defender real-time protection are not touched.
- **If you opt in to `HvciOff`**, the hypervisor launch is also turned off, which stops WSL2, Hyper-V, Docker and Windows Sandbox. Undo restores it.
- Windows Search is disabled, so Start-menu search is limited.
- Install your GPU, chipset and network drivers **before** using the Windows Update driver block, then update drivers by hand.

---

## Controller module

Wraps the DS4Windows optimizer script in `controller\`. It needs **Python 3** (the installer offers to install it with winget).

- Finds DS4Windows, keeps **your** profile as it is (the bundled `EUPHO.xml` is only copied if the profile is missing).
- Sets the profile's Launch Program to the hidden launcher and writes `<profile>_tuned.xml` with the strafe boost
  (`max` = anti-deadzone 16%, max zone 40%, **left stick X only**). The right stick and the curves are untouched.
  **Select the `_tuned` profile in DS4Windows to use it.**
- Installs the scripts into a protected folder and starts them hidden, elevated, at every logon through a scheduled task.
  The folder is read-only for normal users, because the task runs with admin rights.
- Raises DS4Windows to High priority, turns off power throttling for it, and holds the timer at its finest resolution.
- Verify checks: one optimizer running, DS4Windows priority, tuned profile values, task registered and elevated.

Settings in `config.json` under `Controller`:

- `"StrafeBoost": "mild" | "strong" | "max"`
- `"KeepAwake": "games" | "always" | "never"` - `games` (default) holds the PC awake only while cod.exe is running; `always` is the old behaviour.
- `"TunedProfilePolicy": "preserve-edits" | "overwrite"` - `preserve-edits` (default) never overwrites a `_tuned.xml` you edited; `overwrite` is the old behaviour.
- `"AllowUserWritablePython": false` - the elevated task refuses a Python that normal users can edit. Install one for all users: `winget install -e --id Python.Python.3.12 --scope machine`.

---

## Score and checks

- **Applied score** = passed / (passed + failed). Each tweak is read back from Windows. Not-applicable items and
  warnings are listed but never counted as passes.
- **Readiness** (read-only, not part of the score): Secure Boot, TPM, RAM speed (heuristic), monitor refresh vs the
  panel's listed modes, wired vs Wi-Fi, Resizable BAR, startup apps, free disk space.
- **Real results:** capture a minute of gameplay before and after with PresentMon or CapFrameX (CSV export), then
  run option 8 (or `-Action Compare`). It reports average FPS, 1% and 0.1% lows and frame-time jitter.

## Files

| Path | Purpose |
|---|---|
| `Run_Kpekpes.bat` | Launcher (asks Windows for admin) |
| `Kpekpes.ps1` | Menu and command line |
| `lib\Core.ps1`, `lib\Journal.ps1`, `lib\Checks.ps1` | Config, undo journal, readiness checks, frame comparison |
| `modules\Pc.ps1`, `modules\Controller.ps1` | The two modules |
| `controller\` | DS4 optimizer script, launcher templates, default profile |
| `tests\Test-Logic.ps1` | Tests for the logic that does not need Windows (`pwsh tests/Test-Logic.ps1`) |
| `tests\Test-Roundtrip.ps1` | Real-Windows round trip (GitHub Actions only): snapshot, optimize, undo, compare |
| `.github\workflows\windows-test.yml` | The GitHub Actions test |

## Disclaimer

Free to use, modify and share (MIT). No warranty. This changes system settings on purpose; use it at your own risk,
and run **Verify** and the `-WhatIf` mode first if you want to see what it will do.
