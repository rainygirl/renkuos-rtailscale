#!/bin/sh
# install.sh - fetch Tailscale, apply the Haiku/386 port, build it, and install.
#
# Two modes, picked automatically from the host:
#
#   On Linux/macOS  cross-build. Clones tailscale, applies the port, builds the
#                   patched Go toolchain and the haiku/386 binaries, and writes
#                   an archive you copy to the Haiku machine. No system Go is
#                   needed: tailscale's own tool/go fetches a bootstrap
#                   toolchain.
#
#   On Haiku        install. Unpacks that archive and installs the daemon, the
#                   CLI and the launcher.
#
# Why the split: a 32-bit Haiku system cannot bootstrap a Go compiler from
# source, and Go is not installable from pkgman for x86_32, so there is nothing
# to bootstrap FROM. Building has to happen elsewhere. If you do have a working
# Go on the Haiku box, pass GO_BOOTSTRAP=/path/to/go and it will build in place.
#
# Typical use:
#
#   # on your laptop
#   ./install.sh --package ~/tailscale-haiku386.tar.gz
#   scp ~/tailscale-haiku386.tar.gz user@haiku-box:
#
#   # on the Haiku box
#   ./install.sh --prebuilt ~/tailscale-haiku386.tar.gz
#
# Options:
#   --package PATH   (build host) also write a .tar.gz of the built binaries
#   --prebuilt PATH  (Haiku) install from an archive instead of building
#   --prefix DIR     where to install binaries
#                    (default: ~/config/non-packaged/bin on Haiku, ./out elsewhere)
#   --workdir DIR    where to clone and build
#                    (default: ~/Workspace/haiku-tailscale)
#   --ref REF        tailscale git ref (default: v1.102.0)
#   --keep           reuse an existing checkout instead of re-cloning
set -eu

BASE_REF=v1.102.0
TAILSCALE_REPO=${TAILSCALE_REPO:-https://github.com/tailscale/tailscale.git}

workdir=$HOME/Workspace/haiku-tailscale
prebuilt=
package=
prefix=
ref=$BASE_REF
keep=0

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
host=$(uname -s)

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [ $# -gt 0 ]; do
	case $1 in
		--prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; prefix=$2; shift 2 ;;
		--workdir) [ $# -ge 2 ] || die "--workdir needs a directory"; workdir=$2; shift 2 ;;
		--prebuilt) [ $# -ge 2 ] || die "--prebuilt needs a file"; prebuilt=$2; shift 2 ;;
		--package) [ $# -ge 2 ] || die "--package needs a file"; package=$2; shift 2 ;;
		--ref) [ $# -ge 2 ] || die "--ref needs a git ref"; ref=$2; shift 2 ;;
		--keep) keep=1; shift ;;
		-h|--help) sed -n '2,42p' "$0"; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
done

if [ -z "$prefix" ]; then
	if [ "$host" = Haiku ]; then
		prefix=$HOME/config/non-packaged/bin
	else
		prefix=$(pwd)/out
	fi
fi

command -v git >/dev/null 2>&1 || die "git is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
[ -f "$here/apply.sh" ] || die "apply.sh not found next to install.sh"

# --- decide what we are doing ----------------------------------------------

if [ -n "$prebuilt" ]; then
	mode=install
	[ -f "$prebuilt" ] || die "no such archive: $prebuilt"
	prebuilt=$(CDPATH= cd -- "$(dirname -- "$prebuilt")" && pwd)/$(basename -- "$prebuilt")
elif [ "$host" != Haiku ] || [ -n "${GO_BOOTSTRAP:-}" ]; then
	mode=build
else
	cat >&2 <<EOF
error: cannot build on this machine.

A 32-bit Haiku system cannot bootstrap a Go compiler from source, and pkgman has
no Go for x86_32, so there is nothing to bootstrap from. Build on another
machine and bring the result over:

    # on a Linux or macOS machine, with this same script:
    ./install.sh --package tailscale-haiku386.tar.gz
    scp tailscale-haiku386.tar.gz user@$(hostname):

    # back here:
    ./install.sh --prebuilt tailscale-haiku386.tar.gz

If you do have a Go toolchain on this machine, point at it and it will build
here instead:

    GO_BOOTSTRAP=/path/to/go ./install.sh
EOF
	exit 1
fi

# --- fetch and patch (both modes need the launcher and build scripts) -------

