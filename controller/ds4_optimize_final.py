#!/usr/bin/env python3
"""
ds4_optimize_final.py - keep DS4Windows + your game running smooth. (clean final)

While this runs:
  * Windows timer set to its finest resolution (~0.5 ms)  <- the smooth feel
  * DS4Windows raised to HIGH priority
  * Windows power-throttling (EcoQoS) disabled for DS4Windows
  * PC kept awake (--keep-awake always|games|never; default always)
Close the window / Ctrl+C and everything returns to normal.

Profile:
  * Your profile is READ to print a stick report. It is NEVER overwritten.
  * With --strafe-boost / --tune it writes a COPY (<name>_tuned.xml) you can
    select in DS4Windows. Only the settings you ask for are changed.

Usage:
  python ds4_optimize_final.py
  python ds4_optimize_final.py --profile "C:\\...\\Profiles\\EUPHO.xml" --strafe-boost max
"""
import argparse
import ctypes
import hashlib
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

IS_WIN = os.name == "nt"
PROCS = ["DS4Windows.exe"]
# --keep-awake games: the PC is only held awake while one of these is running
GAME_EXES = ["cod.exe", "cod24.exe", "cod23.exe", "ModernWarfare.exe"]
TUNED_SIDECAR = ".kpekpes-sha256"   # remembers the hash of the _tuned.xml this script wrote

# Left-stick X (strafe) levels: (anti-deadzone %, max zone %)
STRAFE_LEVELS = {"mild": (6, 52), "strong": (10, 48), "max": (16, 40)}

# ---------------- system tweaks ----------------
def set_timer_resolution():
    if not IS_WIN:
        return None
    try:
        ctypes.WinDLL("winmm").timeBeginPeriod(1)
    except Exception:
        pass
    try:
        ntdll = ctypes.WinDLL("ntdll")
        cur = ctypes.c_ulong()
        mn, mx, cu = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_ulong()
        ntdll.NtQueryTimerResolution(ctypes.byref(mn), ctypes.byref(mx), ctypes.byref(cu))
        ntdll.NtSetTimerResolution(mx.value, True, ctypes.byref(cur))  # finest allowed
        # Windows 11: keep the request honored even when this window is minimized
        try:
            k32 = ctypes.WinDLL("kernel32")
            class PS(ctypes.Structure):
                _fields_ = [("Version", ctypes.c_ulong), ("ControlMask", ctypes.c_ulong), ("StateMask", ctypes.c_ulong)]
            ps = PS(1, 0x4, 0)  # PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION
            k32.SetProcessInformation(k32.GetCurrentProcess(), 4, ctypes.byref(ps), ctypes.sizeof(ps))
        except Exception:
            pass
        return cur.value / 10000.0
    except Exception:
        return 1.0

def keep_awake(on=True):
    if not IS_WIN:
        return
    try:
        ES_CONTINUOUS, ES_SYSTEM, ES_DISPLAY = 0x80000000, 0x1, 0x2
        flags = ES_CONTINUOUS | (ES_SYSTEM | ES_DISPLAY if on else 0)
        ctypes.WinDLL("kernel32").SetThreadExecutionState(flags)
    except Exception:
        pass

def is_admin():
    if not IS_WIN:
        return False
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False

def find_pids(name):
    try:
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {name}", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    pids = []
    for line in out.splitlines():
        parts = [p.strip('"') for p in line.split('","')]
        if len(parts) > 1 and parts[0].lower() == name.lower():
            try:
                pids.append(int(parts[1]))
            except ValueError:
                continue
    return pids

def any_running(names):
    """True if any of the given image names is running (one tasklist call)."""
    try:
        out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return False
    low = {n.lower() for n in names}
    for line in out.splitlines():
        parts = [p.strip('"') for p in line.split('","')]
        if parts and parts[0].lower() in low:
            return True
    return False

