# The Zig package farm for `zig build --system`, generated from build.zig.zon by
# zon2nix (nix/builder.sh). Fails at evaluation, not halfway through a build,
# when build.zig.zon asks for a package the generated lock doesn't have: the
# river input moves with `nix flake update`, the lock only with the builder.
{
  lib,
  callPackage,
}: {
  name,
  zon,
  lock,
}: let
  wanted = lib.pipe (builtins.readFile zon) [
    (builtins.split ''\.hash = "([^"]+)"'')
    (builtins.filter builtins.isList)
    (map builtins.head)
  ];

  lockFn = import lock;
  locked = map (entry: entry.name) (lockFn (lib.mapAttrs (arg: _:
    if arg == "linkFarm"
    then _: entries: entries
    else _: null) (lib.functionArgs lockFn)));

  missing = lib.subtractLists locked wanted;
in
  if missing == []
  then callPackage lock {}
  else
    throw ''
      ${name}: build.zig.zon needs Zig packages missing from nix/pkgs/${name}/build.zig.zon.nix:
        ${lib.concatStringsSep "\n  " missing}
      Run nix/builder.sh --no-update in the delta repository and commit the result.
    ''
