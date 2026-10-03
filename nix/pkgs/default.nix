{
  lib,
  newScope,
  zig,
  riverSrc,
}:
lib.makeScope newScope (self: {
  inherit zig riverSrc;
  zigDeps = self.callPackage ./zig-deps.nix {};
  river = self.callPackage ./river/package.nix {};
  delta-wm = self.callPackage ./delta/package.nix {};
})
