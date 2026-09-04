# Energy Conversion Meter

## Introduction
Are your converters starving, or is your energy excessively oveflowing?
This meter tells you whether your **energy production and energy conversion are balanced** at a glance, and loudly when it really matters - now also adjustable in settings!

## What it shows
A compact 9-bar meter styled like the top bar:
- **Green center bar** = Most of your converters are working and you're not overflowing energy. Solid balance.
- **Bars fill to the RIGHT (Overflowing)** = Your energy increased, but you're not converting all of it. You're overflowing, potentially leaving extra metal on the table.
- **Bars fill to the LEFT (Idle converters)** = Your converters are sitting unused. You could be converting to metal, but you don't have enough energy.
- Bars ramp **yellow → orange → red** as the imbalance grows. At 3+ bars a plain yellow hint appears: **Overflowing** or **Idle converters**.

## Smart severity
- Severity is **relative to your income** (3k excess on 5k income is huge; on 100k it's mild), with absolute floors so a large absolute waste still maxes the meter on a big economy.
- **Construction-aware**: energy and converters you are *actively building* already count as fixed, so it won't nag you about a problem you're already solving. Untouched blueprints don't count.
- Values are smoothed (~2s) with display hysteresis, so it doesn't flicker during build bursts.

## Alerts (optional)
- Holding **3+ bars for ~5s** pops an on-screen message with a soft beep (once per episode, 30s cooldown).
- **Pinned at 4 bars**: a stronger pulsing message repeats every 20s, the side icon pulses red and the whole panel flashes softly (like the top bar's wasting warning) until solved.

## Extras
- **Ctrl + left-click drag** moves the meter anywhere; the position is saved. While dragging it magnet-snaps to other snap-aware widgets, the minimap and the top bar, with a fine grid fallback elsewhere. Plain clicks pass through, so it never blocks orders.
- Reads the same team rules params as the game's conversion gadget (`mmUse`/`mmCapacity`) — spectator-safe, no unit control, display only.
