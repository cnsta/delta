# Modified from dmkhitaryan's nix module.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    optionalString
    types
    ;

  cfg = config.programs.river-delta;

  riverPkgs = pkgs.callPackage ./pkgs {};

  systemctl = "${pkgs.systemd}/bin/systemctl";
  dbusUpdate = "${pkgs.dbus}/bin/dbus-update-activation-environment";

  importedVariables =
    [
      "WAYLAND_DISPLAY"
      "XDG_CURRENT_DESKTOP"
      "XDG_SESSION_DESKTOP"
      "XDG_SESSION_TYPE"
      "XDG_RUNTIME_DIR"
      "PATH"
    ]
    ++ lib.optional cfg.xwayland.enable "DISPLAY"
    ++ cfg.extraImportedVariables;

  initScript = pkgs.writeShellScript "river-init" ''
    set -u

    set --
    for var in ${toString importedVariables}; do
      eval "value=\''${$var-}"
      if [ -n "$value" ]; then
        set -- "$@" "$var"
      else
        ${systemctl} --user unset-environment "$var" || true
      fi
    done

    if [ "$#" -gt 0 ]; then
      ${systemctl} --user import-environment "$@"
      ${dbusUpdate} --systemd "$@"
    fi

    ${cfg.extraSessionCommands}

    if [ -n "''${NOTIFY_SOCKET-}" ]; then
      ${pkgs.systemd}/bin/systemd-notify --ready
    fi

    exec ${cfg.windowManager.command}
  '';

  sessionScript = pkgs.writeShellScript "river-session" ''
    set -eu

    if ${systemctl} --user -q is-active river-delta.service; then
      echo "river-session: a river session is already running on this user manager." >&2
      exit 1
    fi

    ${systemctl} --user reset-failed river-delta.service river-shutdown.target 2>/dev/null || true

    ${systemctl} --user unset-environment WAYLAND_DISPLAY DISPLAY || true

    export XDG_CURRENT_DESKTOP=river
    export XDG_SESSION_DESKTOP=river
    export XDG_SESSION_TYPE=wayland
    ${systemctl} --user import-environment \
      XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE

    exec ${systemctl} --user start --wait river-delta.service
  '';

  sessionPackage = pkgs.writeTextFile {
    name = "river-delta-session";
    destination = "/share/wayland-sessions/river.desktop";
    text = ''
      [Desktop Entry]
      Name=River
      Comment=River compositor with the ${cfg.windowManager.name} window manager
      Exec=${sessionScript}
      Type=Application
      DesktopNames=river
    '';
    derivationArgs.passthru.providedSessions = ["river"];
  };

  kanshiConfigFile =
    optionalString (cfg.kanshi.config != null)
    " -c ${pkgs.writeText "kanshi-config" cfg.kanshi.config}";
