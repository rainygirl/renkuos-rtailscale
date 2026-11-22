#!/bin/sh
# build.sh - build tailscale and tailscaled for 64-bit RenkuOS/Haiku.
#
#   ./build.sh arm64
#   ./build.sh x86_64
#
# Clones tailscale at the pinned version, applies patches/, and builds both
# binaries into dist/<arch>/. 32-bit x86 is a different port with its own
# build: see i386/.
#
# The one requirement is a Go toolchain that can target Haiku on that
# architecture, named by GO (default: "go" from PATH):
#
#   arm64    github.com/rainygirl/renkuos-golang. On RenkuOS itself that is
#            "pkgman install golang_bin", and this script then builds
#            natively; elsewhere use the cross toolchain that repository
#            builds. Apply patches/go/go-haiku-arm64-startup.patch of
#            github.com/rainygirl/renkuos-gotools to it first, or every
#            binary prints "234567" when it starts.
#   x86_64   github.com/korli/go, branch golang-1.27-haiku (what HaikuPorts'
#            golang package is built from), or that package on RenkuOS.
#
# Environment:
#   GO              the go command to use
#   TAILSCALE_REF   tailscale git ref (default: the version below)
#   WORK            scratch directory (default: ./.work)
#   KEEP=1          reuse an existing checkout in WORK instead of re-cloning
set -eu

BASE_VERSION=1.102.0
TAILSCALE_REPO=${TAILSCALE_REPO:-https://github.com/tailscale/tailscale.git}

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[ $# -eq 1 ] || die "usage: $0 arm64|x86_64"
case $1 in
	arm64) arch=arm64; goarch=arm64 ;;
	x86_64|amd64) arch=x86_64; goarch=amd64 ;;
	x86|i386|386) die "32-bit x86 is built from i386/ (see i386/README.md)" ;;
	*) die "unknown architecture: $1 (arm64 or x86_64)" ;;
esac

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
go=${GO:-go}
ref=${TAILSCALE_REF:-v$BASE_VERSION}
work=${WORK:-$here/.work}
out=$here/dist/$arch
src=$work/tailscale
deps=$work/deps

command -v "$go" >/dev/null 2>&1 || die "no Go toolchain: set GO=/path/to/go"
command -v git >/dev/null 2>&1 || die "git is required"
command -v patch >/dev/null 2>&1 || die "patch is required"
"$go" tool dist list 2>/dev/null | grep -qx "haiku/$goarch" \
	|| die "$("$go" version) cannot target haiku/$goarch; see the header of this script"

mkdir -p "$work" "$out"
export GOTOOLCHAIN=local
export GOFLAGS=-mod=mod
export GOPATH=${GOPATH:-$work/gopath}
export GOCACHE=${GOCACHE:-$work/gocache}

# --- tailscale source --------------------------------------------------------

if [ -d "$src/.git" ] && [ "${KEEP:-0}" = 1 ]; then
	note "reusing $src"
else
	rm -rf "$src"
	note "cloning tailscale $ref"
	git clone --quiet --depth 1 --branch "$ref" "$TAILSCALE_REPO" "$src"
	have=$(cat "$src/VERSION.txt")
	[ "$have" = "$BASE_VERSION" ] \
		|| echo "warning: the patch was made against $BASE_VERSION, this is $have" >&2
	# --check first: a failure must leave the tree untouched, not half applied.
	git -C "$src" apply --check "$here/patches/0001-tailscale-haiku.patch" \
		|| die "patches/0001-tailscale-haiku.patch does not apply to $ref"
	git -C "$src" apply "$here/patches/0001-tailscale-haiku.patch"
	note "applied patches/0001-tailscale-haiku.patch"
fi

# --- patched dependencies ----------------------------------------------------

# wireguard-go needs build tags and the Haiku TUN device, gvisor a small
# change. They are copied out of the module cache and pulled in with a
# replace directive: the cache itself stays pristine, and the go command
# cannot serve a stale index for a directory it assumes never changes.
patched_copy() {
	module=$1
	name=$2
	patchfile=$3
	if [ ! -f "$deps/$name/.patched" ]; then
		(cd "$src" && "$go" mod download "$module")
		dir=$(cd "$src" && "$go" list -m -f '{{.Dir}}' "$module")
		rm -rf "$deps/$name"
		mkdir -p "$deps"
		cp -R "$dir" "$deps/$name"
		chmod -R u+w "$deps/$name"
		patch -s -d "$deps/$name" -p1 < "$patchfile"
		: > "$deps/$name/.patched"
		note "patched $module"
	fi
	(cd "$src" && "$go" mod edit -replace "$module=$deps/$name")
}

patched_copy github.com/tailscale/wireguard-go wireguard-go "$here/deps/wireguard-go-haiku.patch"
patched_copy gvisor.dev/gvisor gvisor "$here/deps/gvisor-haiku-entropy.patch"

# --- build -------------------------------------------------------------------

# The minimal feature sets the 32-bit port ships, plus, for the daemon, what
# a TUN interface needs: osrouter (addresses and routes) and dns (MagicDNS
# through the system resolver). featuretags is a host program, so it runs for
# the build machine, not for Haiku.
daemon_tags=$(cd "$src" && "$go" run ./cmd/featuretags --min --add=netstack,outboundproxy,ipnbus,osrouter,dns)
cli_tags=$(cd "$src" && "$go" run ./cmd/featuretags --min --add=cli,ipnbus)

# Without these the binaries report "<version>-dev<date>-t<commit>-dirty".
commit=$(git -C "$src" rev-parse HEAD)
stamps="-X tailscale.com/version.longStamp=$BASE_VERSION-renkuos \
-X tailscale.com/version.shortStamp=$BASE_VERSION \
-X tailscale.com/version.gitCommitStamp=$commit"

note "building for haiku/$goarch with $("$go" version)"
(
	cd "$src"
	CGO_ENABLED=0 GOOS=haiku GOARCH=$goarch "$go" build -trimpath \
		-ldflags="-s -w $stamps" -tags="$daemon_tags" \
		-o "$out/tailscaled" ./cmd/tailscaled
	CGO_ENABLED=0 GOOS=haiku GOARCH=$goarch "$go" build -trimpath \
		-ldflags="-s -w $stamps" -tags="$cli_tags" \
		-o "$out/tailscale" ./cmd/tailscale
)
install -m 0755 "$here/packaging/tailscaled-service" "$out/tailscaled-service"

if command -v file >/dev/null 2>&1; then
	file "$out/tailscale" "$out/tailscaled"
fi
note "built $out/tailscale, $out/tailscaled"
