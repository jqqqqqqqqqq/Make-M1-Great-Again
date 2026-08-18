# custom-edid — custom refresh rates on Apple Silicon

Adds a **5120×2880 @ 87 Hz** mode to an Apple Studio Display XDR driven by an
M1 Max Mac Studio, which otherwise offers only 60 Hz. A free replacement for
SwitchResX for this one job, plus a written-up account of *why* the usual
approaches fail on Apple Silicon and where the hardware limits actually are.

The interesting part is not the 87 Hz. It is that the display-override plist
every guide tells you to write **does nothing** on Apple Silicon, and that the
real mechanism is a private IOKit call that has to be reapplied at runtime.

## Result

| | |
| --- | --- |
| Hardware | Mac Studio (M1 Max, `J375cAP`) + Studio Display XDR (`0x0610:0xae42`) |
| Stock | 5120×2880 @ 60 Hz |
| Achieved | 5120×2880 @ **87.00 Hz**, `htot 5200 vtot 2997`, 1355.84 MHz, 449 µs vblank |
| Limited by | M1 Max display-pipe clock (~1356 MHz), not the panel or the cable |

![System Settings showing Refresh rate: Adaptive (47-87 Hertz)](Proof%20of%20refresh%20rate.png)

macOS reports it as an adaptive 47–87 Hz range, because it advertises a
variable-refresh range topping out at the fastest timing available.

## Quick start

