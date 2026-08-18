# custom-edid — custom refresh rates on Apple Silicon

Adds a **5120×2880 @ 87 Hz** mode to an Apple Studio Display XDR driven by an
M1 Max Mac Studio, which otherwise offers only 60 Hz. A free replacement for
SwitchResX for this one job, plus a written-up account of *why* the usual
approaches fail on Apple Silicon and where the real hardware limit is.

Two findings, neither of which is the 87 Hz:

1. The display-override plist every guide tells you to write **does nothing** on
   Apple Silicon. The mechanism that works is a private IOKit call that has to be
   reapplied at runtime.
2. The thing that caps refresh rate is not pixel clock and not blanking. It is
   the display pipe's **active-pixel throughput**, around **1.283 Gpixel/s** on
   an M1 Max — which is almost exactly the 6K60 the chip is advertised for.

> **Correction notice.** The first published version of this document claimed
> three limits: a ~1356 MHz pixel clock ceiling, a 395–449 µs vertical blanking
> floor, and an 80 px minimum horizontal blanking. **All three were wrong**, and
> the [methodology section](#how-those-numbers-were-got-wrong-first) explains the
> mistake, because it is an easy one to repeat.

## Result

| | |
| --- | --- |
| Hardware | Mac Studio (M1 Max, `J375cAP`) + Studio Display XDR (`0x0610:0xae42`) |
| Stock | 5120×2880 @ 60 Hz |
| Achieved | 5120×2880 @ **87.00 Hz**, `htot 5200 vtot 2997`, 1355.84 MHz, 449 µs vblank |
| Limited by | M1 Max display-pipe active-pixel throughput (~1.283 Gpx/s) |

![System Settings showing Refresh rate: Adaptive (47-87 Hertz)](Proof%20of%20refresh%20rate.png)

macOS reports it as an adaptive 47–87 Hz range, because it advertises a
variable-refresh range topping out at the fastest timing available.

## Quick start

> **These numbers are specific to a Studio Display XDR (`0x0610:0xae42`) on an
> M1 Max.** The throughput budget is a property of the SoC. On anything else,
> start at [Adapting this to other hardware](#adapting-this-to-other-hardware).
> `avedid apply` refuses an EDID whose vendor/product no connected display
> reports, so a copy-paste on the wrong machine fails closed — but it cannot tell
> that a *plausible* timing is wrong for your panel.

```bash
# 1. build the injector
mkdir -p build && swiftc -O -o build/avedid avedid.swift

# 2. generate a patched EDID containing the extra timing
python3 apple_edid.py build --mode 5120x2880@87:1355.84/vtot=2997

# 3. install it — takes effect in about a second, no reboot
./build/avedid apply build/patched.bin

# 4. make it survive reboots and sleep/wake
./install-agent.sh build/patched.bin 87
```

Then pick 87 Hz in **System Settings → Displays**, or `./build/avedid set-hz 87`.

To undo everything: `./uninstall-agent.sh && ./build/avedid revert`. Nothing that
affects boot is written to disk, so a reboot alone also restores the stock EDID.

## Building and running

Requirements: an Apple Silicon Mac, macOS 12 or later, and the Xcode command line
tools for `swiftc` (`xcode-select --install`). `apple_edid.py` needs only the
Python 3 that ships with macOS. No dependencies, no signing, no root.

```bash
git clone https://github.com/jqqqqqqqqqq/Make-M1-Great-Again.git
cd Make-M1-Great-Again
mkdir -p build && swiftc -O -o build/avedid avedid.swift
python3 apple_edid.py --help
./build/avedid help
```

A prebuilt arm64 binary is attached to each tagged release. It is unsigned, so
clear the quarantine flag after downloading — or just build it, which takes about
a second:

```bash
xattr -d com.apple.quarantine avedid
```

### Tests

```bash
python3 tests/test_apple_edid.py
```

37 checks covering the timing formula against Apple's own timings, DisplayID
encode/decode round-trips, the blanking overrides, `--fit-clock` behaviour,
patched-EDID structure and checksums, and the CLI's refusal paths. No hardware
and no display required, which is what makes it a usable CI gate.

`avedid` itself is only smoke-tested (`avedid help`) in CI, since every other
subcommand talks to a real display controller. `apply`, `revert` and `watch` are
the parts to be careful with when changing them.

### CI and releases

`.github/workflows/ci.yml` runs the tests and builds the binary on an Apple
Silicon runner for every push and pull request. Pushing a `v*` tag builds,
packages and publishes a release with a checksum:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

## Why the obvious approach fails

Every guide says to drop a plist into
`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<v>/DisplayProductID-<p>`
with an `IODisplayEDID` key. **On Apple Silicon that key is ignored.** The
DisplayPort controller (DCP) builds its timing list from the panel's real EDID
and never consults it.

Verified the boring way: install such an override, reboot, then read the live
EDID — it comes back bit-identical to the stock dump. The myth survives because
the *other* keys in the same plist (`scale-resolutions`, `DisplayProductName`,
`IOGFlags`) still work, so the file looks like it took effect.

## What actually works

A private IOKit call that hands the DCP a substitute EDID at runtime:

```c
IOAVServiceSetVirtualEDIDMode(avService, 1, patchedEdidData);  // install
IOAVServiceSetVirtualEDIDMode(avService, 0, NULL);             // revert
```

This is what SwitchResX's daemon does on Apple Silicon, and BetterDisplay's EDID
override too — both binaries import the symbol. Its signature was recovered by
disassembling SwitchResX's daemon; it is not documented anywhere.
`avedid.swift` reimplements it:

1. Enumerate `DCPAVServiceProxy` services with `Location == "External"`.
2. Match one to a `CGDirectDisplayID` by comparing EDID bytes 8–11 against
   `CGDisplayVendorNumber` / `CGDisplayModelNumber`.
3. `IOAVServiceCreateWithService`, then `IOAVServiceSetVirtualEDIDMode`.
4. `SLSDetectDisplays` to force re-enumeration.

No root required, and nothing is SIP-protected. Two consequences:

- **No reboot needed.** The new mode appears in about a second.
- **It does not persist.** A virtual EDID is runtime state, wiped by reboot,
  display sleep/wake, and hot-plug. Something must watch for that and reinstall
  it — which is why SwitchResX ships a resident daemon rather than a login item,
  and why `avedid watch` exists.

The impermanence is also the safety property: a timing that blacks out the
display is undone by rebooting, with nothing on disk to clean up.

## The real limit: active-pixel throughput

```
measured DCP validation limit = [1.2829, 1.2856) Gactive-pixels/s
```

Every accept/reject outcome observed fits this one number:

| Mode | Gpx/s | % of budget | DCP verdict |
| --- | --- | --- | --- |
| 5120×2880 @ 87 | 1.2829 | 100.0% | accepted |
| 5120×2880 @ 88 | 1.2976 | 101.1% | rejected |
| 3840×2160 @ 150 | 1.2442 | 97.0% | accepted |
| 3840×2160 @ 155 | 1.2856 | 100.2% | rejected |
| 3840×2160 @ 160 | 1.3271 | 103.4% | rejected |
| 2560×1440 @ 300 | 1.1059 | 86.2% | accepted |

Active pixels are `width × height × refresh`; blanking is idle time and does not
count. So the budget converts to a maximum refresh per resolution:

```
5120x2880    87.0 Hz      3840x2160   154.7 Hz
2560x1440   348.0 Hz      1920x1080   618.7 Hz
```

That is why **88 Hz is unreachable at 5K**: it needs 1.2976 G, and no amount of
clock or blanking manipulation changes the active pixel count. It also explains
the thing that puzzled us first: the panel's own 5120×2880@120 timing needs
**1.769 G, 138% of budget**, which is why the DCP registers it as `IsPreferred`
and yet never hands it to CoreGraphics.

The number is not arbitrary. Apple advertises the M1 Max as driving 6K@60 per
display, which needs 1.2215 G — **95.2%** of the measured cap. This looks like a
per-pipe hardware design point sized for 6K60 with a little headroom, not a
software policy.

### What is explicitly *not* limited

Each of these was demonstrated by a mode that violates it while staying inside
the throughput budget:

| Not a limit | Disproved by |
| --- | --- |
| Pixel clock | **1470 MHz** accepted (2560×1440@300) |
| Vertical blanking | **156 µs** accepted (5120×2880@86.90), vs Apple's 460 µs convention |
| Horizontal blanking | **24 px** accepted (5120×2880@86.85), vs Apple's 80 |
| Refresh rate itself | **300 Hz** accepted at 1440p |

### Can the limit be bypassed?

Not in software. What was considered:

- **Tiling — architecturally correct, blocked at the display.** Split into two
  2560×2880 tiles on two pipes and 5K@120 needs only **0.885 G per pipe (69% of
  budget)**. Comfortably inside. The panel genuinely is internally 2×1 tiled and
  the DCP parses it (`DisplayHints` shows `Tiled=Yes, TileW=2560`), and the host
  even has a spare head — `dispext0` exposes two DPTX ports and two AV
  controllers, with `Unit 1` empty. But the panel presents a **single SST sink**
  (`SinkCount = 1`, empty `BranchDeviceID`), so there is no second stream to
  assign. The gate is on the display's side of the cable.
- **Thunderbolt.** MST is a DisplayPort-layer property, not a transport one. A TB
  tunnel does not create a sink the display does not have. (This display in fact
  negotiates plain DP alt-mode: `Tunneled = No`, and no TB bus enumerates it.)
- **DSC, reduced bit depth, chroma subsampling.** All operate on *bits*; the limit
  counts *pixels*. DSC is already engaged at 87 Hz and is irrelevant to the
  boundary.
- **Interlacing.** Halves active pixels per field, doubles field rate — identical
  throughput. macOS does not do interlaced over DisplayPort anyway.
- **Lower resolution.** Works (4K allows ~155 Hz) but means running non-native on
  a 5K panel. See the caveat below about host validation versus actual display.
- **Patching the limit.** It lives in DCP firmware, inside the signed boot chain.

The realistic levers are newer silicon (M3/M4 pipes are near-certainly budgeted
higher — untested here, and this tooling measures it directly) or a display that
exposes tiled dual-stream.

### Host validation is not the same as displaying

Everything above measures whether the **DCP accepts a timing**, observable in
`ioreg -lw0 -r -c AppleCLCD2` and in `avedid modes`. Whether the panel then locks
to it is a separate gate. This panel's EDID declares 47–120 Hz vertical, max
367 kHz horizontal and max 1910 MHz pixel clock — so 3840×2160@150 and
2560×1440@300 pass the host and may well be refused by the display. **Untested.**
Only 5120×2880@87 is confirmed actually running.

## How those numbers were got wrong first

Worth recording, because the mistake is easy to repeat and cost several rounds.

The first version of this document claimed a ~1356 MHz clock ceiling, a
395–449 µs vertical blanking floor, and an 80 px horizontal blanking minimum.
Every one of those was an artifact of the same error: **all the probes that
"measured" them worked by raising refresh rate**, and raising refresh rate raises
throughput. So the throughput cap was tripping in every experiment, and each
result got attributed to whichever variable was being nominally adjusted.

The giveaway was visible in the data before the model was: sorted by verdict, the
accepted and rejected *pixel clock* ranges overlapped (1356.00 accepted,
1355.54 rejected) and so did the *blanking* ranges (449 µs accepted, 457 µs
rejected). Only refresh rate separated them cleanly — which is what pointed at a
quantity proportional to it.

What finally worked was testing at a **lower** rate: 86.85, 86.90 and 86.95 Hz
timings that each broke one supposed limit — 1378 MHz clock, 156 µs vblank, 24 px
hblank — while staying under the real cap. All three were accepted, retracting all
three limits at once. Then a cross-resolution probe (1440p@300, 4K@150/155/160)
separated throughput from refresh rate and pinned the budget to 0.22%.

**The transferable lesson: to isolate a variable, hold *throughput* constant, not
clock and not blanking.**

## Known trade-off: no media refresh rates

Custom timings carry no `DiscreteMediaRefreshRates`, while every stock timing
does. The stock 60 Hz mode can drop the panel to 47.95/48 Hz for 24 fps content;
the 87 Hz mode cannot. The custom mode does expose a VRR range (47–87 Hz), so
playback may be handled that way instead — unverified.

The cause is **not** the DisplayID section header. The tool emits DisplayID 1.1 /
product type 3 by default while Apple's stock sections use 1.2 / type 0; that was
made selectable (`--section apple`), tested, and made no difference. A better
guess, untested: the 120 Hz element's media list contains 100.00 and 119.88 Hz,
and *neither exists as a Type I timing in the EDID*, so the list is assembled
from somewhere else — most likely the CTA-861 block (block 1, which this tool
never touches), where standard formats are declared by VIC. 5120×2880@87 is not a
standard VIC, so there may be nothing valid to attach.

If you watch a lot of 24 fps video, 60 Hz is genuinely better for that.

## Command reference

### `apple_edid.py` — EDID encoder / decoder / timing generator

```bash
python3 apple_edid.py build --mode WxH@RATE[:MHZ][/vtot=N][/vblank=N][/hblank=N] ...
python3 apple_edid.py dump  <edid.bin|edid.hex>   # decode every timing
python3 apple_edid.py read                        # live EDID from ioreg, as hex
```

Timings follow Apple's own formula — CVT reduced-blanking with a fixed 80 px
horizontal blanking interval and the standard 460 µs minimum vertical blanking.

What validates it: given only width, height and refresh rate, it reproduces
**11 of the 12** stock Type I timings in this display's EDID bit-for-bit —
identical pixel clock, totals and porches. The single exception is the
NTSC-derived 47.9522 Hz variant, where Apple reuses the 48 Hz geometry
(`vtot 2946`) and divides the clock by 1.001 instead of re-deriving `vtot` from
the 460 µs rule, which gives 2945. `tests/test_apple_edid.py` asserts both the
11 matches and that one exception.

| Flag | Effect |
| --- | --- |
| `:MHZ` | pin the pixel clock exactly (otherwise rounded to the nearest 10 kHz, Apple's convention) |
| `/vtot=N`, `/vblank=N` | override the derived vertical blanking |
| `/hblank=N` | override horizontal blanking (≥ 24 px; back porch gives way before sync width) |
| `--fit-clock MHZ` | shrink vertical blanking only as far as needed to fit each mode under a clock ceiling |
| `--section legacy\|apple` | DisplayID section header; `apple` matches the stock sections |
| `--preserve PLIST` | carry `scale-resolutions` / `IOGFlags` / policies over from an existing override |
| `--stock`, `--name`, `--label`, `--out-edid`, `--out-plist` | inputs and outputs |

`dump` accepts raw bytes or a hex dump, so `read` output can be fed straight back.
`--fit-clock` is a leftover from the mistaken clock-ceiling model; it is still
useful for pinning a clock budget deliberately, but it is not how you find the
real limit — see [the throughput section](#the-real-limit-active-pixel-throughput).

### `avedid` — the injector

```bash
./build/avedid list                   # external displays and their current EDID
./build/avedid dump                   # the EDID a display reports, as hex
./build/avedid modes                  # rates at the current resolution, plus
                                      # max rate and throughput per resolution
./build/avedid set-hz 87              # switch rate (nearest within 0.05 Hz)
./build/avedid set-hz --mode-id 94    # switch to an exact mode ID from `modes`
./build/avedid apply <edid.bin>       # install a virtual EDID
./build/avedid revert                 # restore the panel's real EDID
./build/avedid watch <edid.bin>       # stay resident and reinstall when it drops
```

| Flag | Effect |
| --- | --- |
| `--index N`, `--all` | pick targets. `apply` refuses to guess; `revert` falls back to all, since disabling is harmless |
| `--yes`, `--dry-run`, `--no-redetect` | non-interactive, no-op, skip the re-detect |
| `--ignore-agent` | apply even though the launch agent is loaded |
| `--skip-if-modifiers` | do nothing if Shift or Option is held — the agent's escape hatch |
| `--delay N` | wait before acting, so the display finishes enumerating after login |
| `--restore-hz N` | reselect N Hz after each reinstall (`watch`) |
| `--poll N` | safety re-check interval, default 30 s; events drive the fast path |

`apply` validates the EDID first (header, per-block checksums, extension count in
byte 126), then targets the service already reporting the same vendor/product as
the EDID being installed and **refuses if no connected display claims that
identity**. It also **refuses while the launch agent is loaded**, because a
resident `watch` reinstalls its own EDID within a minute and that silent revert is
indistinguishable from the DCP rejecting the timing — which makes probing
actively misleading. Stop the agent first, or pass `--ignore-agent`.

Each injected timing surfaces **twice** at the top rate, as a VRR and a non-VRR
variant (`modes` labels them and shows distinct mode IDs) — macOS advertises a
variable-refresh range topping out at the fastest timing available. Mode IDs are
**not stable** across EDID changes; re-read `modes` after every `apply`.

### The launch agent

```bash
./install-agent.sh [edid.bin] [hz]    # defaults to build/patched.bin at 87 Hz
./uninstall-agent.sh                  # removes the plist
launchctl bootout gui/$UID/local.avedid   # just stops it, keeps the plist
tail -f /tmp/avedid.log
```

Installs `~/Library/LaunchAgents/local.avedid.plist` running `avedid watch`:
resident, `RunAtLoad`, `KeepAlive` on unclean exit only. It reinstalls the EDID
on login, sleep/wake and hot-plug, then reselects the refresh rate — macOS
re-enumerates at a stock rate, so restoring the EDID alone makes 87 Hz available
but not selected.

**Hold Shift or Option while logging in to skip it.** Since the agent is
resident, that is the only way to stop it reapplying a timing that blacks out the
display.

`watch` reinstalls only when what the display reports differs from the file, so
in the steady state it is silent. Reinstalls are throttled to once a minute per
display, so a persistent mismatch cannot become a screen flash on every check.

## Adapting this to other hardware

1. `python3 apple_edid.py read > mine.hex` then `python3 apple_edid.py dump
   mine.hex` to see your stock timings. `./build/avedid list` prints your IDs.
2. **Measure your throughput budget first.** It is the number that predicts
   everything, and `avedid modes` reports Gpx/s per resolution to compare
   against. Probe it by bisecting refresh rate at your native resolution while
   keeping blanking at Apple's conventions:

   ```bash
   python3 apple_edid.py build \
       --mode 5120x2880@88 --mode 5120x2880@92 --mode 5120x2880@96
   ./build/avedid apply build/patched.bin && ./build/avedid modes
   ```

   Always include a known-good rung so a rejected one still leaves something
   selectable. A rejected timing is one the DCP discarded during EDID parsing —
   confirm with `ioreg -lw0 -r -c AppleCLCD2` if `modes` is ambiguous.
3. Do **not** try to isolate clock or blanking limits by raising refresh rate.
   That is the error described [above](#how-those-numbers-were-got-wrong-first).
   If you suspect a secondary limit, test it at a rate *below* your measured
   throughput ceiling.
4. Sanity-check your number against what the SoC is advertised for. On the M1 Max
   the budget landed 5% above the 6K60 it is specced for, which is a good sign
   the measurement is real rather than an artifact.

Timings on other Apple panels are likely to follow the same 80 px / 460 µs
formula, but the throughput budget is an SoC property and will differ.

### Three ways a timing gets rejected

They look different and are diagnosed differently:

1. **DCP validation.** The timing never becomes a timing element at all. Check
   `ioreg -lw0 -r -c AppleCLCD2` for an element matching your
   `HorizontalAttributes` / `VerticalAttributes`; if absent, the DCP discarded it
   while parsing. This is what exceeding the throughput budget looks like, and
   why the mode simply is not there.
2. **Enumeration.** A timing the DCP kept can still be withheld from
   CoreGraphics. `avedid modes` reads this off without changing anything.
3. **Locking.** A mode enumerates and then fails on selection, reverting. Only
   selecting it reveals this — hold it ~30 s to be sure.

## Files

| Path | What it is |
| --- | --- |
| `apple_edid.py` | EDID / DisplayID encoder, decoder and timing generator |
| `avedid.swift` | The injector — `IOAVServiceSetVirtualEDIDMode` plus mode selection |
| `install-agent.sh`, `uninstall-agent.sh` | Login agent that keeps the EDID in place |
| `tests/test_apple_edid.py` | Dependency-free test suite for the generator |
| `.github/workflows/ci.yml` | Build + test on an Apple Silicon runner; release on tag |
| `edid/studio-display-xdr-stock.bin` | Pristine 768-byte EDID read from this display |
| `install.sh`, `uninstall.sh` | Legacy `/Library/Displays` override — see below |
| `build/` | Generated EDIDs, plists and the compiled binary (gitignored) |

### The legacy plist route

`install.sh` / `uninstall.sh` write a display override to `/Library/Displays`.
On Apple Silicon this does **not** install the EDID; it is kept only for the
`scale-resolutions` HiDPI list, and it needs a reboot. If you have no use for
scaled-resolution overrides you do not need it at all.

SwitchResX's daemon owns that same file and rewrites it when it applies settings.
It also drives the same `IOAVServiceSetVirtualEDIDMode` call, so running both
against one display means whichever ran last wins.

## Caveats

- **The EDID does not persist** without the agent. Every reboot, sleep/wake and
  hot-plug restores the panel's real EDID.
- If the display comes up black, reboot — nothing was written to disk. With the
  agent installed, hold Shift or Option while logging in to skip it.
- **Stop the agent before probing.** It reinstalls its own EDID within a minute,
  which looks exactly like a rejected timing. `avedid apply` now refuses while it
  is loaded, for this reason.
- This Mac exposes **two** external `DCPAVServiceProxy` nodes and only one
  returns an EDID. They are separate ports (`dispextE` and `dispext0`), not the
  panel's two tiles. `avedid list` shows both.
- The agent sometimes logs two startup lines when first loaded, seconds apart.
  Observed to be harmless — it settles into a single stable process — but the
  cause was never pinned down: launchd restarted the first instance despite a
  successful exit, which `KeepAlive: SuccessfulExit=false` should not do.
- 87 Hz runs at 449 µs of vertical blanking, within 2% of Apple's 460 µs
  convention. Much tighter blanking is *accepted* by the DCP (156 µs was), but
  leaves less margin for thermal drift or a marginal cable, and the plausible
  failure is intermittent sync loss rather than an immediate black screen.
- Everything here uses private, undocumented APIs. They can change or vanish in
  any macOS update.
