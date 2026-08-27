# Structure adapted from dmkhitaryan https://github.com/dmkhitaryan/river-next-nix-module
{
  lib,
  stdenv,
  fetchFromForgejo,
  zig,
  libxkbcommon,
  wayland,
  wayland-protocols,
  wayland-scanner,
  pkg-config,
  linuxHeaders,
  callPackage,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "delta";
  version = "unstable-2026-08-27";

  src = fetchFromForgejo {
    domain = "git.cnst.dev";
    owner = "cnst";
    repo = "delta";
    rev = "b2ebcf8796aa4f0d09d269dc170c21c9d1b5794a";
    hash = "sha256-Hym5KFttgaEsTb9+7n/jj1tQ0Qj99+5PAjg1sq6vEOI=";
  };

  deps = callPackage ./build.zig.zon.nix {};

  nativeBuildInputs = [
    zig
    pkg-config
    wayland-scanner
    wayland-protocols
  ];

  buildInputs = [
    libxkbcommon
    wayland
    linuxHeaders
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Doptimize=ReleaseSafe"
  ];

  meta = {
    homepage = "https://git.cnst.dev/cnst/delta";
    description = "A window manager for river";
    license = lib.licenses.bsd0;
    mainProgram = "delta-wm";
    platforms = lib.platforms.linux;
  };
})
