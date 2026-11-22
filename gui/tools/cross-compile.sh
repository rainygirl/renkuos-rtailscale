#!/bin/sh
# Runs inside the cross-compile container (see tools/cross-build.sh), in a
# directory holding src/. Leaves ./RTailscale.
set -e

CXXFLAGS="-O2 -std=c++17 -Wall -Wno-multichar -Wno-unused-parameter"

case "$1" in
x86_64)
	CXX="x86_64-unknown-haiku-g++"
	LINKFLAGS=""
	;;
x86)
	# The secondary (modern gcc) toolchain of the x86_gcc2 hybrid image.
	CXX="/tools/cross-tools-x86/bin/i586-pc-haiku-g++"
	LINKFLAGS=""
	;;
arm64)
	# The Haiku arm64 build tree has no populated sysroot: point one at the
	# haiku_devel package contents, and link against the haiku package's
	# libraries and gcc_syslibs' libstdc++.
	CXX="$GEN/cross-tools-arm64/bin/aarch64-unknown-haiku-g++"
	P="$GEN/objects/haiku/arm64/packaging/packages_build/minimum"
	SYSLIBS="$(ls -d "$GEN"/build_packages/gcc_syslibs-*-arm64/lib | head -1)"
	mkdir -p sysroot/boot/system lib
	ln -sfn "$P/hpkg_-haiku_devel.hpkg/contents/develop" sysroot/boot/system/develop
	ln -sfn "$SYSLIBS/libstdc++.so.6" lib/libstdc++.so
	ln -sfn "$SYSLIBS/libgcc_s.so.1" lib/libgcc_s.so
	CXX="$CXX --sysroot=$PWD/sysroot"
	LINKFLAGS="-L$P/hpkg_-haiku.hpkg/contents/lib -L$PWD/lib"
	;;
*)
	echo "usage: $0 x86_64|x86|arm64" >&2
	exit 1
	;;
esac

for source in src/*.cpp; do
	$CXX $CXXFLAGS -c "$source" -o "$source.o"
done
$CXX -o RTailscale src/*.o $LINKFLAGS -lbe -lnetwork -Xlinker -soname=_APP_
