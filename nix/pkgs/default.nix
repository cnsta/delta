{
  lib,
  newScope,
  zig_0_17,
  riverSrc,
}:
lib.makeScope newScope (self: {
  zig = zig_0_17;
  inherit riverSrc;
  zigDeps = self.callPackage ./zig-deps.nix {};
  river = self.callPackage ./river/package.nix {};
  delta-wm = self.callPackage ./delta/package.nix {};
})
