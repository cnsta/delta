# Taken from [dmkhitaryan](https://github.com/dmkhitaryan/river-next-nix-module/blob/main/river-next.nix)
{
  lib,
  stdenv,
  callPackage,
  fetchFromGitLab,
  fetchFromCodeberg,
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
}: let
  wlroots_0_20_1 = wlroots_0_20.overrideAttrs (new: prev: {
    version = "0.20.1";
    src = fetchFromGitLab {
      domain = "gitlab.freedesktop.org";
      owner = "wlroots";
      repo = "wlroots";
      tag = new.version;
      hash = "sha256-uuc1dn13FXvFSBvE3+QOi35rLJZmWIUst64oaXGdPFk=";
    };

    buildInputs =
      (prev.buildInputs or [])
      ++ lib.optionals vulkanSupport [vulkan-headers vulkan-loader];

    mesonFlags =
      (prev.mesonFlags or [])
      ++ lib.optional vulkanSupport "-Drenderers=gles2,vulkan";
  });
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "river-next";
    version = "0.5.0-dev";
    outputs = ["out"] ++ lib.optionals withManpages ["man"];

    src = fetchFromCodeberg {
      owner = "river";
      repo = "river";
      rev = "7e15d4985e6b22a338494c609bcbf5bfe583f7a2";
      hash = "sha256-aw1aZXy7S2atr8L+uFb4yX1lY8OflnVGyVOHIAGoDHs=";
    };

    deps = callPackage ./build.zig.zon.nix {};

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
        wlroots_0_20_1
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
      wlroots = wlroots_0_20_1;
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
