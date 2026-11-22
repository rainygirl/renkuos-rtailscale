#!/bin/sh
# install.sh - install dist/<arch>/ without making a package.
#
# Runs on RenkuOS/Haiku and copies into ~/config/non-packaged, which needs no
# package activation and no restart:
#
#   bin/tailscale  bin/tailscaled  bin/tailscaled-service
#   apps/RTailscale                (with its signature and icon attached)
#
#   ./install.sh                   # this machine's architecture
#   ./install.sh arm64
#   ./install.sh --uninstall
#
# It does not add a launch job: start the service from R Tailscale, or run
# tailscaled-service yourself. The package (tools/make-hpkg.sh) is what
# starts it at login.
set -eu

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = Haiku ] || die "run this on RenkuOS/Haiku"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=$HOME/config/non-packaged

if [ "${1:-}" = --uninstall ]; then
	rm -f "$prefix/bin/tailscale" "$prefix/bin/tailscaled" \
		"$prefix/bin/tailscaled-service" "$prefix/apps/RTailscale"
	echo "removed. Settings and the node key stay in ~/config/settings/tailscale."
	exit 0
fi

if [ $# -ge 1 ]; then
	arch=$1
else
	case $(uname -m) in
		aarch64|arm64) arch=arm64 ;;
		x86_64) arch=x86_64 ;;
		*) die "unsupported machine $(uname -m): pass arm64 or x86_64" ;;
	esac
fi
dist=$here/dist/$arch
for f in tailscale tailscaled tailscaled-service RTailscale; do
	[ -f "$dist/$f" ] || die "missing $dist/$f (run build.sh and build gui/ first)"
done

mkdir -p "$prefix/bin" "$prefix/apps"
install -m 0755 "$dist/tailscale" "$dist/tailscaled" "$dist/tailscaled-service" "$prefix/bin/"

# Copy to a temporary name first: replacing a running application's file in
# place would corrupt the copy that is mapped into memory.
tmp=$prefix/apps/.RTailscale.new
cp "$dist/RTailscale" "$tmp"
chmod 0755 "$tmp"
rc -o "$prefix/apps/.RTailscale.rsrc" "$here/gui/RTailscale.rdef"
xres -o "$tmp" "$prefix/apps/.RTailscale.rsrc"
rm -f "$prefix/apps/.RTailscale.rsrc"
mv -f "$tmp" "$prefix/apps/RTailscale"
mimeset -f "$prefix/apps/RTailscale"

cat <<DONE
Installed into $prefix:

  bin/tailscale  bin/tailscaled  bin/tailscaled-service
  apps/RTailscale

Open R Tailscale and press "Start service", then "Sign in".
DONE
