# Built upon code from [dmkhitaryan](https://github.com/dmkhitaryan/river-next-nix-module/blob/main/river-next.nix)
{
  lib,
  stdenv,
  riverSrc,
  zigDeps,
  libGL,
  libx11,
  libevdev,
  libinput,
  libxkbcommon,
  pixman,
  pkg-config,
  scdoc,
  udev,
  versionCheckHook,
  vulkan-headers,
  vulkan-loader,
  wayland,
  wayland-protocols,
  wayland-scanner,
  wlroots_0_20,
  xwayland,
  zig,
  withManpages ? true,
  xwaylandSupport ? true,
  vulkanSupport ? true,
}:
assert lib.versionAtLeast wlroots_0_20.version "0.20.2"; let
  wlroots_0_20' = wlroots_0_20.overrideAttrs (prev: {
    buildInputs =
      (prev.buildInputs or [])
      ++ lib.optionals vulkanSupport [vulkan-headers vulkan-loader];

    mesonFlags =
      (prev.mesonFlags or [])
      ++ lib.optional vulkanSupport "-Drenderers=gles2,vulkan";

    patches =
      (prev.patches or [])
      ++ [
        ./wlroots-xwm-reclaim-selection-on-focus.patch
      ];
  });
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "river-next";
    version = lib.pipe "${riverSrc}/build.zig.zon" [
      builtins.readFile
      (builtins.split ''\.version = "([^"]+)"'')
      (builtins.filter builtins.isList)
      builtins.head
      builtins.head
    ];
    outputs = ["out"] ++ lib.optionals withManpages ["man"];

    src = riverSrc;

    deps = zigDeps {
      name = "river";
      zon = "${riverSrc}/build.zig.zon";
      lock = ./build.zig.zon.nix;
    };

    patches = [./river-hdr-output.patch];

    nativeBuildInputs =
      [
        pkg-config
        wayland-scanner
        xwayland
        zig
      ]
      ++ lib.optional withManpages scdoc;

    buildInputs =
      [
        libGL
        libevdev
        libinput
        libxkbcommon
        pixman
        udev
        wayland
        wayland-protocols
        wlroots_0_20'
      ]
      ++ lib.optional xwaylandSupport libx11;

    zigBuildFlags =
      [
        "--system"
        "${finalAttrs.deps}"
      ]
      ++ lib.optional withManpages "-Dman-pages"
      ++ lib.optional xwaylandSupport "-Dxwayland"
      ++ ["-Doptimize=ReleaseSafe"];

    postInstall = ''
      install contrib/river.desktop -Dt $out/share/wayland-sessions
    '';

    doInstallCheck = true;
    nativeInstallCheckInputs = [versionCheckHook];
    versionCheckProgramArg = "-version";

    passthru = {
      providedSessions = ["river"];
      inherit vulkanSupport;
      wlroots = wlroots_0_20';
    };

    meta = {
      homepage = "https://codeberg.org/river/river-classic";
      description = "Dynamic tiling wayland compositor";
      longDescription = ''
        River is a non-monolithic Wayland compositor.
        Unlike other Wayland compositors, river does not combine the compositor and window manager into one program.
        Instead, users can choose any window manager implementing the river-window-management-v1 protocol.
      '';
      changelog = "https://codeberg.org/river/river/releases/tag/v${finalAttrs.version}";
      license = lib.licenses.gpl3Only;
      maintainers = with lib.maintainers; [
        # Includes original maintainers when the file was used to generate the new version. Note: the release has now dropped on Nixpkgs.
        adamcstephens
        moni
        rodrgz
        dmkhitaryan
      ];
      mainProgram = "river";
      platforms = lib.platforms.linux;
    };
  })
