{
  lib,
  newScope,
}:
lib.makeScope newScope (self: {
  river = self.callPackage ./river/package.nix {};
  delta = self.callPackage ./delta/package.nix {};
})
