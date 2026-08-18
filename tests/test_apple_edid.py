#!/usr/bin/env python3
"""Self-contained tests for apple_edid.py. No dependencies, no hardware.

Run:  python3 tests/test_apple_edid.py
Exits non-zero on the first failure, so it works as a CI gate.
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from apple_edid import (  # noqa: E402
    CLOCK_STEP_HZ,
    MIN_V_BLANK_US,
    decode_type1,
    encode_type1,
    load_edid,
    make_timing,
    patch_edid,
    split_hblank,
)

REPO = os.path.join(os.path.dirname(__file__), "..")
STOCK = os.path.join(REPO, "edid", "studio-display-xdr-stock.bin")

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name}" + (f" — {detail}" if detail else ""))


def stock_timings(edid):
    """Every DisplayID Type I timing in an EDID."""
    out = []
    for b in range(1, len(edid) // 128):
        blk = edid[b * 128:(b + 1) * 128]
        if blk[0] != 0x70:
            continue
        off, end = 5, 5 + blk[2]
        while off < end - 2:
            tag, _rev, dlen = blk[off], blk[off + 1], blk[off + 2]
            if tag == 0 and dlen == 0:
                break
            if tag == 0x03:
                for i in range(off + 3, off + 3 + dlen, 20):
                    out.append(decode_type1(blk[i:i + 20]))
            off += 3 + dlen
    return out


# --- the timing formula reproduces Apple's own timings ----------------------
# This is what validates the formula: feed it only (width, height, rate) and it
# must land on the exact pixel clock and blanking Apple shipped.
#
# The one documented exception is the NTSC-derived 47.9522 Hz variant. Apple
# reuses the 48 Hz geometry (vtot 2946) and divides the clock by 1.001, rather
# than re-deriving vtot from the 460 us rule, which would give 2945.

NTSC_VARIANT_RATE = 47.9522

print("Apple timing formula vs the stock EDID")
edid = load_edid(STOCK)
timings = stock_timings(edid)
check("stock EDID parses to 12 Type I timings", len(timings) == 12, f"got {len(timings)}")

reproduced = exceptions = 0
for t in timings:
    rate = round(t.actual_refresh, 4)
    g = make_timing(t.hactive, t.vactive, rate)
    same = (g.pixel_clock == t.pixel_clock and g.htotal == t.htotal
            and g.vtotal == t.vtotal and g.hfp == t.hfp and g.hsw == t.hsw
            and g.vfp == t.vfp and g.vsw == t.vsw)
    if same:
        reproduced += 1
    elif abs(rate - NTSC_VARIANT_RATE) < 0.001:
        exceptions += 1
    else:
        check(f"reproduce {t.hactive}x{t.vactive}@{rate}", False,
              f"vtot {g.vtotal} vs {t.vtotal}, pclk {g.pixel_clock} vs {t.pixel_clock}")

check("11 of 12 stock timings reproduce bit-for-bit", reproduced == 11, f"got {reproduced}")
check("the only exception is the 47.9522 Hz NTSC variant", exceptions == 1, f"got {exceptions}")

# --- encode / decode round-trip --------------------------------------------

print("\nDisplayID Type I encoding")
for spec in [(5120, 2880, 87.0), (5120, 2880, 60.0), (3840, 2160, 120.0419),
             (2560, 1440, 100.0)]:
    t = make_timing(*spec)
    r = decode_type1(encode_type1(t))
    check(f"round-trip {spec[0]}x{spec[1]}@{spec[2]}",
          (r.pixel_clock, r.htotal, r.vtotal, r.hfp, r.hsw, r.vfp, r.vsw)
          == (t.pixel_clock, t.htotal, t.vtotal, t.hfp, t.hsw, t.vfp, t.vsw))
check("descriptor is exactly 20 bytes", len(encode_type1(make_timing(5120, 2880, 87.0))) == 20)

# --- blanking controls ------------------------------------------------------

print("\nblanking overrides")
a = make_timing(5120, 2880, 88.0, vtotal=2930)
b = make_timing(5120, 2880, 88.0, vtotal=2880 + 50)
check("vtot= and vblank= agree", encode_type1(a) == encode_type1(b))

check("default hblank reproduces Apple's 8/32/40", split_hblank(80) == (8, 32, 40))
check("back porch yields before sync width", split_hblank(48) == (8, 32, 8))
check("sync width yields once back porch bottoms out", split_hblank(32) == (8, 16, 8))
check("tightest split is 8/8/8", split_hblank(24) == (8, 8, 8))
try:
    split_hblank(16)
    check("hblank below floor refused", False)
except ValueError:
    check("hblank below floor refused", True)

t = make_timing(5120, 2880, 88.0, hblank=40)
check("hblank= changes htotal", t.htotal == 5160, f"got {t.htotal}")

# --- fit-clock --------------------------------------------------------------

print("\nfit-clock ceiling")
CEIL = 1356_000_000
for rate in (87.0, 88.0, 89.0, 90.0):
    t = make_timing(5120, 2880, rate, fit_clock=CEIL)
    check(f"{rate} Hz fits under 1356 MHz", t.pixel_clock <= CEIL,
          f"got {t.pixel_clock/1e6:.2f} MHz")
    check(f"{rate} Hz keeps vtotal above the active lines", t.vtotal > 2880)
try:
    make_timing(5120, 2880, 91.0, fit_clock=CEIL)
    check("91 Hz refused under 1356 MHz", False)
except ValueError:
    check("91 Hz refused under 1356 MHz", True)

t = make_timing(5120, 2880, 60.0, fit_clock=CEIL)
check("a mode that already fits is left at the 460us convention",
      t.v_blank_us >= MIN_V_BLANK_US, f"got {t.v_blank_us:.0f}us")

try:
    make_timing(5120, 2880, 87.0, vtotal=2880)
    check("vtotal below the active lines refused", False)
except ValueError:
    check("vtotal below the active lines refused", True)

# --- patched EDID structure -------------------------------------------------

print("\npatched EDID structure")
patched = patch_edid(edid, [make_timing(5120, 2880, 87.0, pixel_clock=1355_840_000,
                                        vtotal=2997)])
check("grows by exactly one 128-byte block", len(patched) == len(edid) + 128)
check("keeps the EDID header", patched[:8] == b"\x00\xff\xff\xff\xff\xff\xff\x00")
check("extension count in byte 126 matches", patched[126] == len(patched) // 128 - 1,
      f"byte126={patched[126]}, blocks={len(patched)//128}")
bad = [i for i in range(len(patched) // 128)
       if sum(patched[i * 128:(i + 1) * 128]) % 256 != 0]
check("every block checksum is valid", not bad, f"bad blocks: {bad}")
check("the added timing decodes back", any(
    abs(t.actual_refresh - 87.0) < 0.01 for t in stock_timings(patched)))

check("pixel clock stays on the 10 kHz grid",
      make_timing(5120, 2880, 87.0).pixel_clock % CLOCK_STEP_HZ == 0)

# --- CLI --------------------------------------------------------------------

print("\ncommand line")


def run(args):
    return subprocess.run([sys.executable, os.path.join(REPO, "apple_edid.py")] + args,
                          capture_output=True, text=True, cwd=REPO)

r = run(["dump", STOCK])
check("dump decodes the stock EDID", r.returncode == 0 and "vendor 0x0610" in r.stdout)

r = run(["build", "--mode", "5120x2880@88/vtot=2963/vblank=83",
         "--out-edid", "/dev/null", "--out-plist", "/dev/null"])
check("vtot and vblank together refused", r.returncode != 0)

r = run(["build", "--mode", "5120x2880@88/bogus=1",
         "--out-edid", "/dev/null", "--out-plist", "/dev/null"])
check("unknown mode key refused", r.returncode != 0)

r = run(["build", "--mode", "not-a-mode",
         "--out-edid", "/dev/null", "--out-plist", "/dev/null"])
check("malformed mode refused", r.returncode != 0)

r = run(["build", "--fit-clock", "1356", "--mode", "5120x2880@91",
         "--out-edid", "/dev/null", "--out-plist", "/dev/null"])
check("impossible mode fails cleanly, no traceback",
      r.returncode != 0 and "Traceback" not in r.stderr, r.stderr[-200:])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
