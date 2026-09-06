const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = @import("wayland").Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_xkb_bindings_v1", 3);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_compositor", 4);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const files = b.addWriteFiles();
    const headers = files.add("headers.h",
        \\#include <linux/input-event-codes.h>
    );
    const input_event_codes = b.addTranslateC(.{
        .root_source_file = headers,
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "delta-wm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayland", .module = wayland },
                .{ .name = "xkbcommon", .module = xkbcommon },
                .{ .name = "event-codes", .module = input_event_codes.createModule() },
            },
        }),
    });

    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    b.installArtifact(exe);

    const ctl = b.addExecutable(.{
        .name = "delctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/delctl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    ctl.root_module.link_libc = true;
    b.installArtifact(ctl);

    const ctl_step = b.step("ctl", "Build delctl only");
    ctl_step.dependOn(&b.addInstallArtifact(ctl, .{}).step);

    const run_step = b.step("run", "Run delta");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
