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

  src = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../build.zig
      ../../../build.zig.zon
      ../../../src
      ../../../protocol
    ];
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

  doCheck = true;

  zigCheckFlags = finalAttrs.zigBuildFlags;

  postInstall = ''
    installShellCompletion --cmd delctl \
      --bash contrib/completion/delctl.bash \
      --fish contrib/completion/delctl.fish \
      --zsh contrib/completion/delctl.zsh
  '';

  meta = {
    homepage = "https://git.cnst.dev/cnst/delta";
    description = "A window manager for river";
    license = lib.licenses.bsd0;
    mainProgram = "delta-wm";
    platforms = lib.platforms.linux;
  };
})
