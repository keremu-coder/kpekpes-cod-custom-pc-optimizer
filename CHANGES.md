# Changes in 1.3.0 (proposed: audit fixes + measurement maths)

The logic behind these changes is checked by `tests/Test-Logic.ps1` (120 checks) and the new `tests/Test-Stats.ps1` (53 checks).
Both suites pass under PowerShell 7. The Windows-only parts (ACL checks, CPU probe, scheduled tasks, the seeded
round trip) parse cleanly but must be confirmed by `windows-test.yml` on a real Windows runner.

## Security fixes
- **No elevated task launches DS4Windows any more.** The elevated controller bat only boosts DS4Windows; DS4Windows
  itself is started by a new NON-elevated logon task `Kpekpes DS4Windows Start`. Before, replacing `DS4Windows.exe`
  in Downloads/Desktop (no admin needed) gave silent admin rights at the next logon.
- **The tuned profile is written once at install** (`--write-only`), not by the elevated logon task into a
  user-writable profile folder.
- **Defender exclusions only for folders a normal account cannot change** (`lib/Safety.ps1`: trusted owner, no
  write rights for non-admins, no junctions, checked up to the drive root). `%LOCALAPPDATA%\Battle.net`, Downloads
  and user-writable Steam libraries are reported as "not excluded" instead of silently excluded.
- **`Protect-KDir` takes ownership first** (`icacls /setowner Administrators`), so a folder pre-created by a normal
  user can no longer keep its owner's power to rewrite the permissions.

## CPU-aware defaults
- Exact CCD count from the L3 caches (`lib/Topology.ps1`) replaces "8 cores or fewer = single CCD".
- On dual-CCD X3D chips (7900X3D / 7950X3D / 9900X3D / 9950X3D) core parking, Game Mode and Game Bar are kept:
  AMD's V-Cache driver needs all three.
- Game Mode is now left at the Windows default. `GameModeOff` (opt-in) turns it off, never on dual-CCD X3D.

## Undo
- Registry entries record what the tool wrote; Undo reports values changed afterwards by you or Windows ("drift").
- Every entry carries its tweak group. `-Action Undo -Module PC -Group 'Scheduling'` undoes one group only,
  which makes per-group A/B testing possible.

## Measurement (`lib/Stats.ps1`)
- Compare accepts several captures per side (`-Before a.csv,b.csv,c.csv -After ...`) and gives each metric a
  95 % interval (wider of Welch t and bootstrap) and a verdict: better / worse / no real difference / not enough data.
- New metrics: time-weighted 1 % low, frame-to-frame jitter (replaces the standard deviation, which counted smooth
  drift as jitter), stutter count and stutter time, input-to-photon latency when PresentMon records it.
- Displayed-frame times (`MsBetweenDisplayChange`) are preferred over present-to-present times.
- ABBA run order (cancels linear drift exactly), latency model, VRR cap formula, stick-response model, placebo-free score.
- The launcher's marketing comment is replaced by a plain description of what it does.

## Tests
- `Test-Stats.ps1` (new) runs in CI. `Test-Roundtrip.ps1 -Seeds 3` adds three runs that start from random existing
  values (absent / other value / other type) to prove Undo(Optimize(S)) = S for more than one starting state.

---

# Changes in this version

Nothing was removed. Everything that worked still works; new behaviour is behind config switches.

## Fixes (found by the real-Windows test)
- Undo now restores a service's DelayedAutostart flag exactly (set it, or remove it) and checks it. (finding A)
- Hibernate journal now records whether `HibernateEnabled` existed and its value; undo restores it exactly. (finding B)
- Restore-point repair is now journaled: VSS/swprv start types and the shadow-storage size are put back on Undo. System Protection is never turned off by Undo (that would delete restore points); a note is shown instead. (point 7)
- Test-Logic.ps1 no longer runs the endless optimizer: it calls `write_tuned` through a helper with a 30 s limit.

## New config switches (config.json), safe defaults
- `HvciOff` default `false` (opt-in). (point 1)
- `DisableToastNotifications` default `false` (opt-in; can hide Windows Security alerts). (point 2)
- `UsePlatformTick` default `false` (opt-in; `disabledynamictick` is kept). (point 4)
- `ReapplyUserPreferences` default `false`: logon re-apply skips the mouse / visual / input group. (point 8)
- `Controller.KeepAwake` default `games` (`always` = old behaviour, `never`). (point 5)
- `Controller.TunedProfilePolicy` default `preserve-edits` (`overwrite` = old behaviour). (point 6)

To get exactly the old behaviour back, put this in `C:\ProgramData\KpekpesCODCustom\config.json`:
`{ "HvciOff": true, "DisableToastNotifications": true, "UsePlatformTick": true, "ReapplyUserPreferences": true, "Controller": { "KeepAwake": "always", "TunedProfilePolicy": "overwrite" } }`

## Controller module
- Controller optimizer: two added flags, `--keep-awake` and `--tuned-policy`. Defaults in the script itself are the old behaviour (`always`, `overwrite`), so running it by hand is unchanged. Everything else is byte-for-byte the same code.
- Tuned profile: a hash file (`.kpekpes-sha256`) remembers what the script wrote; an edited file is never overwritten, and Undo deletes it only if unedited.

## Tests / CI
- New `tests/Test-Roundtrip.ps1` (adapters, Defender, tasks, QoS, boot, services, hibernate, shadow storage; Safe and Full scenarios).
- Simplified `.github/workflows/windows-test.yml`: no patch step, 5 min limit on step 2, 8 min on step 3.
- Logic tests: 45 -> 113 checks.
