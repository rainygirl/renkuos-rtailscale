#!/bin/sh
# Build native Haiku/x86 binaries with the experimental Go Haiku/386 port.
set -eu

OUTPUT=${1:-dist/haiku32}
GO_REPOSITORY=${HAIKU_GO_REPOSITORY:-https://github.com/korli/go.git}
GO_BRANCH=${HAIKU_GO_BRANCH:-golang-1.26-haiku}
GO_COMMIT=4af74db8618f13d5bc0f3447fa6a7adb906fa709

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
case $OUTPUT in
	/*) ;;
	*) OUTPUT=$repo_dir/$OUTPUT ;;
esac
cache_dir=${HAIKU32_CACHE:-$repo_dir/.cache/haiku32-native}
go_root=$cache_dir/go
go_cache=$cache_dir/gocache
go_path=$cache_dir/gopath
tmp_dir=$cache_dir/tmp
patch_stamp=$go_root/.tailscale-haiku386-patch
patch_sentinel=$go_root/src/runtime/syscall2_haiku.go
prebuilt_archive=$script_dir/prebuilt-haiku386.tar.gz
host_os=${HAIKU32_HOST_OS:-$(uname -s)}

mkdir -p "$cache_dir" "$go_cache" "$go_path" "$tmp_dir" "$OUTPUT"

install_launcher()
{
	install -m 0755 "$script_dir/run-native.sh" "$OUTPUT/tailscale-haiku"
	rm -f "$OUTPUT/tailscale-core.gz" "$OUTPUT/tailscale-state.img" \
		"$OUTPUT/vmlinuz" "$OUTPUT/kernel" "$OUTPUT/initrd"
}

verify_native_abi()
{
	for binary in "$OUTPUT/tailscale" "$OUTPUT/tailscaled"; do
		for forbidden in libbsd.so LIBBSD_ LIBROOT_ LIBNETWORK_; do
			if LC_ALL=C grep -aq "$forbidden" "$binary"; then
				echo "error: $binary contains forbidden Haiku ABI dependency $forbidden" >&2
				echo "rebuild with a fresh HAIKU32_CACHE" >&2
				exit 1
			fi
		done

		# A native Haiku network application necessarily uses the system's
		# libroot and libnetwork. Reject every other DT_NEEDED entry and all
		# versioned imports; these two unversioned base-system libraries are
		# the complete supported runtime dependency set.
		if command -v objdump >/dev/null 2>&1; then
			needed=$(objdump -p "$binary" |
				awk '$1 == "NEEDED" { print $2 }' |
				LC_ALL=C sort)
			expected=$(printf '%s\n' libnetwork.so libroot.so)
			if [ "$needed" != "$expected" ]; then
				echo "error: unexpected DT_NEEDED entries in $binary:" >&2
				printf '%s\n' "$needed" >&2
				exit 1
			fi
		fi
	done
}

# Prefer the checked-in native bundle on every host. This keeps the ordinary
# `make haiku32` path reproducible and offline; rebuilding the experimental Go
# port is an explicit developer operation.
if [ "${HAIKU32_REBUILD:-0}" != 1 ] && [ -f "$prebuilt_archive" ]; then
	# dist is gitignored and may still contain the old QEMU launcher from an
	# earlier checkout. Remove it before doing anything that can fail so it can
	# never be mistaken for the native launcher again.
	rm -f "$OUTPUT/tailscale-haiku"
	if [ ! -f "$prebuilt_archive" ]; then
		echo "error: missing $prebuilt_archive" >&2
		exit 1
	fi
	tar -xzf "$prebuilt_archive" -C "$OUTPUT"
	chmod 0755 "$OUTPUT/tailscale" "$OUTPUT/tailscaled"
	install_launcher
	verify_native_abi
	echo "Installed bundled native Haiku/x86 binaries in $OUTPUT"
	exit 0
fi

# A 32-bit Haiku system cannot bootstrap the first Go compiler from source.
if [ "$host_os" = Haiku ] && [ -z "${GO_BOOTSTRAP:-}" ]; then
	echo "error: rebuilding Go on Haiku/x86 requires GO_BOOTSTRAP" >&2
	echo "unset HAIKU32_REBUILD to install the bundled native binaries" >&2
	exit 1
fi

if [ ! -d "$go_root/.git" ]; then
	git clone --depth 1 --single-branch --branch "$GO_BRANCH" \
		"$GO_REPOSITORY" "$go_root"
	if ! git -C "$go_root" cat-file -e "$GO_COMMIT^{commit}" 2>/dev/null; then
		git -C "$go_root" fetch --depth 1 origin "$GO_COMMIT"
	fi
	git -C "$go_root" checkout --detach "$GO_COMMIT"
fi

actual_commit=$(git -C "$go_root" rev-parse HEAD)
if [ "$actual_commit" != "$GO_COMMIT" ]; then
	echo "error: $go_root is at $actual_commit, expected $GO_COMMIT" >&2
	echo "remove that cache directory or set HAIKU32_CACHE to a new directory" >&2
	exit 1
fi

patch_is_applied()
{
	grep -q 'libc_waitpid waitpid "libroot.so"' "$patch_sentinel" 2>/dev/null &&
		! grep -q '"libbsd.so"' "$patch_sentinel" 2>/dev/null
}

if patch_is_applied; then
	# Recover a missing stamp only after verifying the actual source.
	: > "$patch_stamp"
elif [ -f "$patch_stamp" ]; then
	echo "error: stale Haiku Go patch stamp in $go_root" >&2
	echo "the cached source still imports libbsd.so; use a fresh HAIKU32_CACHE" >&2
	exit 1
else
	git -C "$go_root" apply --unidiff-zero --check "$script_dir/go-haiku386.patch"
	git -C "$go_root" apply --unidiff-zero "$script_dir/go-haiku386.patch"
	patch_is_applied || {
		echo "error: Haiku Go patch did not remove the libbsd.so dependency" >&2
		exit 1
	}
	# Enable the working Haiku/386 netpoller: non-blocking sockets registered
	# with the poller, plus the netpoll_haiku.go fix that polls a snapshot of the
	# fd set with mtxset released (so netpollarm can't race the poller into
	# permanently stranding a socket) and implements the delay==0 non-blocking
	# poll. This delivers accept/connect/read/write readiness reliably (verified
	# on hardware), which is what removes the startup wedge, the DERP CPU spin,
	# and the LocalAPI/control/CLI stalls. See go-haiku386-netpoll.patch and the
	# "Haiku/386 Go netpoller" section of AGENTS.md.
	git -C "$go_root" apply --check "$script_dir/go-haiku386-netpoll.patch"
	git -C "$go_root" apply "$script_dir/go-haiku386-netpoll.patch"
	# Fix Go async preemption on Haiku/386. Haiku's signal wrapper passes the
	# register set (vregs == mcontext) INLINE on the stack, not a pointer to a
	# ucontext, so the stock sigtramp/regs() read the interrupted eip/esp as
	# garbage; isAsyncSafePoint then always failed and stop-the-world (e.g. GC
	# during startup) spun SIGURG forever, wedging the daemon. This patch passes
	# the inline vregs by address, casts it directly in regs(), and preserves the
	# wrapper's callee-saved DI/SI/BX so its post-handler copy-back keeps the
	# injected asyncPreempt. Verified on hardware: daemon startup went from ~50%
	# wedge to 8/8 with NO asyncpreemptoff needed. See go-haiku386-preempt.patch
	# and the startup-wedge section of AGENTS.md.
	git -C "$go_root" apply --check "$script_dir/go-haiku386-preempt.patch"
	git -C "$go_root" apply "$script_dir/go-haiku386-preempt.patch"
	# Actually put sockets on the netpoller. The base patch kept them blocking
	# and unpollable, and the netpoll patch never undid that, so the working
	# netpoller went unused for sockets - and, worse, SetReadDeadline could not
	# interrupt a read blocked in the kernel, making every socket deadline in the
	# tree a no-op. Measured end to end on hardware, alternating the two builds
	# run-for-run: ssh through the tailnet succeeded 3 of 5 with this patch and
	# 0 of 5 without. See go-haiku386-sockets.patch.
	git -C "$go_root" apply --check "$script_dir/go-haiku386-sockets.patch"
	git -C "$go_root" apply "$script_dir/go-haiku386-sockets.patch"
	# Create each m's parking semaphore at m-creation time instead of on the m's
	# first lock2, so that lock2 never calls libc malloc while holding m.locks
	# and a P. Hygiene for the startup hang rather than a proven cure; see
	# go-haiku386-semacreate.patch and AGENTS.md.
	git -C "$go_root" apply --check "$script_dir/go-haiku386-semacreate.patch"
	git -C "$go_root" apply "$script_dir/go-haiku386-semacreate.patch"
	# THE startup hang: osyield passed snooze()'s 64-bit argument as a single
	# 32-bit word, so the high half was stack garbage and the "yield" could sleep
	# effectively forever - inside lock2's spin phase, holding a P. Measured
	# 0 hangs in 20 with this patch against 12 in 20 without. See
	# go-haiku386-osyield.patch and AGENTS.md.
	git -C "$go_root" apply --check "$script_dir/go-haiku386-osyield.patch"
	git -C "$go_root" apply "$script_dir/go-haiku386-osyield.patch"
	# Same defect class as osyield, found by auditing for it: mmap's 64-bit
	# off_t needs seven argument words and only six were passed. Latent (the
	# runtime maps anonymously, where the offset is ignored) but fixed anyway,
	# which required widening the libc argument window to eight words. See
	# go-haiku386-mmap.patch.
	git -C "$go_root" apply --check "$script_dir/go-haiku386-mmap.patch"
	git -C "$go_root" apply "$script_dir/go-haiku386-mmap.patch"
	: > "$patch_stamp"
fi

if [ -n "${GO_BOOTSTRAP:-}" ]; then
	bootstrap_root=$GO_BOOTSTRAP
elif [ "$host_os" != Haiku ]; then
	bootstrap_root=$($repo_dir/tool/go env GOROOT)
else
	echo "error: set GO_BOOTSTRAP to rebuild Go from source on Haiku/x86" >&2
	exit 1
fi

if [ ! -x "$go_root/bin/go" ] || [ ! -f "$go_root/.tailscale-toolchain-built" ]; then
	(
		cd "$go_root/src"
		GOROOT_BOOTSTRAP=$bootstrap_root ./make.bash
	)
	: > "$go_root/.tailscale-toolchain-built"
fi

go=$go_root/bin/go
export GOPATH=$go_path
export GOCACHE=$go_cache
export GOTOOLCHAIN=local

(cd "$repo_dir" && "$go" mod download github.com/tailscale/wireguard-go)
wireguard_dir=$(cd "$repo_dir" && "$go" list -m -f '{{.Dir}}' github.com/tailscale/wireguard-go)
if ! grep -q 'tamago || haiku' "$wireguard_dir/rwcancel/rwcancel_stub.go"; then
	chmod -R u+w "$wireguard_dir"
	TMPDIR=$tmp_dir patch -d "$wireguard_dir" -p1 < "$script_dir/wireguard-go-haiku.patch"
	"$go" clean -cache
fi

(cd "$repo_dir" && "$go" mod download gvisor.dev/gvisor)
gvisor_dir=$(cd "$repo_dir" && "$go" list -m -f '{{.Dir}}' gvisor.dev/gvisor)
if ! grep -q 'Keep this small for the 32-bit Haiku port' "$gvisor_dir/pkg/tcpip/network/ipv4/ipv4.go"; then
	chmod -R u+w "$gvisor_dir"
	TMPDIR=$tmp_dir patch -d "$gvisor_dir" -p1 < "$script_dir/gvisor-haiku386.patch"
	"$go" clean -cache
fi
daemon_tags=$(cd "$repo_dir" && "$go" run ./cmd/featuretags --min --add=netstack,outboundproxy,ipnbus)
cli_tags=$(cd "$repo_dir" && "$go" run ./cmd/featuretags --min --add=cli,ipnbus)

(
	cd "$repo_dir"
	CGO_ENABLED=0 GOOS=haiku GOARCH=386 "$go" build \
		-trimpath -ldflags='-s -w' -tags="$daemon_tags" \
		-o "$OUTPUT/tailscaled" ./cmd/tailscaled
	CGO_ENABLED=0 GOOS=haiku GOARCH=386 "$go" build \
		-trimpath -ldflags='-s -w' -tags="$cli_tags" \
		-o "$OUTPUT/tailscale" ./cmd/tailscale
)

install_launcher
verify_native_abi

if command -v file >/dev/null 2>&1; then
	file "$OUTPUT/tailscale" "$OUTPUT/tailscaled"
	file "$OUTPUT/tailscaled" | grep -Eq 'ELF 32-bit.*(Intel 80386|i386).*interpreter /system/runtime_loader' || {
		echo "error: tailscaled is not a native Haiku/x86 executable" >&2
		exit 1
	}
fi

echo "Built native Haiku/x86 binaries in $OUTPUT"
