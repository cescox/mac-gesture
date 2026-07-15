# Multitouch Findings & Improvement Options

Research notes captured while investigating the **palm-counted-as-finger** bug
(3-finger gesture misfires as 4-finger when the palm grazes the trackpad).
This document is a decision aid — not a plan. Pick what to build from
"Recommendation order" at the bottom.

---

## 1. The bug, restated

`Sources/main.swift:401` — `touchCallback` uses `numTouches` from the
MultitouchSupport framework directly as the finger count. The framework
delivers **raw** contacts with no palm rejection, so a palm resting on
the trackpad while three fingers tap is reported as four touches and
fires the 4-finger binding.

Apple's native gestures don't have this problem because the OS does
palm filtering one layer up, in the trackpad driver / IOHID path that
feeds `NSTouch`. `NSTouch` only delivers to the focused window, so it's
unusable for a system-wide listener like ours.

---

## 2. APIs surveyed

| API | Palm rejection? | System-wide? | Verdict |
|---|---|---|---|
| `NSTouch` (AppKit) | Yes (Apple does it) | No — focused window only | Doesn't fit our model |
| `MultitouchSupport.framework` (private) | **No** — raw stream | Yes | What we use today; we must do palm rejection ourselves |
| IOHID raw | No | Yes, but lower level | More work, no benefit over MTSupport |

Conclusion: stay on `MultitouchSupport`, do palm filtering in-process
using fields already in each `MTTouch`.

---

## 3. MTTouch struct (reverse-engineered, confirmed across sources)

```c
typedef struct {
    int32_t  frame;
    double   timestamp;
    int32_t  pathIndex;
    MTPathStage stage;          // enum 0..7 (lifecycle, not palm/finger)
    int32_t  fingerID;
    int32_t  handID;            // always 1
    MTVector normalizedVector;  // x, y, vx, vy (currently we read only x,y)
    float    zTotal;            // ~capacitance total (0..1, 1/8 steps)
    float    zPressure;         // force-touch pressure (0 on non-FT pads)
    float    angle;
    float    majorAxis;         // touch ellipse — palm signal
    float    minorAxis;
    MTVector absoluteVector;    // mm
    int32_t  field14, field15;  // always 0
    float    zDensity;
} MTTouch;
```

`MTPathStage`: `NotTracking, StartInRange, HoverInRange, MakeTouch,
Touching, BreakTouch, LingerInRange, OutOfRange`. Note: **no palm
state** — Apple's palm rejection isn't exposed here.

### Sources

