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

Freeloader shows both, sorted worst-first, updated once a second.

## Usage

```
/free              toggle the window
/free on           enable script profiling (needs a reload)
/free off          turn it back off
/free report [n]   cumulative worst offenders since login, printed to chat
/free reset        zero the counters, start a fresh window
/free rows <n>     how many lines to show (3-40)
/free rate <n>     seconds between samples (0.25-10)
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
