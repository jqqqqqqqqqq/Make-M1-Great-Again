#!/usr/bin/env python3
"""
Add custom refresh rates to an Apple display on Apple Silicon by appending a
DisplayID Type I timing block to its EDID, then shipping that EDID as a macOS
display override plist.

Apple Silicon (M1/M2/M3...) builds its mode list from the DisplayID extension
blocks in the EDID, not from the legacy CTA-861 block. The Studio Display XDR
ships 6 EDID blocks: a base block plus five DisplayID 1.2 sections holding the
stock 47.95/48/50/59.94/60/120 Hz timings. Appending a seventh block with extra
Type I detailed timings is enough to make macOS offer them.

Subcommands:
  dump    <edid.bin>          decode an EDID and print every timing
  build                       generate the patched EDID + override plist
  read                        read the live EDID out of ioreg

The timing generator reproduces Apple's stock 60 Hz and 120 Hz timings
bit-for-bit, so generated modes match what the panel already accepts.
"""

import argparse
import math
import plistlib
import re
import subprocess
import sys

# --- Apple's timing formula -------------------------------------------------
# Derived by solving against the stock timings in the Studio Display XDR EDID.
# It is CVT reduced-blanking v1 with two Apple-specific constants: a fixed
# 80-pixel horizontal blanking interval (CVT-RB uses 160) and the standard
# 460 us minimum vertical blanking period.

H_FRONT_PORCH = 8
H_SYNC_WIDTH = 32
H_BACK_PORCH = 40  # -> hblank = 80
V_SYNC_WIDTH = 8
V_BACK_PORCH = 6
MIN_V_BLANK_US = 460.0

CLOCK_STEP_HZ = 10_000  # DisplayID pixel clock granularity


class Timing:
    def __init__(self, hactive, vactive, refresh, pixel_clock, htotal, vtotal,
                 hfp, hsw, hpol, vfp, vsw, vpol, preferred=False):
        self.hactive, self.vactive = hactive, vactive
        self.refresh = refresh
        self.pixel_clock = pixel_clock
        self.htotal, self.vtotal = htotal, vtotal
        self.hfp, self.hsw, self.hpol = hfp, hsw, hpol
        self.vfp, self.vsw, self.vpol = vfp, vsw, vpol
        self.preferred = preferred

    @property
    def actual_refresh(self):
        return self.pixel_clock / (self.htotal * self.vtotal)

    @property
    def h_rate_khz(self):
        return self.pixel_clock / self.htotal / 1000

    @property
    def v_blank_us(self):
        """Duration of the vertical blanking interval. Apple's own timings sit
        at >= 460 us; below that is off-spec and the panel may refuse to latch."""
        return (self.vtotal - self.vactive) / (self.pixel_clock / self.htotal) * 1e6

    def __str__(self):
        pref = " PREFERRED" if self.preferred else ""
        return (f"{self.hactive}x{self.vactive} @ {self.actual_refresh:8.4f} Hz | "
                f"pclk={self.pixel_clock / 1e6:9.3f} MHz htot={self.htotal} vtot={self.vtotal} "
                f"hfp={self.hfp} hsw={self.hsw}{'+' if self.hpol else '-'} "
                f"vfp={self.vfp} vsw={self.vsw}{'+' if self.vpol else '-'} "
                f"hrate={self.h_rate_khz:.1f} kHz vblank={self.v_blank_us:.0f}us{pref}")


H_BLANK_MIN = 24  # hfp 8 + hsw 8 + hbp 8, the tightest split worth emitting


def split_hblank(hblank):
    """Divide a horizontal blanking budget into front porch / sync / back porch.

    Reproduces Apple's own 8/32/40 exactly at the default 80, then gives ground
    from the back porch first and the sync width only once that hits its floor.
    """
    if hblank < H_BLANK_MIN:
        raise ValueError(f"horizontal blanking {hblank} is below the {H_BLANK_MIN}px floor")
    hfp = H_FRONT_PORCH
    hsw = min(H_SYNC_WIDTH, hblank - hfp - 8)
    hbp = hblank - hfp - hsw
    if hbp < 8:
        hsw = hblank - hfp - 8
        hbp = 8
    return hfp, hsw, hbp


