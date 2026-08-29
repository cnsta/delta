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

    formatter = forAllPlatforms (pkgs: pkgs.alejandra);

    nixosModules.river = import ./nix/nixosModule.nix;
    nixosModules.default = self.nixosModules.river;
  };
}