def boost_process(pid):
    try:
        k32 = ctypes.WinDLL("kernel32")
        h = k32.OpenProcess(0x0200 | 0x1000, False, pid)  # SET_INFORMATION | QUERY_LIMITED
        if not h:
            return False
        ok = bool(k32.SetPriorityClass(h, 0x80))  # HIGH_PRIORITY_CLASS
        class PS(ctypes.Structure):
            _fields_ = [("Version", ctypes.c_ulong), ("ControlMask", ctypes.c_ulong), ("StateMask", ctypes.c_ulong)]
        ps = PS(1, 0x1 | 0x4, 0)  # disable EcoQoS + honor timer resolution
        k32.SetProcessInformation(h, 4, ctypes.byref(ps), ctypes.sizeof(ps))
        k32.CloseHandle(h)
        return ok
    except Exception:
        return False

# ---------------- profile (read-only) ----------------
def g(root, tag, default=None):
    el = root.find(tag)
    return el.text if el is not None and el.text is not None else default

def load_profile(path):
    if not os.path.isfile(path):
        print(f"\nProfile not found: {path}")
        print("  (Check the path in the launcher. Continuing with system tweaks only.)")
        return None
    try:
        return ET.parse(path).getroot()
    except ET.ParseError as e:
        print(f"\nCould not read profile {path}: {e}")
        print("  (File looks damaged. Continuing with system tweaks only.)")
        return None

def report(path, root):
    print(f"\nProfile: {path}")
    for s in ("LS", "RS"):
        try:
            dz = float(g(root, f"{s}DeadZone", "0"))
            adz = float(g(root, f"{s}AntiDeadZone", "0"))
            mz = float(g(root, f"{s}MaxZone", "100"))
        except ValueError:
            print(f"  {s}: could not read stick values (skipping)")
            continue
        curve = g(root, f"{s}OutputCurveMode", "linear")
        if g(root, f"{s}DeadZoneType", "Radial") == "Axial":
            ax = root.find(f"{s}AxialDeadOptions")
            if ax is not None:
                print(f"  {s} (Axial): X max zone {g(ax,'MaxZoneX')}%, X anti-dz {g(ax,'AntiDeadZoneX')}%  "
                      f"| Y max zone {g(ax,'MaxZoneY')}%, Y anti-dz {g(ax,'AntiDeadZoneY')}%")
        print(f"  {s}: deadzone {dz:.0f}/127 ({dz/127*100:.1f}%), anti-deadzone {adz:.0f}%, "
              f"max zone {mz:.0f}%, curve {curve}")
        if s == "RS":
            if dz / 127 > 0.10:
                print("    tip: RS deadzone is large - small aim adjustments get swallowed. Try 4-8 if your stick has no drift.")
            if adz == 0:
                print("    tip: anti-deadzone is 0 - if your game has its own deadzone, 15-25% makes tiny moves register.")
            if mz < 90:
                print("    tip: max zone under 90% reaches full speed early - can feel twitchy.")

def _set(parent, tag, value):
    """Set parent/tag to value (creating the tag if missing). Returns the old text."""
    el = parent.find(tag)
    if el is None:
        el = ET.SubElement(parent, tag)
    old = el.text
    el.text = str(value)
    return old

def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def tuned_was_edited(out):
    """True if <out> exists and is not exactly what this script wrote last time (or we cannot tell)."""
    if not os.path.isfile(out):
        return False
    side = out + TUNED_SIDECAR
    try:
        with open(side, "r", encoding="ascii") as f:
            return f.read().strip().lower() != _sha256(out)
    except OSError:
        return True   # no record of writing it -> treat it as the user's file

