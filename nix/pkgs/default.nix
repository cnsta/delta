{
  lib,
  newScope,
  zig,
}:
lib.makeScope newScope (self: {
  inherit zig;
  river = self.callPackage ./river/package.nix {};
  delta-wm = self.callPackage ./delta/package.nix {};
})
