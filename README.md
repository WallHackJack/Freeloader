# Freeloader

Which addon isn't paying its way.

A live per-addon CPU and memory readout for World of Warcraft Classic clients
(built and tested against the 2.5.5 anniversary client). No libraries, two Lua
files, and it costs nothing while the window is closed.

## Why

The usual advice — "check addon memory in the AddOns list" — measures the wrong
thing. An addon sitting on 8 MB costs nothing to sit there. What actually turns
into a framerate drop is:

- **ms/frame.** At 60 fps you have 16.7 ms per frame. An addon burning 2 ms of
  that is eating 12% of your budget, every frame, forever.
- **KB/s allocated.** Allocation *rate* is what feeds the garbage collector, and
  the collector is what stutters. Total memory held says nothing about it.

Freeloader shows both, sorted worst-first, on a 3 second window.

## Reading the columns

Hover any column header in-game for the same explanation, or the **All addons**
totals row for the session figures. The addon rows themselves take no mouse
input — every mouse-enabled frame is a region the client hit-tests as the cursor
crosses the window, and their tooltips only repeated what the columns showed.

| Column | What it is |
| --- | --- |
| **CPU** | Share of one CPU core spent running that addon's Lua, averaged over the sample window. Good for ranking; says nothing about whether the cost is one ugly spike or spread evenly. |
| **ms/f** | Milliseconds of Lua per rendered frame. At 60 fps the entire frame is 16.7 ms, shared with the game world and everything else. An addon at 2.00 is taking 12% of that away from drawing. This is the column that becomes a framerate drop. |
| **KB/s** | Kilobytes of Lua memory *allocated* per second — new tables, strings, closures. **Not** memory held: an addon can sit on 20 MB at 0 KB/s and cost you nothing. Allocation is what feeds the garbage collector, and a collection pass is a frame that doesn't get drawn. Sustained hundreds of KB/s from one addon usually means it rebuilds something every frame instead of reusing it. Sampled every third tick — see below. |

**KB/s is off by default** — `/free memory` turns it on, and the column reads
`-` until you do. `UpdateAddOnMemoryUsage` walks every addon's memory
attribution and is a well-known source of a periodic hitch, big enough to be
worse than most of what it would tell you about. Worse, it's a C call, so the
script profiler bills its cost to nobody — not even to Freeloader. An addon
that can't account for its own cost has no business running that cost by
default.

When it is on, the scan runs on every third sample rather than every one, so
KB/s updates about every 9 seconds at the default rate while the CPU columns
stay live. Turn it on when you're actually hunting a stutter, and back off when
you're done. With script profiling off, the CPU half of the sample loop is
skipped entirely too.

The sample window is 3 seconds by default rather than 1. A one-second window is
both hard to read and noisy — a single GC pass or stray event lands entirely
inside it and throws that row to the top. `/free rate <n>` if you want it
faster or slower.

## Usage

```
/free              toggle the window
/free on           enable script profiling (needs a reload)
/free off          turn it back off
/free memory       track allocation rate, the KB/s column (default off)
/free report [n]   cumulative worst offenders since login, printed to chat
/free reset        zero the counters, start a fresh window
/free rows <n>     how many lines to show (3-40)
/free rate <n>     seconds between samples (0.25-10, default 3)
/free lock         stop the window being dragged
/free minimap      show or hide the minimap button
```

`/freeload` and `/freeloader` are aliases. `/free` is short enough that another
addon could have claimed it first — slash registration is last-writer-wins with
no warning — so `/freeloader` is the one to fall back on if `/free` does
something unexpected.

The minimap button toggles the window on left-click and prints the session
report on right-click. Drag it around the ring; `/free minimap` hides it.

Escape deliberately does **not** close the window. This is a monitor you leave
running while you play, and Escape is a key you hit for a hundred other reasons.
Use the close button or `/free`.

## Script profiling

CPU numbers only exist when the `scriptProfile` CVar is on, and that CVar only
changes on a UI reload — `/free on` sets it and offers the reload. Memory and
allocation rate work without it.

Profiling adds a few percent CPU of its own, so the honest workflow is: turn it
on, reproduce the problem, read the list, turn it off. Absolute milliseconds are
inflated while it runs; the *ranking* is what you should trust.

## Caveats worth knowing

- **Attribution is per-owning-file.** An addon that hooks or calls into another
  addon bills the callee. If a number looks wrong, it probably is, and
  `GetFunctionCPUUsage` is the escape hatch.
- **This is Lua cost only.** An addon that spawns 400 frames costs you draw time
  that never shows up in a CPU column. Watch the fps readout alongside it.
- **Negative memory deltas are floored at zero.** A drop means the collector
  ran, not that an addon gave memory back.
- **Nothing is sampled while the window is closed.** Hidden frames get no
  `OnUpdate`. `/free report` still works — it reads cumulative counters.

## License

Do what you like with it.
