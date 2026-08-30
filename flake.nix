{
  description = "delta: a window manager for river";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";

    systems.url = "github:nix-systems/default";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
      };
    };

    zon2nix = {
      url = "github:jcollie/zon2nix?ref=main";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    zon2nix,
    systems,
    ...
  }: let
    inherit (nixpkgs) lib legacyPackages;
    platforms = lib.attrNames zig.packages;
    forAllPlatforms = f: lib.genAttrs platforms (s: f legacyPackages.${s});
  in {
    devShells = forAllPlatforms (pkgs: {
      default =
        pkgs.callPackage ./nix/devShell.nix
        {
          zig = zig.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
          zon2nix = zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix;
        };
    });

    packages = forAllPlatforms (pkgs: let
      scope = pkgs.callPackage ./nix/pkgs {};
    in {
      inherit (scope) river delta-wm;
      default = scope.delta-wm;
    });

    overlays.default = final: _prev: let
      scope = final.callPackage ./nix/pkgs {};
    in {
      inherit (scope) delta-wm river;
    };

    lib.withDelta = ashell:
      ashell.overrideAttrs (old: {
        pname = "ashell-delta";

        postPatch =
          (old.postPatch or "")
          + ''
            echo "applying delta backend..."
            set -x
            pwd
            ls src/services/compositor/
            cp ${./contrib/ashell/delta.rs} src/services/compositor/delta.rs
              ls -l src/services/compositor/
              set +x
              substituteInPlace src/services/compositor/mod.rs \
                --replace-fail 'pub mod generic;' 'pub mod delta;
              pub mod generic;'

              substituteInPlace src/services/compositor/mod.rs \
                --replace-fail 'CompositorChoice::Generic => generic::run_listener(&tx).await,' \
                  'CompositorChoice::Delta => delta::run_listener(&tx).await,
                          CompositorChoice::Generic => generic::run_listener(&tx).await,'

              substituteInPlace src/services/compositor/mod.rs \
                --replace-fail 'CompositorChoice::Generic => generic::execute_command(command).await,' \
                  'CompositorChoice::Delta => delta::execute_command(command).await,
                          CompositorChoice::Generic => generic::execute_command(command).await,'

              substituteInPlace src/services/compositor/mod.rs \
                --replace-fail '} else if generic::is_available() {' \
                  '} else if delta::is_available() {
                          Some(CompositorChoice::Delta)
                      } else if generic::is_available() {'

              substituteInPlace src/services/compositor/types.rs \
                --replace-fail '    Generic,' '    Delta,
                  Generic,'
          '';

        meta =
          (old.meta or {})
          // {
            description = "ashell with a delta compositor backend";
          };
      });

    formatter = forAllPlatforms (pkgs: pkgs.alejandra);

    nixosModules.river = import ./nix/nixosModule.nix;
    nixosModules.default = self.nixosModules.river;
  };
}
