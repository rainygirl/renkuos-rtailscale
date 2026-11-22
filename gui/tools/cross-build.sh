#!/bin/sh
# Cross-compile R Tailscale for x86_64, x86 (32-bit) or arm64 on a workstation with Docker,
# producing dist/<arch>/RTailscale without resources. The signature and icon
# are attached when the package is made (../tools/make-hpkg.sh) or by
# "make" on RenkuOS itself.
#
#   tools/cross-build.sh x86_64    # haiku/cross-compiler:x86_64-r1beta4 image
#   tools/cross-build.sh x86       # haiku/cross-compiler:x86_gcc2h-r1beta4 image (32-bit)
#   tools/cross-build.sh arm64     # a container with a Haiku arm64 build tree
#
# arm64 needs a running container that has already built Haiku for arm64 (the
# cross toolchain, the haiku and haiku_devel package contents, gcc_syslibs):
#   ARM64_CONTAINER   default haiku-builder
#   ARM64_GENERATED   default /root/renku-arm64-work/generated.arm64
set -e

ARCH="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/dist/$ARCH"
mkdir -p "$OUT"

case "$ARCH" in
x86_64)
	( cd "$HERE" && tar cf - src tools/cross-compile.sh ) \
		| docker run --rm -i --platform linux/amd64 \
			haiku/cross-compiler:x86_64-r1beta4 \
			sh -c 'mkdir -p /work && cd /work && tar xf - && sh tools/cross-compile.sh x86_64 >&2 && tar cf - RTailscale' \
		| tar xf - -C "$OUT"
	;;
x86)
	( cd "$HERE" && tar cf - src tools/cross-compile.sh ) \
		| docker run --rm -i --platform linux/amd64 \
			haiku/cross-compiler:x86_gcc2h-r1beta4 \
			sh -c 'mkdir -p /work && cd /work && tar xf - && sh tools/cross-compile.sh x86 >&2 && tar cf - RTailscale' \
		| tar xf - -C "$OUT"
	;;
arm64)
	CONTAINER="${ARM64_CONTAINER:-haiku-builder}"
	GEN="${ARM64_GENERATED:-/root/renku-arm64-work/generated.arm64}"
	WORK="/tmp/rtailscale-cross-$$"
	( cd "$HERE" && tar cf - src tools/cross-compile.sh ) \
		| docker exec -i -e GEN="$GEN" "$CONTAINER" \
			sh -c "mkdir -p $WORK && cd $WORK && tar xf - && sh tools/cross-compile.sh arm64 >&2 && tar cf - RTailscale; rm -rf $WORK" \
		| tar xf - -C "$OUT"
	;;
*)
	echo "usage: $0 x86_64|x86|arm64" >&2
	exit 1
	;;
esac

file "$OUT/RTailscale"