def write_tuned(path, args):
    try:
        tree = ET.parse(path)
    except (OSError, ET.ParseError) as e:
        print(f"\nCould not write tuned copy: {e}")
        return
    root = tree.getroot()
    print("\nChanges (old -> new):")
    n_changes = 0

    # Optional stick settings: only what you pass on the command line
    options = {"RSDeadZone": args.rs_deadzone, "RSAntiDeadZone": args.rs_antideadzone,
               "RSMaxZone": args.rs_maxzone, "LSDeadZone": args.ls_deadzone}
    for tag, val in options.items():
        if val is None:
            continue
        old = _set(root, tag, val)
        print(f"  {tag}: {old} -> {val}")
        n_changes += 1

    if args.strafe_boost:
        # Left/right strafe = LS X axis only. Forward/back (Y), the LS curve,
        # the vertical scale and the whole right stick are left exactly as they are.
        anti_x, max_x = STRAFE_LEVELS[args.strafe_boost]
        old = _set(root, "LSDeadZoneType", "Axial")
        if old != "Axial":
            print(f"  LSDeadZoneType: {old} -> Axial")
        ax = root.find("LSAxialDeadOptions")
        if ax is None:
            ax = ET.SubElement(root, "LSAxialDeadOptions")
        old_a = _set(ax, "AntiDeadZoneX", anti_x)
        old_m = _set(ax, "MaxZoneX", max_x)
        print(f"  LS X anti-deadzone: {old_a} -> {anti_x}")
        print(f"  LS X max zone:      {old_m} -> {max_x}")
        print(f"Strafe boost '{args.strafe_boost}' applied: LS X anti-deadzone {anti_x}%, X max zone {max_x}%")
        n_changes += 2

    if n_changes == 0:
        print("  (nothing to change)")
        return

    base, ext = os.path.splitext(path)
    if base.endswith("_tuned"):
        base = base[: -len("_tuned")]   # never produce _tuned_tuned.xml
    out = f"{base}_tuned{ext}"
    policy = getattr(args, "tuned_policy", "overwrite")
    if policy == "preserve-edits" and tuned_was_edited(out):
        print(f"\nKept your edited tuned profile (not overwritten): {out}")
        return
    try:
        tree.write(out, encoding="utf-8", xml_declaration=True)
        if policy == "preserve-edits":
            with open(out + TUNED_SIDECAR, "w", encoding="ascii") as f:
                f.write(_sha256(out))
    except OSError as e:
        print(f"\nCould not save tuned copy: {e}")
        return
    print(f"\nWrote tuned COPY: {out}\n(Original untouched. Select it in DS4Windows to try it.)")

# ---------------- main ----------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile")
    ap.add_argument("--tune", action="store_true", help="write a _tuned.xml copy")
    ap.add_argument("--rs-deadzone", type=int)
    ap.add_argument("--rs-antideadzone", type=int)
    ap.add_argument("--rs-maxzone", type=int)
    ap.add_argument("--ls-deadzone", type=int)
    ap.add_argument("--strafe-boost", choices=list(STRAFE_LEVELS),
                    help="faster left/right strafe response (writes a copy)")
    ap.add_argument("--game", action="append", default=[], help="game .exe to boost too, e.g. --game cod.exe")
    ap.add_argument("--keep-awake", choices=["always", "games", "never"], default="always",
                    help="when to hold the PC/monitor awake (default: always, as before)")
    ap.add_argument("--tuned-policy", choices=["overwrite", "preserve-edits"], default="overwrite",
                    help="preserve-edits: never overwrite a _tuned.xml you changed (default: overwrite, as before)")
    args = ap.parse_args()

    if args.profile:
        root = load_profile(args.profile)
        if root is not None:
            report(args.profile, root)
            if args.tune or args.strafe_boost:
                write_tuned(args.profile, args)

    if not IS_WIN:
        print("\nSystem tweaks only work on Windows.")
        return

    if not is_admin():
        print("\nNOTE: not running as administrator - DS4Windows priority boost may fail.")
        print("      Use the launcher (ds4_launch_final.bat), it asks for admin for you.")

    res = set_timer_resolution()
    awake = (args.keep_awake == "always")
    keep_awake(awake)
    print(f"\nTimer resolution: {res:.2f} ms" if res else "\nTimer resolution: unchanged")
    targets = PROCS + args.game
    boosted = set()
    print("Optimizer running. Leave this window open (minimized is fine). Ctrl+C to stop.\n")
    try:
        while True:
            for name in targets:
                for pid in find_pids(name):
                    if pid not in boosted:
                        print(("Boosted " if boost_process(pid) else "Could not boost (run as admin?) ") + f"{name} [{pid}]", flush=True)
                        boosted.add(pid)
            if args.keep_awake == "games":
                want = any_running(GAME_EXES)
                if want != awake:
                    awake = want
                    keep_awake(awake)
                    print("Game running - holding PC awake." if awake else "No game running - sleep allowed again.", flush=True)
            time.sleep(5)
    except KeyboardInterrupt:
        pass
    finally:
        keep_awake(False)
        try:
            ctypes.WinDLL("winmm").timeEndPeriod(1)
        except Exception:
            pass
        print("Stopped. Windows back to normal.")

if __name__ == "__main__":
    main()
