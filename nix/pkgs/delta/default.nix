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
    rev = "4e5cfb6cf949dc950bc32ad5006b07e740f17a56";
    hash = "sha256-gRwurPA+KLb/Gie2mL1aNuPD3rC0JzHw17D9awZgrXA=";
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