- [hs._asm.undocumented.touchdevice — MultitouchSupport.h (asmagill)](https://github.com/asmagill/hs._asm.undocumented.touchdevice/blob/master/MultitouchSupport.h)
- [OpenMultitouchSupport (Kyome22)](https://github.com/Kyome22/OpenMultitouchSupport)
- [open-multitouch-support (interface-club)](https://github.com/interface-club/open-multitouch-support)
- [Accessing raw multitouch trackpad data — gist (krackers fork)](https://gist.github.com/krackers/6f972136cc09b0f41dd89a966436378a)
- [Wacom: Multi-Touch Framework notes on palm rejection / confidence](https://developer-support.wacom.com/hc/en-us/articles/12845526953239-Multi-Touch-Framework)

---

## 4. What each "extra" field could unlock (generic catalog)

| Field(s) | Capability |
|---|---|
| `majorAxis`, `minorAxis`, `zTotal` | Palm vs finger discrimination |
| `normalizedVector` (vx, vy) | Per-finger velocity → flick vs drag, swipe direction |
| `zPressure` | Force-tap variants (Force Touch hardware only) |
| `angle` | Finger orientation; two-touch rotation deltas |
| `MTPathStage` (Hover / Linger) | Hover-triggered (FT pads only) and "anchored finger" gestures |
| `fingerID`, `handID` | Persistent identity across frames — track which finger lifted |
| `timestamp` + stage transitions | Reliable tap / hold / double-tap disambiguation |
| `absoluteVector` (mm) | Physical-distance thresholds (trackpad-size independent) |
| `zTotal`, `zDensity` | Light-vs-firm tap on non-FT pads; ghost-touch filtering |

---

## 5. Fit analysis for *this* app

Current app surface (`Sources/main.swift`):
- 3 / 4 / 5-finger tap → one action each
- Tap = peak finger count + duration `< tapThreshold` (~120 ms) + centroid
  deviation `< maxMovement` (0.03 normalized)
- Movement is **explicitly rejected** (`Sources/main.swift:463`)
- Total bindings today: **3** (one per finger count)

### Tier 1 — fixes a real bug (Recommended first)

**Palm filter using `majorAxis` (+ `zTotal` as tiebreaker).**
- Where: `Sources/main.swift:403` — replace `numTouches` with a filtered count.
- Cost: ~10 LOC + one constant + brief calibration to pick the threshold.
- Risk: low. Threshold may need tuning across trackpad generations.
- UI: none.
- Open question: hard-coded threshold vs. user-tunable in preferences?

### Tier 2 — biggest product expansion

**Directional swipes via centroid delta direction.**
- Where: `Sources/main.swift:463` — today this branch rejects; instead,
  when `maxDeviation > maxMovement`, classify dominant direction from
  `dx/dy` (already computed at line 446).
- Effect: 3 bindings → **15** (tap + 4 swipe directions per finger count).
- `normalizedVector` per-finger velocity (Tier-2 field upgrade) optional —
  used to distinguish "hand swiped together" from "fingers diverged".
- Cost: medium. Requires:
  - Direction classifier (one function, ~15 LOC).
  - Preferences UI: 4 new action slots per finger count.
  - Settings storage schema changes.
- Risk: medium. Need to make sure scroll/native gestures still work
  (we're observing, not intercepting, so likely fine — verify).

### Tier 3 — cheap, modest payoff

**Tap-and-hold variant using duration + `MTPathStage`.**
- Where: alongside the `validDuration` check at `Sources/main.swift:462`.
- Effect: doubles vocabulary again (tap vs hold per finger count).
- Cost: small code, but needs a UI row per finger count.
- Risk: low.

### Tier 4 — limited fit

**Force-tap variant using `zPressure`.**
- Splits tap into soft / hard.
- Requires Force Touch trackpad (runtime check needed).
- Competes with the hold variant for the same conceptual "second tap" slot.
- Recommendation: skip unless users explicitly ask.

### Not worth it for *this* app

- `angle` rotation gestures — system handles 2-finger rotate; we're a finger-count app.
- `absoluteVector` (mm) — normalized 0.03 threshold already works.
- Knuckle vs fingertip — no clear user mapping.
- Hover — Force Touch only, unreliable, no clean use case.

---

## 6. Free side-benefit: code-quality cleanup

Once `MTTouch` is declared properly (per §3), we can delete:
- `detectStride` (`Sources/main.swift:65`)
- Raw `load(fromByteOffset:)` reads in `readAveragePosition`
  (`Sources/main.swift:78`)

Replacing both with `UnsafeBufferPointer<MTTouch>` iteration. This makes
every Tier 1/2/3 feature easier to write and review. Not a feature on its
own — bundle it with whichever Tier-1 change ships first.

---

## 7. Recommendation order

1. **Palm filter** (Tier 1) — closes the reported bug. Small, no UI.
2. **Struct refactor** (§6) — removes the stride hack, enables everything below.
3. **Directional swipes** (Tier 2) — biggest UX expansion. Needs settings UI work.
4. **Hold variant** (Tier 3) — only if users run out of bindings.
5. Skip force-tap and the rest unless requested.

---

## 8. Decisions to make before implementing

- [ ] Palm threshold: hard-coded vs. user-tunable?
- [ ] Calibration step on first launch, or trust a default?
- [ ] Swipes: ship behind a feature flag while we tune false-positive rate?
- [ ] Swipe direction model: 4-way (↑↓←→) or 8-way (add diagonals)?
- [ ] Settings UI: keep current popover, or move to a real preferences window when binding count grows?
