# Freeloader

Which addon isn't paying its way?

Shows CPU and memory usage from other addons in a single persistent GUI window.

No libraries, Super Minimal, costs nothing until opened!

Built and tested against the 2.5.6 anniversary client.

Just a little thing Claude built for me, there are likely better options out there, but this one works fine!

Not sure if I'll be maintaining this one, but feel free to reach out to @wallhackjack on discord. 

## Usage

```
/free                  Toggle the window, and print this list
/free toggle           Toggle script profiling, the WoW setting that powers Freeloader
/free memory           Track allocation rate, the KB/s column (default off)
/free report <count>   Cumulative worst offenders since login, printed to chat
/free reset            Zero the counters and start a fresh window
/free rows <count>     How many lines the window shows (3-40)
/free rate <seconds>   How often the table refreshes (0.25-10, default 3)
/free lock             Stop the window being dragged
```

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
