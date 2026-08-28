{
  lib,
  stdenv,
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
  version = "unstable";

  src = lib.cleanSource ../../..;

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
