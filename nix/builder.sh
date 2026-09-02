#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash git nix-prefetch-git zon2nix jq gnused ed alejandra
#
# ./builder.sh                update upstream pins, sync local locks, build
# ./builder.sh --update       update upstream pins only
# ./builder.sh --sync         regenerate local dependency locks only
# ./builder.sh --build        build only
# ./builder.sh --sync delta   regenerate delta's lock

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

usage() {
  sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
}

sync_local_zon() {
  local name=$1
  local zonfile="pkgs/$name/build.zig.zon.nix"
  local zon="../build.zig.zon"
  local digest

  digest=$(sha256sum "$zon" | cut -d' ' -f1)

  if [ -s "$zonfile" ] && [ "$(current_zon_digest "$zonfile")" = "$digest" ]; then
    return 0
  fi

  echo "    regenerating $zonfile"
  zon2nix "$zon" >"$zonfile"
  write_zon_digest_comment "$zonfile" "$digest"
  sanitize_zon "$zonfile"
  alejandra --quiet "$zonfile" >/dev/null
}

do_update=false
do_build=false
do_sync=false
only=()

for arg in "$@"; do
  case "$arg" in
  --update) do_update=true ;;
  --build) do_build=true ;;
  --sync) do_sync=true ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "unknown flag: $arg" >&2
    exit 1
    ;;
  *) only+=("$arg") ;;
  esac
done

if ! $do_update && ! $do_build; then
  do_update=true
  do_build=true
fi

packages=(
  "river|https://codeberg.org/river/river|main"
)

local_packages=(
  "delta"
)

selected() {
  [ ${#only[@]} -eq 0 ] && return 0
  local n
  for n in "${only[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

current_rev() {
  sed -n 's/.*rev = "\([^"]*\)".*/\1/p' "$1" | head -n1
}

zon_version() {
  sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*unstable-[^"]*\)";.*/\1/p' "$1" | head -n1
}

current_zon_digest() {
  sed -n 's/^# build\.zig\.zon-sha256: //p' "$1" | head -n1
}

write_zon_digest_comment() {
  local f=$1 digest=$2 tmp
  tmp=$(mktemp)
  {
    printf '# build.zig.zon-sha256: %s\n' "$digest"
    sed '1{/^# build\.zig\.zon-sha256: /d;}' "$f"
  } >"$tmp"
  mv "$tmp" "$f"
}

sanitize_zon() {
  local f=$1
  sed -i 's|url = "\(https://[^"?]*\)?ref=[^"]*"|url = "\1"|g' "$f"
  sed -i 's|url = "https://codeload\.github\.com/\([^/][^/]*\)/\([^/][^/]*\)/tar\.gz/refs/tags/\([^"]*\)"|url = "https://github.com/\1/\2/archive/refs/tags/\3.tar.gz"|g' "$f"
  if grep -q '?ref=' "$f"; then
    echo "    ERROR: $f still contains a query string after sanitising" >&2
    return 1
  fi
}

update_src() {
  local file=$1 rev=$2 hash=$3 version=$4

  if [ -n "$version" ]; then
    sed -i -E \
      "/^[[:space:]]*version = \"[^\"]*unstable-[^\"]*\";/s|version = \"[^\"]*\";|version = \"$version\";|" \
      "$file"
  fi

  ed -s "$file" >/dev/null <<EOF
/src = fetchFrom[A-Za-z]* {/
/rev = /s|rev = "[^"]*"|rev = "$rev"|
/hash = /s|hash = "[^"]*"|hash = "$hash"|
w
q
EOF
}

update_one() {
  local name=$1 url=$2 branch=$3
  local pkgfile="pkgs/$name/package.nix"
  local zonfile="pkgs/$name/build.zig.zon.nix"

  echo "==> $name"
  local prefetch rev hash path date zon digest upstream version
  prefetch=$(nix-prefetch-git --url "$url" --rev "refs/heads/$branch" --quiet)
  rev=$(jq -r .rev <<<"$prefetch")
  hash=$(jq -r .hash <<<"$prefetch")
  path=$(jq -r .path <<<"$prefetch")
  date=$(jq -r '.date | split("T")[0]' <<<"$prefetch")

  zon="$path/build.zig.zon"
  if [ ! -f "$zon" ]; then
    echo "    ERROR: no build.zig.zon in the prefetched tree" >&2
    return 1
  fi
  digest=$(sha256sum "$zon" | cut -d' ' -f1)

  case "$(current_version "$pkgfile")" in
  "")
    version=""
    ;;
  unstable-*)
    version="unstable-$date"
    ;;
  *)
    upstream=$(zon_version "$zon")
    version="${upstream:+$upstream-}unstable-$date"
    ;;
  esac

  local pinned
  pinned=$(current_rev "$pkgfile")

  if [ "$pinned" = "$rev" ]; then
    echo "    already at $rev"
  else
    echo "    $pinned -> $rev ($date)"
  fi

  echo "    version ${version:-pinned in $pkgfile, left alone}"
  update_src "$pkgfile" "$rev" "$hash" "$version"

  if [ -s "$zonfile" ] && [ "$(current_zon_digest "$zonfile")" = "$digest" ]; then
    echo "    lock in sync with build.zig.zon"
  else
    echo "    regenerating $zonfile"
    zon2nix "$zon" >"$zonfile"
    write_zon_digest_comment "$zonfile" "$digest"
    sanitize_zon "$zonfile"
    alejandra --quiet "$zonfile" >/dev/null
  fi
}

build_one() {
  local name=$1 attr=$2
  echo "==> $name: building"
  nix build --no-link ".#$attr"
}

failed=()

for entry in "${packages[@]}"; do
  IFS='|' read -r name url branch <<<"$entry"
  selected "$name" || continue
  $do_update || continue
  update_one "$name" "$url" "$branch" || failed+=("update:$name")
done

for entry in "${packages[@]}"; do
  IFS='|' read -r name _ _ <<<"$entry"
  selected "$name" || continue
  $do_build || continue
  build_one "$name" || failed+=("build:$name")
done

for name in "${local_packages[@]}"; do
  selected "$name" || continue
  $do_sync || continue
  echo "==> $name"
  sync_local_zon "$name" || failed+=("sync:$name")
done

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "failures:"
  printf '  - %s\n' "${failed[@]}"
  echo
  echo "revert with: git checkout -- $(pwd)"
  exit 1
fi
