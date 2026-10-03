#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash nix jq zon2nix alejandra
#
# nix/builder.sh              move river to upstream main, refresh Zig locks, build
# nix/builder.sh --no-update  refresh Zig locks and build, keep river's pin
# nix/builder.sh --no-build   skip the build
#
# River's source is the flake's `river` input. A plain `nix flake update river`
# works too, as long as River's Zig dependencies didn't change, evaluation
# says so when they did (nix/pkgs/zig-deps.nix), and then this script is needed.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

update=true
build=true
for arg in "$@"; do
  case "$arg" in
  --no-update) update=false ;;
  --no-build) build=false ;;
  -h | --help)
    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown argument: $arg" >&2
    exit 1
    ;;
  esac
done

# path: rather than the git tree, so uncommitted changes count.
flake="path:$PWD"

lock() {
  local zon=$1 out=$2
  echo "==> $out"
  local tmp="${out%.nix}.tmp.nix"
  zon2nix "$zon" >"$tmp"
  # fetchgit can't take ?ref= queries, and codeload tarballs aren't stable.
  sed -i \
    -e 's|url = "\(https://[^"?]*\)?ref=[^"]*"|url = "\1"|g' \
    -e 's|url = "https://codeload\.github\.com/\([^/]*\)/\([^/]*\)/tar\.gz/refs/tags/\([^"]*\)"|url = "https://github.com/\1/\2/archive/refs/tags/\3.tar.gz"|g' \
    "$tmp"
  alejandra --quiet "$tmp" >/dev/null
  mv "$tmp" "$out"
}

if $update; then
  echo "==> updating the river input"
  nix flake update river --flake "$flake"
fi

river_src=$(nix flake archive --json "$flake" | jq -r '.inputs.river.path')
echo "    river: $(nix flake metadata --json "$flake" | jq -r '.locks.nodes.river.locked.rev')"

lock "$river_src/build.zig.zon" nix/pkgs/river/build.zig.zon.nix
lock build.zig.zon nix/pkgs/delta/build.zig.zon.nix

if $build; then
  echo "==> building"
  nix build --no-link "$flake#river" "$flake#default"
fi