> **These numbers are specific to a Studio Display XDR (`0x0610:0xae42`) on an
> M1 Max.** The 87 Hz timing and the 1355.84 MHz clock were measured on that
> hardware; the pipe clock is an SoC property and the blanking floors are the
> panel's. On anything else, start at
> [Adapting this to other hardware](#adapting-this-to-other-hardware) instead of
> copying these commands. `avedid apply` refuses an EDID whose vendor/product no
> connected display reports, so a copy-paste on the wrong machine fails closed
> rather than injecting foreign timings — but it cannot tell that a *plausible*
> timing is wrong for your panel.

```bash
# 1. build the EDID injector
mkdir -p build && swiftc -O -o build/avedid avedid.swift

# 2. generate a patched EDID containing the extra timing
python3 apple_edid.py build --mode 5120x2880@87:1355.84/vtot=2997

# 3. install it — takes effect in about a second, no reboot
./build/avedid apply build/patched.bin

# 4. make it survive reboots and sleep/wake
./install-agent.sh build/patched.bin 87
```

Then pick 87 Hz in **System Settings → Displays**, or `./build/avedid set-hz 87`.

To undo everything: `./uninstall-agent.sh && ./build/avedid revert`. Nothing is
written to disk that affects boot, so a reboot alone also restores the stock EDID.

## Building and running

Requirements: an Apple Silicon Mac, macOS 12 or later, and the Xcode command line
tools for `swiftc` (`xcode-select --install`). `apple_edid.py` needs only the
Python 3 that ships with macOS. Nothing else — no package manager, no
dependencies, no signing, and no root.

```bash
git clone https://github.com/jqqqqqqqqqq/Make-M1-Great-Again.git
cd Make-M1-Great-Again

# the injector is one Swift file
mkdir -p build && swiftc -O -o build/avedid avedid.swift

# the generator runs as-is
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
encode/decode round-trips, the blanking overrides, `--fit-clock` ceiling
behaviour, patched-EDID structure and checksums, and the CLI's refusal paths.
No hardware and no display required, which is what makes it a usable CI gate.

`avedid` itself is only smoke-tested (`avedid help`) in CI, since every other
subcommand talks to a real display controller. The parts that cannot be tested
headless are the ones to be careful with when changing them: `apply`, `revert`
and `watch`.

### CI and releases

`.github/workflows/ci.yml` runs the test suite and builds the binary on an Apple
Silicon runner for every push and pull request. Pushing a `v*` tag additionally
builds, packages and publishes a release with a checksum:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

## Why the obvious approach fails

Every guide says to drop a plist into
`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<v>/DisplayProductID-<p>`
with an `IODisplayEDID` key. **On Apple Silicon the `IODisplayEDID` key is
ignored.** The DisplayPort controller (DCP) builds its timing list from the
panel's real EDID and never consults it.

Verified the boring way: install such an override, reboot, then read the live
EDID — it comes back bit-identical to the stock dump. The reason this myth
survives is that the *other* keys in the same plist (`scale-resolutions`,
`DisplayProductName`, `IOGFlags`) still work, so the file looks like it took
effect.

## What actually works

A private IOKit call that hands the DCP a substitute EDID at runtime:

```c
IOAVServiceSetVirtualEDIDMode(avService, 1, patchedEdidData);  // install
IOAVServiceSetVirtualEDIDMode(avService, 0, NULL);             // revert
```

This is what SwitchResX's daemon does on Apple Silicon, and BetterDisplay's EDID
override too — both binaries import the symbol. `avedid.swift` reimplements it:

1. Enumerate `DCPAVServiceProxy` services with `Location == "External"`.
2. Match one to a `CGDirectDisplayID` by comparing EDID bytes 8–11 against
   `CGDisplayVendorNumber` / `CGDisplayModelNumber`.
3. `IOAVServiceCreateWithService`, then `IOAVServiceSetVirtualEDIDMode`.
4. `SLSDetectDisplays` to force re-enumeration.

No root required, and nothing is SIP-protected.

Two consequences:

- **No reboot needed.** The new mode appears in about a second.
- **It does not persist.** A virtual EDID is runtime state, wiped by reboot,
  display sleep/wake, and hot-plug. Something must watch for that and reinstall
  it — which is why SwitchResX ships a resident daemon rather than a login item,
  and why `avedid watch` exists.

The impermanence is also the safety property: a timing that blacks out the
display is undone by rebooting, with nothing on disk to clean up.

## The measured limits

Three independent constraints, each established by probing rather than assumed.
The method generalises even though the numbers are specific to this hardware.

| Constraint | Value | How it was established |
| --- | --- | --- |
| Display-pipe pixel clock | **~1356 MHz** | 1356.00 MHz produces a working mode; 1356.75 MHz is discarded during EDID parsing |
| Vertical blanking floor | **395–449 µs** | 449 µs accepted, 395 µs rejected |
| Horizontal blanking | **≥ 80 px, no exceptions** | 48 / 40 / 24 px all rejected even with generous vblank |

Because `pclk = htotal × vtotal × refresh`, these interact:
shrinking blanking raises the rate a fixed clock can carry. At 87 Hz with the
mandatory 80 px horizontal blanking, `vtot 2997` gives 449 µs — right at the
floor. That is why 87 Hz is the ceiling and 88 Hz is not reachable: it would
need either more clock or less blanking than the hardware allows.

Note that with `htot` pinned at 5200, pixel clock and horizontal rate are
strictly proportional, so this cannot distinguish a ~1356 MHz clock limit from a
~260.8 kHz horizontal-rate limit. It makes no operational difference: under
either reading, the wider `htot 5280` the DCP also accepts yields no more than
87 Hz.

### Three ways a timing gets rejected

Worth knowing, because they look different and are diagnosed differently:

1. **DCP validation.** The timing never becomes a mode at all. Check with
   `ioreg -lw0 -r -c AppleCLCD2` and look for an element matching your
   `HorizontalAttributes` / `VerticalAttributes`; if it is absent, the DCP threw
   it out while parsing. This is what happens just past the limits above.
2. **Enumeration.** A timing the DCP kept can still be withheld from
   CoreGraphics. The panel's stock 120 Hz timing at 1903 MHz is registered as
   `IsPreferred` and never reaches CG. `avedid modes` reads this off without
   changing anything.
3. **Locking.** A mode enumerates, then fails on selection and reverts. Only
   actually selecting it reveals this.

A useful shortcut: the highest surviving timing is always the one that appears
**twice** in `avedid modes` — once `fixed`, once `VRR`, because macOS advertises
a variable-refresh range topping out at the fastest available timing. So the top
of that list tells you where the DCP stopped accepting.

### What does not work, so nobody retries it

- **The panel's own 120 Hz timing.** Present in the stock EDID at 1903 MHz and
  marked `IsPreferred`, but 1.4× past the pipe clock. Unreachable.
- **Tiling / dual-head.** The panel really is internally 2×1 tiled (DisplayID
  Tiled Display Topology: two 2560×2880 tiles, single enclosure), and the DCP
  parses it — `DisplayHints` shows `Tiled=Yes, TileW=2560`. There are even two
  DPTX ports and two AV controllers on this DCP instance. But the panel presents
  a **single SST sink** (`SinkCount = 1`, no MST branch), so there is no second
  stream to assign a second pipe to. Splitting would have halved the per-pipe
  clock; it is not available.
- **Thunderbolt.** MST is a DisplayPort-layer property, not a transport one. A
  TB tunnel does not create a sink the display does not have. (This display in
  fact negotiates plain DP alt-mode: `Tunneled = No`, and no TB bus enumerates it.)
- **DSC.** Compresses the link downstream of the pipe. The pixel clock the pipe
  sees is unchanged, so it cannot buy refresh rate.

### Known trade-off

Custom timings carry no `DiscreteMediaRefreshRates`, while every stock timing
does — the stock 60 Hz mode can drop the panel to 47.95/48 Hz for 24 fps content,
and the 87 Hz mode cannot. The custom mode does expose a VRR range (47–87 Hz),
so playback may be handled that way instead; this has not been verified. If you
watch a lot of 24 fps video, 60 Hz is genuinely better for that.

## Command reference

### `apple_edid.py` — EDID encoder / decoder / timing generator

```bash
python3 apple_edid.py build --mode WxH@RATE[:MHZ][/vtot=N][/vblank=N][/hblank=N] ...
python3 apple_edid.py dump  <edid.bin>     # decode every timing
python3 apple_edid.py read                 # live EDID from ioreg, as hex
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
| `--fit-clock MHZ` | shrink vertical blanking only as far as needed to fit each mode under a clock ceiling, keeping as much as possible |
| `--preserve PLIST` | carry `scale-resolutions` / `IOGFlags` / policies over from an existing override |
| `--stock`, `--name`, `--label`, `--out-edid`, `--out-plist` | inputs and outputs |

It warns when a mode's vertical blanking falls meaningfully below the 460 µs
convention, and refuses timings whose `vtotal` drops below the active lines.

### `avedid` — the injector

```bash
./build/avedid list                   # external displays and their current EDID
./build/avedid dump                   # the EDID a display reports, as hex
./build/avedid modes                  # rates at the current resolution, fixed vs VRR
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
| `--skip-if-modifiers` | do nothing if Shift or Option is held — the launch agent's escape hatch |
| `--delay N` | wait before acting, so the display finishes enumerating after login |
| `--restore-hz N` | reselect N Hz after each reinstall (`watch`) |
| `--poll N` | safety re-check interval, default 30 s; events drive the fast path |

`apply` validates the EDID first: header, per-block checksums, and the extension
count in byte 126. It then targets the service already reporting the same
vendor/product as the EDID being installed, and **refuses if no connected display
claims that identity** — the usual cause is an EDID built for a different panel.
`--index N` overrides that deliberately. It also refuses to guess when nothing is
identifiable, since applying to an unused port would leave a phantom display
latched there until reboot.

### The launch agent

```bash
./install-agent.sh [edid.bin] [hz]    # defaults to build/patched.bin at 87 Hz
./uninstall-agent.sh
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

1. `python3 apple_edid.py read > mine.hex` and
   `python3 apple_edid.py dump mine.bin` to see your stock timings.
2. Find your IDs: `./build/avedid list` prints vendor and product.
3. Measure your pixel-clock ceiling before guessing at refresh rates — hold the
   geometry fixed at a known-good timing and pin only the clock upward:

   ```bash
   python3 apple_edid.py build \
       --mode 5120x2880@86.0005:1341.16/vtot=2999 \
       --mode 5120x2880@86.1826:1344.00/vtot=2999 \
       --mode 5120x2880@86.3749:1347.00/vtot=2999
   ```

   Rungs a fraction of a Hz apart are indistinguishable in System Settings,
   hence `avedid modes` and `set-hz`. Always include a known-good rung so a
   rejected one still leaves something selectable.
4. Only then trade blanking for refresh, via `--fit-clock` at the measured
   ceiling. Doing it in this order matters: measuring the clock first was worth a
   full Hz here, because at the clock originally assumed to be the limit, 87 Hz
   needed off-spec blanking, and at the real one it needs only 449 µs.

Timings on other Apple panels are likely to follow the same 80 px / 460 µs
formula, but the pipe clock is an SoC property and will differ — M3 and M4 are
expected to be higher, though that is untested here.

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
- This Mac exposes **two** external `DCPAVServiceProxy` nodes and only one
  returns an EDID. They are separate ports, not the panel's two tiles. `avedid
  list` shows both; use `--index` or `--all` to override targeting.
- Mode IDs are **not stable** across EDID changes. Re-read `avedid modes` after
  every `apply` before using `--mode-id`.
- The agent sometimes logs two startup lines when first loaded, seconds apart.
  Observed to be harmless — it settles into a single stable process — but the
  cause was never pinned down: launchd restarted the first instance despite it
  exiting successfully, which `KeepAlive: SuccessfulExit=false` should not do.
- Off-spec blanking is where arithmetic stops being a guarantee. 87 Hz at 449 µs
  is within 2% of Apple's own convention; anything much tighter has less margin
  for thermal drift or a marginal cable, and the plausible failure is
  intermittent sync loss rather than an immediate black screen.
- Everything here uses private, undocumented APIs. They can change or vanish in
  any macOS update. `IOAVServiceSetVirtualEDIDMode`'s signature was recovered by
  disassembling SwitchResX's daemon, not from any documentation.
