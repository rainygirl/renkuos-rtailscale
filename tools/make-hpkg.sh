#!/bin/sh
# make-hpkg.sh - turn dist/<arch>/ into an installable package.
#
# Runs on RenkuOS/Haiku: the application's signature and icon are file
# attributes, and only Haiku's own rc, xres and mimeset can attach them.
#
#   tools/make-hpkg.sh              # this machine's architecture
#   tools/make-hpkg.sh arm64        # arm64 | x86_64 | x86_gcc2
#
# The package only holds files, so any Haiku machine can make the package of
# any architecture.
#
# Expects, in dist/<arch>/:
#   tailscale tailscaled tailscaled-service    from ./build.sh <arch>
#   RTailscale                                 from gui/ (make, or tools/cross-build.sh)
# and for x86_gcc2 (32-bit), in dist/x86_gcc2/:
#   tailscale tailscaled tailscale-haiku       from i386/install.sh
#   RTailscale                                 from gui/tools/cross-build.sh x86
#
# Writes dist/renkuos_rtailscale-<version>-<revision>-<arch>.hpkg; the 32-bit
# package is renkuos_rtailscale_x86, as R Tailscale there is built with the
# secondary (x86) toolchain of the hybrid.
#
#   REVISION   package revision (default 1)
#   PACKAGER   packager field (default "rainygirl")
#   VENDOR     vendor field; it has to be the vendor of the repository the
#              package goes into (default "RENKU" for arm64, else "rainygirl")
set -eu

VERSION=1.102.0
REVISION=${REVISION:-1}

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = Haiku ] || die "run this on RenkuOS/Haiku (it needs rc, xres, mimeset and package)"
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ $# -ge 1 ]; then
	arch=$1
else
	case $(uname -m) in
		aarch64|arm64) arch=arm64 ;;
		x86_64) arch=x86_64 ;;
		*) die "unsupported machine $(uname -m): pass arm64, x86_64 or x86_gcc2" ;;
	esac
fi
dist=$here/dist/$arch
name=renkuos_rtailscale
requires=haiku
extra_provides=
case $arch in
	arm64) vendor=${VENDOR:-RENKU}; files="tailscale tailscaled tailscaled-service RTailscale" ;;
	x86_64) vendor=${VENDOR:-rainygirl}; files="tailscale tailscaled tailscaled-service RTailscale" ;;
	x86_gcc2)
		vendor=${VENDOR:-rainygirl}
		name=renkuos_rtailscale_x86
		requires="haiku
	haiku_x86"
		extra_provides="	cmd:tailscale_haiku = $VERSION"
		files="tailscale tailscaled tailscale-haiku RTailscale"
		;;
	*) die "unknown architecture $arch: arm64, x86_64 or x86_gcc2" ;;
esac
for f in $files; do
	[ -f "$dist/$f" ] || die "missing $dist/$f (see the header of this script)"
done

stage=$here/dist/.stage-$arch
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/apps" "$stage/data/launch" \
	"$stage/data/deskbar/menu/Applications" \
	"$stage/documentation/packages/$name"

if [ "$arch" = x86_gcc2 ]; then
	install -m 0755 "$dist/tailscale" "$dist/tailscaled" "$dist/tailscale-haiku" "$stage/bin/"
	install -m 0755 "$here/packaging/tailscaled-service-x86" "$stage/bin/tailscaled-service"
else
	install -m 0755 "$dist/tailscale" "$dist/tailscaled" "$dist/tailscaled-service" "$stage/bin/"
fi

# The cross-built application has no resources yet.
cp "$dist/RTailscale" "$stage/apps/RTailscale"
chmod 0755 "$stage/apps/RTailscale"
rc -o "$stage/RTailscale.rsrc" "$here/gui/RTailscale.rdef"
xres -o "$stage/apps/RTailscale" "$stage/RTailscale.rsrc"
rm -f "$stage/RTailscale.rsrc"
mimeset -f "$stage/apps/RTailscale"

ln -s ../../../../apps/RTailscale "$stage/data/deskbar/menu/Applications/R Tailscale"
cp "$here/packaging/tailscale.launch" "$stage/data/launch/tailscale"
cp "$here"/README*.md "$here/LICENSE" "$stage/documentation/packages/$name/"

cat > "$stage/.PackageInfo" <<INFO
name		$name
version		$VERSION-$REVISION
architecture	$arch
summary		"Tailscale for RenkuOS: the daemon, the CLI and the R Tailscale window"
description	"An unofficial port of Tailscale $VERSION to RenkuOS/Haiku. tailscaled runs in userspace-networking mode and offers the tailnet to applications through a SOCKS5 proxy (127.0.0.1:1055) and an HTTP proxy (127.0.0.1:1056); the tailscale command is the usual CLI; R Tailscale is a native window that shows the connection state and the devices in the tailnet, signs in and out, and opens ssh to a device. Not affiliated with Tailscale Inc."
packager	"${PACKAGER:-rainygirl}"
vendor		"$vendor"
copyrights {
	"2026 rainygirl"
	"Tailscale Inc & contributors"
}
licenses {
	"MIT"
	"BSD (3-clause)"
}
urls {
	"https://github.com/rainygirl/renkuos-rtailscale"
}
provides {
	$name = $VERSION
	cmd:tailscale = $VERSION
	cmd:tailscaled = $VERSION
	cmd:tailscaled_service = $VERSION
	app:RTailscale = $VERSION
$extra_provides
}
requires {
	$requires
}
INFO

out=$here/dist/$name-$VERSION-$REVISION-$arch.hpkg
rm -f "$out"
(cd "$stage" && package create -q "$out")
rm -rf "$stage"
package list "$out" | head -40
echo "==> $out"
