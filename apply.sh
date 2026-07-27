#!/bin/sh
# apply.sh - apply the Haiku/386 port to a checkout of tailscale/tailscale.
#
# Usage:
#   git clone https://github.com/tailscale/tailscale
#   cd tailscale && git checkout v1.102.0        # see BASE_VERSION below
#   /path/to/haiku386-port/apply.sh .
#
# What it does:
#   1. sanity-checks that the target really is a tailscale checkout at the
#      version this patch was made against,
#   2. applies patches/0001-tailscale-haiku386.patch to the tailscale source,
#   3. copies the port's own files (build scripts, launcher, reproducer) into
#      haiku32/ inside the checkout.
#
# It does NOT patch the Go toolchain. That is a separate step, because the Go
# tree is a separate repository; see go-runtime/README.md, or just run
# haiku32/build.sh afterwards, which applies those patches itself.
set -eu

BASE_VERSION=1.102.0

usage() {
	echo "usage: $0 <path-to-tailscale-checkout>" >&2
	exit 2
}

[ $# -eq 1 ] || usage
target=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ -d "$target" ] || { echo "error: not a directory: $target" >&2; exit 1; }
target=$(CDPATH= cd -- "$target" && pwd)

# 1. Is this a tailscale checkout, and the right version?
if [ ! -f "$target/VERSION.txt" ] || [ ! -d "$target/cmd/tailscaled" ]; then
	echo "error: $target does not look like a tailscale checkout" >&2
	exit 1
fi
have=$(cat "$target/VERSION.txt")
if [ "$have" != "$BASE_VERSION" ]; then
	echo "warning: this port was made against tailscale $BASE_VERSION, but" >&2
	echo "         $target is $have. The patch may not apply cleanly." >&2
	if [ "${HAIKU386_FORCE:-}" != "1" ]; then
		echo "         Set HAIKU386_FORCE=1 to try anyway." >&2
		exit 1
	fi
fi

# 2. Patch the tailscale source.
patch_file=$here/patches/0001-tailscale-haiku386.patch
[ -f "$patch_file" ] || { echo "error: missing $patch_file" >&2; exit 1; }

if git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
	# --check first so a failure leaves the tree untouched rather than half
	# applied, which is a miserable state to debug.
	if ! git -C "$target" apply --check "$patch_file" 2>/dev/null; then
		echo "error: the patch does not apply cleanly to $target" >&2
		echo "       Run: git -C $target apply --check -v $patch_file" >&2
		exit 1
	fi
	git -C "$target" apply "$patch_file"
else
	# No git: fall back to patch(1). Still refuse to apply partially.
	(cd "$target" && patch --dry-run -p1 -s <"$patch_file") || {
		echo "error: the patch does not apply cleanly to $target" >&2
		exit 1
	}
	(cd "$target" && patch -p1 -s <"$patch_file")
fi
echo "applied: tailscale source patch"

# 3. Install the port's own files.
mkdir -p "$target/haiku32/testdata/stress"
cp "$here"/go-runtime/*.patch "$target/haiku32/"
cp "$here"/go-runtime/go-haiku386-diag.patch.txt "$target/haiku32/"
cp "$here"/build/build.sh "$here"/build/Makefile "$target/haiku32/"
cp "$here"/build/README-haiku32.md "$target/haiku32/README.md"
cp "$here"/scripts/run-native.sh "$target/haiku32/"
cp "$here"/testdata/lockstress.go "$target/haiku32/testdata/stress/"
chmod +x "$target/haiku32/build.sh" "$target/haiku32/run-native.sh"
echo "installed: haiku32/ (build scripts, launcher, Go patches, reproducer)"

cat <<EOF

Done. Next:

  cd $target
  ./haiku32/build.sh        # fetches and patches Go, then builds for haiku/386

haiku32/build.sh applies the Go runtime patches in haiku32/go-haiku386*.patch.
Read go-runtime/README.md for what each one fixes.
EOF
