# $\Delta$ delta

A window manager for [river](https://codeberg.org/river/river).

River 0.5 splits the compositor from the window manager: river handles
rendering, input and output configuration, and a separate client decides where
windows go. delta is such a client, speaking `river-window-management-v1`.

Written in Zig. Two dependencies: `zig-wayland` and `zig-xkbcommon`.

## Status & Contribution

Usable, I'm currently daily-driving it, however, it should not be considered
stable. Expect the config format to change, and things to break. I do this on my
spare time as a hobby. Contributions are appreciated, but perhaps forking the
code and building something for yourself is more advisible.

**Works:** bsp-ish tiling, workspaces, floating windows, fullscreen, keyboard
and pointer resize, directional focus, key repeat, pointer warping, layer shell
(bars, launchers, lock screens), window rules, live config reload, an IPC, basic
animations.

**Missing:** Multi-seat beyond the obvious cases, rules that re-evaluate when a
window renames itself. General hardening, optimization, and time.

**Notes:** I have only tested this on NixOS and I have no immediate plans change
this fact. There is a functioning [ashell](https://github.com/MalpenZibo/ashell)
patch packaged with my nixosModule. This enables ashell's workspace widget. I'm
also tinkering with what will be an optional screen locker, stay tuned (as if
I'm not the only one reading this).

**Disclaimer:** What you read below might not be completely up to date.

## Building

```
zig build
```

Needs Zig 0.16, `wayland-client`, `libxkbcommon`, and the Linux input headers.

Run it under river:

```
river -c /path/to/delta-wm
```

## Nix

The flake exposes `packages.delta-wm`, `packages.river` (river 0.5 built with
the Vulkan renderer available), and `nixosModules.default`.

    {
      inputs.delta.url = "git+https://git.cnst.dev/cnst/delta";

      # in your NixOS configuration
      imports = [ inputs.delta.nixosModules.default ];

      programs.river-delta = {
        enable = true;
        renderer = "vulkan";
      };
    }

The module sets up a systemd user session, an XDG portal, and optionally kanshi.
`programs.river-delta.sessionScript` is the entry point to hand to greetd
directly, rather than scraping `Exec=` out of a desktop entry.

The config file is not generated. Write `~/.config/delta/config.zon` by hand,
delta reloads it when you save.

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

    .window_rules = .{
        .{ .matches = .{.{ .app_id = "vesktop" }}, .open_workspace = 4 },
        .{ .matches = .{.{ .app_id = "*", .dialog = true }}, .open_floating = true },
    },
}
```

ZON rather than a bespoke format: no parser to write, no dependency to add, type
and field errors for free, and it generates cleanly from Nix.

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
