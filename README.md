# delta

A window manager for [river](https://codeberg.org/river/river).

River 0.5 splits the compositor from the window manager: river handles
rendering, input and output configuration, and a separate client decides where
windows go. delta is such a client, speaking `river-window-management-v1`.

Written in Zig. Two dependencies: `zig-wayland` and `zig-xkbcommon`.

## Status

Usable, and daily-driven by its author. Not stable. Expect the config format to
change.

**Works:** dwindle-style tiling, workspaces, floating windows, fullscreen,
keyboard and pointer resize, directional focus, key repeat, pointer warping,
layer shell (bars, launchers, lock screens), live config reload.

**Missing:** IPC, window rules, animations, multi-seat beyond the obvious cases.

## Building

```
zig build
```

Needs Zig 0.16, `wayland-client`, `libxkbcommon`, and the Linux input headers.

Run it under river:

```
river -c /path/to/delta-wm
```

Or nested inside an existing session, which is the sane way to test changes.

## Configuration

`$XDG_CONFIG_HOME/delta/config.zon`, falling back to
`~/.config/delta/config.zon`. See `example-config.zon` for the full set of
options, everything has a default and anything omitted keeps it.

```zig
.{
    .gaps = .{ .between = 8, .edge = 8 },

    .bindings = .{
        .{ .mods = .{.super}, .keys = .{"Return"}, .action = .{ .spawn = .{"foot"} } },
        .{ .mods = .{.super}, .keys = .{"q"}, .action = .close },
        .{ .mods = .{.super}, .keys = .{ "h", "Left" }, .action = .{ .focus_direction = .left } },
    },
}
```

ZON rather than a bespoke format: no parser to write, no dependency to add, type
and field errors for free, and it generates cleanly from Nix.

Key names are xkb keysym names, case sensitive, naming the **unshifted** symbol,
river resolves at level 0, so `shift` goes in `mods` and the key is still
`"plus"`, not `"question"`.

## Design

Four rules the code follows, listed because they explain most of its shape:

**Dependencies point inward.** `main` -> `Delta` -> entities -> utilities.
Nothing imports `main`.

**Listeners record, they never act.** The protocol allows window management
state to be modified only inside a manage sequence, so events set fields and
`manage` turns them into requests.

**Compositor state is edge-triggered.** Every request is sent when its answer
changes and not otherwise, which is why `Window` carries a record of what the
compositor has already been told.

**Layouts know windows and rectangles.** A layout divides an area into boxes
that tile it exactly, `layouts/rules.zig` turns a box into a content rect. Gaps
and borders are decided in one place, so a second layout inherits them for free.

## Name

Delta, because river delta.

## License

0BSD. Derived from Isaac Freund & Vladyslav Khardel's `tinywm`.
