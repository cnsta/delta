{
  mkShell,
  lib,
  pkg-config,
  libxkbcommon,
  alejandra,
  wayland,
  wayland-scanner,
  wayland-protocols,
  zon2nix,
  zig,
  river,
  linuxHeaders,
  pixman,
  libinput,
  libevdev,
  udev,
  libGL,
  vulkan-headers,
  vulkan-loader,
  scdoc,
  complgen,
  bash-completion,
}: let
  runtimeLibs = [
    wayland
    libxkbcommon
    pixman
    libinput
    libevdev
    udev
    libGL
    vulkan-loader
  ];
in
  mkShell {
    name = "delta-dev-shell";

    nativeBuildInputs = [
      zig
      zon2nix
      pkg-config
      wayland-scanner
      wayland-protocols
      alejandra
      scdoc
      complgen
      bash-completion
    ];

    buildInputs =
      runtimeLibs
      ++ [
        linuxHeaders
        vulkan-headers
        river
      ];

    env = {
      ZIG_GLOBAL_CACHE_DIR = "../.zig-cache/global";
      LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
    };

    shellHook = ''
      echo "⚡ river / delta dev shell ready"
      echo "Zig version: $(zig version)"
      echo "Zon2nix:     $(zon2nix --version 2>/dev/null || echo "available")"
    '';
  }