in {
  options.programs.river-delta = {
    enable = mkEnableOption "the river compositor with a systemd-managed session";

    package = mkOption {
      type = types.package;
      default = riverPkgs.river.override {
        xwaylandSupport = cfg.xwayland.enable;
      };
      defaultText = lib.literalMD "`river` from this flake";
      description = "The river compositor package.";
    };

    windowManager = {
      name = mkOption {
        type = types.str;
        default = "delta-wm";
        description = ''
          Name of the window manager. Used for the session comment and, via
          `command` below, for the binary name -- `delta-wm` rather than
          `delta` because the latter is the git pager on most systems.
        '';
      };

      renderer = mkOption {
        type = types.nullOr (types.enum ["gles2" "vulkan" "pixman"]);
        default = null;
        example = "vulkan";
        description = ''
          Value for `WLR_RENDERER`. Null lets wlroots choose, which today means
          GLES2.

          This is a compositor setting, not a window manager one: delta issues no
          drawing commands at all, so every river window manager renders through
          whatever this selects. It is not a delta feature and never can be.

          `vulkan` requires wlroots to have been *built* with it. If it was not,
          river fails at startup with "Cannot create Vulkan renderer: disabled at
          compile-time" rather than falling back -- on a real session that is a
          black screen with no way back, so test it nested first. The river
          package in this flake takes `vulkanSupport` to turn the build flag on.
        '';
      };

      package = mkOption {
        type = types.package;
        default = riverPkgs.delta-wm;
        defaultText = lib.literalMD "`delta` from this flake, with the local focus patch";
        description = ''
          Window manager package. River 0.4+ spawns the window manager itself
          over a private socket, so it cannot be a separate systemd unit.
        '';
      };

      command = mkOption {
        type = types.str;
        default = "${cfg.windowManager.package}/bin/${cfg.windowManager.name}";
        defaultText = lib.literalMD "`\${windowManager.package}/bin/\${windowManager.name}`";
        description = ''
          Command river execs as the window manager. Swap this out to run a
          different river window manager without touching anything else.
        '';
      };
    };

    xwayland.enable = mkEnableOption "XWayland support" // {default = true;};

    xdgAutostart.enable =
      mkEnableOption "XDG autostart entries via xdg-desktop-autostart.target"
      // {default = true;};

    trayTarget.enable =
      mkEnableOption ''
        a tray.target user target.
      ''
      // {default = true;};

    portal = {
      enable = mkEnableOption "xdg-desktop-portal with the wlr and gtk backends" // {default = true;};
    };

    kanshi = {
      enable = mkEnableOption "the kanshi output management daemon";

      package = mkPackageOption pkgs "kanshi" {};

      config = mkOption {
        type = types.nullOr types.lines;
        default = null;
        example = ''
          profile "desk" {
            output DP-3 mode 2560x1440@239.970Hz position 0,0 scale 1
          }
        '';
        description = "Contents of the kanshi config file. When null, kanshi uses its default search paths.";
      };
    };

    path = mkOption {
      type = types.str;
      default = lib.concatStringsSep ":" [
        "%h/.local/bin"
        "/run/wrappers/bin"
        "%h/.nix-profile/bin"
        "/etc/profiles/per-user/%u/bin"
        "/nix/var/nix/profiles/default/bin"
        "/run/current-system/sw/bin"
      ];
      description = ''
        PATH for the compositor and everything it spawns, including every
        `launch` keybinding. systemd unit specifiers are expanded.
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      example = lib.literalExpression "with pkgs; [ fuzzel ghostty ]";
      description = "Extra packages to install system-wide alongside river.";
    };

    extraSessionCommands = mkOption {
      type = types.lines;
      default = "";
      example = "systemctl --user start my-thing.service";
      description = ''
        Shell run inside the compositor after the environment is published but
        before readiness is signalled.
      '';
    };

    extraImportedVariables = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["XCURSOR_THEME" "XCURSOR_SIZE"];
      description = "Additional variables to publish to systemd and D-Bus, if set in the compositor.";
    };

    sessionScript = mkOption {
      type = types.path;
      readOnly = true;
      description = ''
        The session entrypoint. Point greetd at this directly instead of
        scraping Exec= out of a desktop entry:

        ```nix
        services.greetd.settings.initial_session.command =
          config.programs.river-delta.sessionScript;
        ```
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.windowManager.renderer
          != "vulkan"
          || (cfg.package.passthru.vulkanSupport or true);
        message = ''
          programs.river-delta.renderer = "vulkan" but the configured river
          package was built without the Vulkan renderer. river would fail at
          startup with "Cannot create Vulkan renderer: disabled at
          compile-time", which on a real session means a black screen and no
          way back. Build river with vulkanSupport = true, or leave renderer
          null.
        '';
      }
    ];

    programs.river-delta.sessionScript = sessionScript;

    environment.systemPackages =
      [cfg.package cfg.windowManager.package]
      ++ lib.optional cfg.kanshi.enable cfg.kanshi.package
      ++ cfg.extraPackages;

    programs.xwayland.enable = cfg.xwayland.enable;
    security.polkit.enable = true;
    services.graphical-desktop.enable = true;
    services.displayManager.sessionPackages = [sessionPackage];

    services.dbus.implementation = lib.mkDefault "broker";

    systemd.user.services.river-delta = {
      description = "River Wayland compositor session";
      documentation = ["man:river(1)"];
      bindsTo = ["graphical-session.target"];
      before =
        ["graphical-session.target"]
        ++ lib.optional cfg.xdgAutostart.enable "xdg-desktop-autostart.target";
      wants =
        ["graphical-session-pre.target"]
        ++ lib.optional cfg.xdgAutostart.enable "xdg-desktop-autostart.target";
      after = ["graphical-session-pre.target"];

      unitConfig = {
        OnFailure = "river-shutdown.target";
        OnSuccess = "river-shutdown.target";
        CollectMode = "inactive-or-failed";
      };

      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = "${cfg.package}/bin/river -c ${initScript}";
        Environment =
          ["PATH=${cfg.path}"]
          ++ lib.optional (cfg.windowManager.renderer != null) "WLR_RENDERER=${cfg.windowManager.renderer}";

        UnsetEnvironment = "WAYLAND_DISPLAY DISPLAY";

        ExecStopPost = "${systemctl} --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP";

        Restart = "no";
        TimeoutStartSec = "30s";
        TimeoutStopSec = "10s";
        Slice = "session.slice";
        OOMScoreAdjust = -500;
      };
    };

    systemd.user.targets.river-shutdown = {
      description = "Shut down a running river session";
      conflicts = [
        "graphical-session.target"
        "graphical-session-pre.target"
        "xdg-desktop-autostart.target"
      ];
      after = [
        "graphical-session.target"
        "graphical-session-pre.target"
        "xdg-desktop-autostart.target"
      ];
      unitConfig = {
        DefaultDependencies = "no";
        StopWhenUnneeded = true;
      };
    };

    systemd.user.targets.tray = mkIf cfg.trayTarget.enable {
      description = "System tray";
      requires = ["graphical-session-pre.target"];
      after = ["graphical-session-pre.target"];
      partOf = ["graphical-session.target"];
      wantedBy = ["graphical-session.target"];
    };

    systemd.user.services.kanshi = mkIf cfg.kanshi.enable {
      description = "kanshi output management";
      partOf = ["graphical-session.target"];
      after = ["graphical-session.target"];
      wantedBy = ["graphical-session.target"];
      serviceConfig = {
        ExecStart = "${cfg.kanshi.package}/bin/kanshi${kanshiConfigFile}";
        Restart = "always";
        RestartSec = 1;
        Slice = "session.slice";
      };
      unitConfig.StartLimitIntervalSec = 0;
    };

    xdg.portal = mkIf cfg.portal.enable {
      enable = true;
      xdgOpenUsePortal = true;
      wlr = {
        enable = true;
        settings.screencast = {
          chooser_type = "simple";
          chooser_cmd = "${pkgs.slurp}/bin/slurp -f %o";
        };
      };
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
      config.river.default = lib.mkDefault ["gtk" "wlr"];
    };
  };
}
