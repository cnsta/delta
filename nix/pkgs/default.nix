{
  lib,
  newScope,
  zig_0_16,
  riverSrc,
}:
lib.makeScope newScope (self: {
  # Pinned until the zig 0.17 migration.
  zig = zig_0_16;
  inherit riverSrc;
  zigDeps = self.callPackage ./zig-deps.nix {};
  river = self.callPackage ./river/package.nix {};
  delta-wm = self.callPackage ./delta/package.nix {};
})
