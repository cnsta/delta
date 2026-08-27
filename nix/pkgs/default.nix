{
  lib,
  newScope,
}:
lib.makeScope newScope (self: {
  river = self.callPackage ./river {};
  delta = self.callPackage ./delta {};
})