def make_timing(hactive, vactive, refresh, preferred=False, pixel_clock=None,
                vtotal=None, fit_clock=None, hblank=None):
    """Generate an Apple-style reduced-blanking timing.

    pixel_clock (in Hz) may be given to pin the clock exactly; otherwise it is
    rounded to the nearest 10 kHz, which is the convention Apple's own stock
    timings use.

    vtotal overrides the derived vertical total, which is how you buy refresh
    rate on a host whose pixel clock is capped: pclk = htotal * vtotal * refresh,
    so shrinking the vertical blanking interval raises the rate the same clock
    can carry. fit_clock (Hz) does that search automatically, keeping as much
    blanking as the ceiling allows since more blanking is the safer choice.
    """
    # Shrinking horizontal blanking lengthens the vertical blanking interval a
    # given clock can afford: vblank_time = 1/refresh - vactive * htotal / pclk.
    hfp, hsw, hbp = split_hblank(
        hblank if hblank is not None else H_FRONT_PORCH + H_SYNC_WIDTH + H_BACK_PORCH)
    htotal = hactive + hfp + hsw + hbp
    min_vtotal = vactive + V_SYNC_WIDTH + V_BACK_PORCH + 1

    if vtotal is None:
        # vtotal such that the vertical blanking interval lasts >= 460 us.
        # vblank = ceil(460us * refresh * vtotal)  ->  solve for vtotal.
        vtotal = math.ceil(vactive / (1 - (MIN_V_BLANK_US / 1e6) * refresh))
        if fit_clock is not None and htotal * vtotal * refresh > fit_clock:
            vtotal = int(fit_clock // (htotal * refresh))
            if vtotal < min_vtotal:
                raise ValueError(
                    f"{hactive}x{vactive}@{refresh}: cannot fit under "
                    f"{fit_clock / 1e6:.2f} MHz — needs vtotal {vtotal}, but "
                    f"{min_vtotal} is the floor ({vactive} active + sync + porch)")

    if vtotal < min_vtotal:
        raise ValueError(
            f"{hactive}x{vactive}@{refresh}: vtotal {vtotal} is below the "
            f"{min_vtotal} floor ({vactive} active + sync + porch)")
    vfp = vtotal - vactive - V_SYNC_WIDTH - V_BACK_PORCH

    if pixel_clock is None:
        pixel_clock = round(htotal * vtotal * refresh / CLOCK_STEP_HZ) * CLOCK_STEP_HZ
        # Rounding up must not breach a ceiling the caller asked us to respect.
        if fit_clock is not None and pixel_clock > fit_clock:
            pixel_clock = int(fit_clock // CLOCK_STEP_HZ) * CLOCK_STEP_HZ

    return Timing(hactive, vactive, refresh, pixel_clock, htotal, vtotal,
                  hfp, hsw, 1, vfp, V_SYNC_WIDTH, 0, preferred)


# --- DisplayID Type I encoding ---------------------------------------------

def encode_type1(t: Timing) -> bytes:
    """Encode one 20-byte DisplayID Type I detailed timing descriptor."""
    if t.pixel_clock % CLOCK_STEP_HZ:
        raise ValueError("pixel clock must be a multiple of 10 kHz")
    out = bytearray()
    out += (t.pixel_clock // CLOCK_STEP_HZ - 1).to_bytes(3, "little")
    out += bytes([0x80 if t.preferred else 0x00])          # flags
    out += (t.hactive - 1).to_bytes(2, "little")
    out += (t.htotal - t.hactive - 1).to_bytes(2, "little")  # hblank
    out += ((t.hfp - 1) | (t.hpol << 15)).to_bytes(2, "little")
    out += (t.hsw - 1).to_bytes(2, "little")
    out += (t.vactive - 1).to_bytes(2, "little")
    out += (t.vtotal - t.vactive - 1).to_bytes(2, "little")  # vblank
    out += ((t.vfp - 1) | (t.vpol << 15)).to_bytes(2, "little")
    out += (t.vsw - 1).to_bytes(2, "little")
    assert len(out) == 20
    return bytes(out)


def decode_type1(d: bytes) -> Timing:
    pixel_clock = (int.from_bytes(d[0:3], "little") + 1) * CLOCK_STEP_HZ
    flags = d[3]
    hactive = int.from_bytes(d[4:6], "little") + 1
    hblank = int.from_bytes(d[6:8], "little") + 1
    raw_hfp = int.from_bytes(d[8:10], "little")
    hsw = int.from_bytes(d[10:12], "little") + 1
    vactive = int.from_bytes(d[12:14], "little") + 1
    vblank = int.from_bytes(d[14:16], "little") + 1
    raw_vfp = int.from_bytes(d[16:18], "little")
    vsw = int.from_bytes(d[18:20], "little") + 1
    htotal, vtotal = hactive + hblank, vactive + vblank
    return Timing(hactive, vactive, pixel_clock / (htotal * vtotal), pixel_clock,
                  htotal, vtotal,
                  (raw_hfp & 0x7FFF) + 1, hsw, raw_hfp >> 15,
                  (raw_vfp & 0x7FFF) + 1, vsw, raw_vfp >> 15,
                  bool(flags & 0x80))


# DisplayID section headers. `legacy` is what this tool emitted originally and
# what the deployed 87 Hz EDID uses. `apple` matches the stock sections in this
# panel's own EDID: DisplayID 1.2, product type 0 ("extension section", i.e. this
# section extends the primary display description rather than describing a
# separate product). Whether that changes how macOS treats the timings —
# specifically whether it grants them DiscreteMediaRefreshRates — is the reason
# it is selectable.
SECTION_STYLES = {
    "legacy": (0x11, 0x03),
    "apple": (0x12, 0x00),
}


def build_displayid_block(timings, label="CustomEDID", style="legacy") -> bytes:
    """Build a 128-byte EDID extension holding one DisplayID section."""
    try:
        version, product_type = SECTION_STYLES[style]
    except KeyError:
        raise ValueError(f"unknown section style {style!r}; "
                         f"expected one of {', '.join(SECTION_STYLES)}")
    data = bytearray()

    timing_payload = b"".join(encode_type1(t) for t in timings)
    if len(timing_payload) > 251:
        raise ValueError("too many timings for one DisplayID section")
    data += bytes([0x03, 0x00, len(timing_payload)]) + timing_payload   # Type I timings

    tag = label.encode("ascii")
    data += bytes([0x0B, 0x00, len(tag)]) + tag                        # ASCII string

    section = bytearray([version, len(data), product_type, 0x00]) + data  # ver, len, type, ext
    section.append((-sum(section)) & 0xFF)                             # DisplayID checksum

    block = bytearray([0x70]) + section                                # EDID extension tag
    block += bytes(127 - len(block))
    block.append((-sum(block)) & 0xFF)                                 # EDID block checksum
    assert len(block) == 128
    return bytes(block)


def patch_edid(stock: bytes, timings, label="CustomEDID", style="legacy") -> bytes:
    if len(stock) % 128:
        raise ValueError(f"EDID length {len(stock)} is not a multiple of 128")
    if stock[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
        raise ValueError("missing EDID header")
    if sum(stock[:128]) % 256:
        raise ValueError("base block checksum is bad")

    base = bytearray(stock[:128])
    if base[126] != len(stock) // 128 - 1:
        raise ValueError(f"extension count {base[126]} disagrees with {len(stock)} bytes")

    base[126] += 1                                                     # one more extension
    base[127] = (base[127] - 1) & 0xFF                                 # keep checksum at 0
    assert sum(base) % 256 == 0

    return bytes(base) + stock[128:] + build_displayid_block(timings, label, style)


# --- EDID decoding (for verification) ---------------------------------------

DISPLAYID_TAGS = {
    0x00: "Product ID", 0x01: "Display Parameters", 0x02: "Color Characteristics",
    0x03: "Type I Detailed Timing", 0x0B: "ASCII String",
    0x0C: "Display Device", 0x12: "Tiled Display Topology", 0x7F: "Vendor Specific",
}


def dump(edid: bytes):
    print(f"{len(edid)} bytes / {len(edid) // 128} blocks")
    base = edid[:128]
    vendor = int.from_bytes(base[8:10], "big")
    letters = "".join(chr(64 + ((vendor >> s) & 0x1F)) for s in (10, 5, 0))
    print(f"  vendor 0x{vendor:04x} ({letters})  product 0x{int.from_bytes(base[10:12], 'little'):04x}  "
          f"serial {int.from_bytes(base[12:16], 'little')}")
    print(f"  extensions {base[126]}  checksum {'ok' if sum(base) % 256 == 0 else 'BAD'}")

    for i in range(0, len(edid), 128):
        blk = edid[i:i + 128]
        n = i // 128
        ok = "ok" if sum(blk) % 256 == 0 else "BAD"
        if n == 0:
            continue
        if blk[0] != 0x70:
            print(f"\nblock {n}: tag 0x{blk[0]:02x} (not DisplayID)  checksum {ok}")
            continue
        seclen = blk[2]
        print(f"\nblock {n}: DisplayID v0x{blk[1]:02x} section={seclen}B type={blk[3]}  checksum {ok}")
        off, end = 5, 5 + seclen
        while off + 3 <= end:
            tag, _rev, ln = blk[off], blk[off + 1], blk[off + 2]
            payload = blk[off + 3:off + 3 + ln]
            if tag == 0x03:
                print(f"    [0x03] {DISPLAYID_TAGS[0x03]} ({ln}B)")
                for j in range(ln // 20):
                    print(f"        {decode_type1(payload[j * 20:(j + 1) * 20])}")
            elif tag == 0x0B:
                print(f"    [0x0b] ASCII String: {payload.decode('ascii', 'replace')!r}")
            elif ln:
                print(f"    [0x{tag:02x}] {DISPLAYID_TAGS.get(tag, 'unknown')} ({ln}B)")
            off += 3 + ln


# --- live EDID + override plist ---------------------------------------------

def load_edid(path: str) -> bytes:
    """Read an EDID from a file, accepting either raw bytes or a hex dump.

    `read` writes hex, so accepting both means its output can be fed straight
    back to `dump`. A real EDID always starts with a 0x00 byte, which is not a
    hex digit, so the two are never confusable.
    """
    raw = open(path, "rb").read()
    text = raw.strip()
    if text and all(c in b"0123456789abcdefABCDEF \n\r\t" for c in text):
        compact = b"".join(text.split())
        if len(compact) % 2 == 0:
            return bytes.fromhex(compact.decode("ascii"))
    return raw


def read_live_edid() -> bytes:
    out = subprocess.run(["ioreg", "-lw0"], capture_output=True, text=True, check=True).stdout
    matches = re.findall(r'"EDID" = <([0-9a-f]+)>', out)
    if not matches:
        sys.exit("No EDID found in ioreg - is an external display connected?")
    # Longest match wins if several displays are attached.
    return bytes.fromhex(max(matches, key=len))


def build_plist(edid: bytes, name: str, extra: dict) -> bytes:
    base = edid[:128]
    payload = {
        "DisplayVendorID": int.from_bytes(base[8:10], "big"),
        "DisplayProductID": int.from_bytes(base[10:12], "little"),
        "DisplayProductName": name,
        "IODisplayEDID": edid,
    }
    payload.update(extra)
    return plistlib.dumps(payload, sort_keys=True)


class ModeSpec:
    """A parsed --mode, turned into a Timing once --fit-clock is known."""

    def __init__(self, hactive, vactive, refresh, clock=None, vtotal=None, vblank=None,
                 hblank=None):
        self.hactive, self.vactive, self.refresh = hactive, vactive, refresh
        self.clock, self.vtotal, self.vblank = clock, vtotal, vblank
        self.hblank = hblank

    def build(self, fit_clock=None) -> Timing:
        vtotal = self.vtotal
        if vtotal is None and self.vblank is not None:
            vtotal = self.vactive + self.vblank
        return make_timing(self.hactive, self.vactive, self.refresh,
                           pixel_clock=self.clock, vtotal=vtotal,
                           fit_clock=fit_clock, hblank=self.hblank)


MODE_KEYS = ("vtot", "vblank", "hblank")


def parse_mode(spec: str) -> ModeSpec:
    """WIDTHxHEIGHT@RATE[:PIXELCLOCK_MHZ][/KEY=N ...]

    :MHZ pins the clock exactly. /vtot= or /vblank= overrides the derived
    vertical blanking, and /hblank= the horizontal — the two levers for trading
    blanking against refresh rate under a fixed pixel-clock ceiling. Suffixes
    may be combined, e.g. 5120x2880@88/hblank=32.
    """
    head, *rest = spec.strip().split("/")
    m = re.fullmatch(r"(\d+)x(\d+)@([\d.]+)(?::([\d.]+))?", head)
    if not m:
        raise argparse.ArgumentTypeError(
            f"expected WIDTHxHEIGHT@RATE[:PIXELCLOCK_MHZ], got {head!r}")

    opts = {}
    for part in rest:
        km = re.fullmatch(r"(\w+)=(\d+)", part)
        if not km or km[1] not in MODE_KEYS:
            raise argparse.ArgumentTypeError(
                f"expected /KEY=N with KEY in {'|'.join(MODE_KEYS)}, got {part!r}")
        if km[1] in opts:
            raise argparse.ArgumentTypeError(f"{km[1]} given twice in {spec!r}")
        opts[km[1]] = int(km[2])
    if "vtot" in opts and "vblank" in opts:
        raise argparse.ArgumentTypeError(f"give vtot or vblank, not both, in {spec!r}")

    clock = round(float(m[4]) * 1e6) if m[4] else None
    return ModeSpec(int(m[1]), int(m[2]), float(m[3]), clock,
                    opts.get("vtot"), opts.get("vblank"), opts.get("hblank"))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("dump", help="decode an EDID file")
    p.add_argument("path")

    sub.add_parser("read", help="write the live EDID from ioreg to stdout as hex")

    p = sub.add_parser("build", help="generate patched EDID + override plist")
    p.add_argument("--stock", default="edid/studio-display-xdr-stock.bin",
                   help="stock EDID to patch (default: %(default)s)")
    p.add_argument("--mode", type=parse_mode, action="append", required=True,
                   metavar="WxH@RATE[:MHZ][/vtot=N]", help="mode to add; repeatable")
    p.add_argument("--fit-clock", type=float, metavar="MHZ",
                   help="pixel-clock ceiling; shrinks vertical blanking as needed "
                        "to fit each mode under it, keeping as much as it can")
    p.add_argument("--name", default="Studio Display XDR", help="DisplayProductName")
    p.add_argument("--label", default="CustomEDID", help="ASCII tag inside the DisplayID block")
    p.add_argument("--section", choices=sorted(SECTION_STYLES), default="legacy",
                   help="DisplayID section header: 'legacy' (1.1, product type 3) or "
                        "'apple' (1.2, type 0), matching this panel's stock sections "
                        "(default: %(default)s)")
    p.add_argument("--out-edid", default="build/patched.bin")
    p.add_argument("--out-plist", default="build/DisplayProductID-ae42")
    p.add_argument("--preserve", metavar="PLIST",
                   help="carry over scale-resolutions/IOGFlags/policies from an existing override")

    args = ap.parse_args()

    if args.cmd == "dump":
        dump(load_edid(args.path))
        return

    if args.cmd == "read":
        print(read_live_edid().hex())
        return

    stock = load_edid(args.stock)
    print(f"stock EDID: {args.stock} ({len(stock)} bytes, {len(stock) // 128} blocks)\n")

    fit = round(args.fit_clock * 1e6) if args.fit_clock else None
    try:
        timings = [spec.build(fit) for spec in args.mode]
    except ValueError as exc:
        sys.exit(f"error: {exc}")

    print("adding timings:")
    for t in timings:
        print(f"  {t}")
        if abs(t.actual_refresh - t.refresh) > 0.01:
            print(f"      note: rounds to {t.actual_refresh:.4f} Hz on the 10 kHz clock grid")
        if fit and t.pixel_clock > fit:
            print(f"      WARNING: {t.pixel_clock / 1e6:.2f} MHz exceeds the "
                  f"{fit / 1e6:.2f} MHz ceiling")
        # Apple's own stock timings land at 461-467 us, so a couple of us under
        # 460 is not worth a warning; only a real shortfall is.
        if t.v_blank_us < MIN_V_BLANK_US * 0.98:
            print(f"      WARNING: {t.v_blank_us:.0f}us vertical blanking is "
                  f"{t.v_blank_us / MIN_V_BLANK_US * 100:.0f}% of Apple's "
                  f"{MIN_V_BLANK_US:.0f}us convention; the panel may refuse it")

    patched = patch_edid(stock, timings, args.label, args.section)

    extra = {}
    if args.preserve:
        src = plistlib.load(open(args.preserve, "rb"))
        src = src.get("SwitchResX backup settings", src)  # prefer the pristine copy
        for key in ("scale-resolutions", "IOGFlags",
                    "display-refresh-rate-policy", "display-rotation-policy"):
            if key in src:
                extra[key] = src[key]
        print(f"\npreserved from {args.preserve}: {', '.join(sorted(extra)) or '(nothing)'}")

    import os
    for path in (args.out_edid, args.out_plist):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    open(args.out_edid, "wb").write(patched)
    open(args.out_plist, "wb").write(build_plist(patched, args.name, extra))

    print(f"\nwrote {args.out_edid} ({len(patched)} bytes)")
    print(f"wrote {args.out_plist}")
    print("\n--- verification ---")
    dump(patched)


if __name__ == "__main__":
    main()
