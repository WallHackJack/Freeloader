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
/frl              toggle the window
/frl on           enable script profiling (needs a reload)
/frl off          turn it back off
/frl report [n]   cumulative worst offenders since login, printed to chat
/frl reset        zero the counters, start a fresh window
/frl rows <n>     how many lines to show (3-40)
/frl rate <n>     seconds between samples (0.25-10)
/frl lock         stop the window being dragged
```

`/freeloader` works as the full-length alias. Escape closes the window.

## Script profiling

CPU numbers only exist when the `scriptProfile` CVar is on, and that CVar only
changes on a UI reload — `/frl on` sets it and offers the reload. Memory and
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
  `OnUpdate`. `/frl report` still works — it reads cumulative counters.

## License

Do what you like with it.