mkdir -p "$(dirname -- "$workdir")"
if [ -d "$workdir/.git" ] && [ "$keep" = 1 ]; then
	note "reusing existing checkout in $workdir"
else
	if [ -e "$workdir" ]; then
		# Never delete something that is not ours to delete.
		[ -d "$workdir/.git" ] || die "$workdir exists and is not a git checkout; move it or use --workdir"
		note "removing previous checkout in $workdir"
		rm -rf "$workdir"
	fi
	note "cloning tailscale $ref into $workdir"
	git clone --depth 1 --branch "$ref" "$TAILSCALE_REPO" "$workdir"
fi

if [ -f "$workdir/haiku32/build.sh" ] && [ "$keep" = 1 ]; then
	note "port already applied, skipping"
else
	note "applying the Haiku/386 port"
	"$here/apply.sh" "$workdir"
fi

out=$workdir/dist/haiku32
mkdir -p "$out"

# --- build or unpack --------------------------------------------------------

if [ "$mode" = build ]; then
	if [ -n "${GO_BOOTSTRAP:-}" ]; then
		note "building with GO_BOOTSTRAP=$GO_BOOTSTRAP"
		export GO_BOOTSTRAP
	else
		# No system Go required: tailscale's tool/go downloads the bootstrap
		# toolchain itself, and haiku32/build.sh uses it on non-Haiku hosts.
		note "building (tool/go will fetch a bootstrap toolchain if needed)"
	fi
	note "this clones and compiles a patched Go; expect several minutes"
	( cd "$workdir" && HAIKU32_REBUILD=1 ./haiku32/build.sh )
else
	note "unpacking $prebuilt"
	tar -xzf "$prebuilt" -C "$out"
	[ -f "$out/tailscaled" ] || die "archive did not contain tailscaled"
	chmod 0755 "$out/tailscale" "$out/tailscaled"
	install -m 0755 "$workdir/haiku32/run-native.sh" "$out/tailscale-haiku"
fi

[ -x "$out/tailscaled" ] || die "no tailscaled in $out"

# --- package ----------------------------------------------------------------

if [ -n "$package" ]; then
	pkg_dir=$(CDPATH= cd -- "$(dirname -- "$package")" && pwd)
	package=$pkg_dir/$(basename -- "$package")
	tar -czf "$package" -C "$out" tailscale tailscaled
	note "wrote $package"
fi

# --- install ----------------------------------------------------------------

note "installing into $prefix"
mkdir -p "$prefix"
install -m 0755 "$out/tailscaled" "$prefix/tailscaled"
install -m 0755 "$out/tailscale" "$prefix/tailscale"
install -m 0755 "$out/tailscale-haiku" "$prefix/tailscale-haiku"

# The closing message depends on what was actually done, not on the host: an
# install is an install even when it is being staged from a build machine.
if [ "$mode" = build ] && [ "$host" != Haiku ]; then
	cat <<EOF

Built haiku/386 binaries in $prefix.

These do not run here - copy them to the Haiku machine:
EOF
	if [ -n "$package" ]; then
		cat <<EOF

  scp $package user@haiku-box:
  # then on the Haiku box:
  ./install.sh --prebuilt \$(basename $package)
EOF
	else
		cat <<EOF

  ./install.sh --package tailscale-haiku386.tar.gz     # to get an archive
EOF
	fi
	exit 0
fi

cat <<EOF

Installed:

  $prefix/tailscaled        the daemon
  $prefix/tailscale         the CLI
  $prefix/tailscale-haiku   launcher: starts the daemon and runs 'up'

Start it:

  $prefix/tailscale-haiku

That brings the daemon up, waits until the node actually reaches Running, and
prints the authentication URL on first use. Leave it running.

Then reach a tailnet host from another terminal. tailscaled runs in
userspace-networking mode, so ssh has to go through it:

  ssh -o ProxyCommand="env GOMAXPROCS=1 GODEBUG=asyncpreemptoff=1 \\
          $prefix/tailscale --socket=\$HOME/config/settings/tailscale/tailscaled.sock nc %h %p" \\
      -o ConnectTimeout=45 user@100.x.y.z

See SSH.md - it explains why each option is there, and has a retry wrapper.
EOF

case ":$PATH:" in
	*":$prefix:"*) ;;
	*) echo "note: $prefix is not in your PATH." >&2 ;;
esac
