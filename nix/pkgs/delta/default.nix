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
    rev = "bbf518c04e0f81c322f60028438ea1c75cdf086c";
    hash = "sha256-tq6eTQnQURrUObaZjpuhGA5LKD33JleUt3IldX8TlSc=";
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
