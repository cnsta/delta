{
  lib,
  newScope,
}:
lib.makeScope newScope (self: {
  river = self.callPackage ./river/package.nix {};
  delta-wm = self.callPackage ./delta/package.nix {};
})
