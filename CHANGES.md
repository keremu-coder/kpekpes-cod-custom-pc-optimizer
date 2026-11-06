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
- `Controller.AllowUserWritablePython` default `false`. (point 3)

To get exactly the old behaviour back, put this in `C:\ProgramData\KpekpesCODCustom\config.json`:
`{ "HvciOff": true, "DisableToastNotifications": true, "UsePlatformTick": true, "ReapplyUserPreferences": true, "Controller": { "KeepAwake": "always", "TunedProfilePolicy": "overwrite", "AllowUserWritablePython": true } }`

## Controller module
- Stores the FULL Python path in the launcher (no PATH lookup); refuses a user-writable Python for the elevated task; offers `winget --scope machine`. (point 3)
- `ds4_optimize_final.py`: two added flags, `--keep-awake` and `--tuned-policy`. Defaults in the script itself are the old behaviour (`always`, `overwrite`), so running it by hand is unchanged. Everything else is byte-for-byte the same code.
- Tuned profile: a hash file (`.kpekpes-sha256`) remembers what the script wrote; an edited file is never overwritten, and Undo deletes it only if unedited.

## Tests / CI
- New `tests/Test-Roundtrip.ps1` (adapters, Defender, tasks, QoS, boot, services, hibernate, shadow storage; Safe and Full scenarios).
- Simplified `.github/workflows/windows-test.yml`: no patch step, 5 min limit on step 2, 8 min on step 3.
- Logic tests: 45 -> 113 checks.
