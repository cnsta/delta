{
  description = "delta: a window manager for river";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    forEachSystem = nixpkgs.lib.genAttrs systems;

    pkgsFor = system: import nixpkgs {inherit system;};

    zigFor = pkgs: pkgs.zig_0_16;

    buildToolsFor = pkgs:
      with pkgs; [
        pkg-config
        wayland-scanner
        wayland-protocols
        linuxHeaders
      ];

    runtimeLibsFor = pkgs:
      with pkgs; [
        wayland
        libxkbcommon
      ];

    devToolsFor = pkgs:
      with pkgs; [
        river
        foot
      ];
  in {
    devShells = forEachSystem (
      system: let
        pkgs = pkgsFor system;
        zig = zigFor pkgs;
        runtimeLibs = runtimeLibsFor pkgs;
      in {
        default = pkgs.mkShell {
          packages =
            [
              zig
              pkgs.zls
            ]
            ++ buildToolsFor pkgs
            ++ devToolsFor pkgs;

          buildInputs = runtimeLibs;

          env = {
            ZIG_GLOBAL_CACHE_DIR = ".zig-cache/global";
            LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath runtimeLibs;
          };

          shellHook = ''
            echo "⚡ delta dev shell — $(zig version)"
          '';
        };
      }
    );

    formatter = forEachSystem (system: (pkgsFor system).nixfmt-rfc-style);
  };
}
