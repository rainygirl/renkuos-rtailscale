# Tailscale on HaikuOS (32-bit x86)

A patch set that builds and runs Tailscale natively on HaikuOS/x86 (`haiku/386`),
including the Go runtime fixes the port needs.

Nothing here is a fork. It is a patch you apply to an unmodified
`tailscale/tailscale` checkout, plus the build scripts and the Go toolchain
patches, so you can see exactly what was changed and why.

Korean version of this document: [README.ko.md](README.ko.md).

## Layout

```
install.sh               cross-build on Linux/macOS, install on HaikuOS
apply.sh                 apply the port to a tailscale checkout
patches/                 changes to the tailscale source
go-runtime/              changes to the Go toolchain (and gvisor, wireguard-go)
build/                   build.sh, Makefile - build for haiku/386
scripts/                 run-native.sh (the launcher)
testdata/                lockstress.go - reproducer for the scheduler hang
SSH.md                   reaching a tailnet host from HaikuOS
SSH.ko.md                the same, in Korean
```

## Where you have to build

**You cannot build this on the HaikuOS machine.** Build on Linux or macOS and copy
the binaries over. That is not a preference, it is a bootstrap problem:

- The Go compiler is written in Go, so building it needs a working Go first.
- There is no Go for 32-bit HaikuOS to start from - `pkgman` has no `go` package
  for x86_32.
- The usual escape hatch, cross-building a target-native toolchain with Go's
  `src/bootstrap.bash`, does not work here either. It fails while compiling
  `cmd/vendor/golang.org/x/sys/unix`, which has no HaikuOS support:

  ```
  x/sys/unix/fdset.go:15:12: undefined: FdSet
  x/sys/unix/ioctl_unsigned.go:34:47: undefined: Winsize
  ```

  Porting `x/sys/unix` to HaikuOS would fix that and make on-device builds
  possible. It is a separate piece of work and is not part of this port.

If you do somehow have a working Go on the HaikuOS box, `install.sh` will use it:
pass `GO_BOOTSTRAP=/path/to/go` and it builds in place.

The build host does **not** need Go installed. Tailscale's own `tool/go`
downloads a bootstrap toolchain automatically.

## Install

On a Linux or macOS machine:

```sh
./install.sh --package tailscale-haiku386.tar.gz
scp tailscale-haiku386.tar.gz user@haiku-box:
```

That clones tailscale at the pinned version, applies the port, builds the
patched Go toolchain and the `haiku/386` binaries, and writes the archive.
Expect several minutes; it compiles a Go toolchain.

Then on the HaikuOS machine:

```sh
./install.sh --prebuilt tailscale-haiku386.tar.gz
```

which installs into `~/config/non-packaged/bin`:

| binary | what it is |
| --- | --- |
| `tailscaled` | the daemon |
| `tailscale` | the CLI |
| `tailscale-haiku` | launcher: starts the daemon, runs `up`, waits for Running |

Start it with `tailscale-haiku` and leave it running; it prints the
authentication URL on first use.

### Applying the patch by hand

If you would rather drive the build yourself:

```sh
git clone https://github.com/tailscale/tailscale
cd tailscale && git checkout v1.102.0
/path/to/haiku386-port/apply.sh .
./haiku32/build.sh
```

`apply.sh` refuses to run against a different tailscale version rather than
leaving you with a half-applied tree; override with `HAIKU386_FORCE=1`.

## Reaching other machines

`tailscaled` runs in userspace-networking mode: there is no TUN device, so it
does not route the operating system's traffic. Use `tailscale nc` as an ssh
`ProxyCommand`. [SSH.md](SSH.md) covers that - the options that are not
optional, why names do not resolve, and a retry wrapper you can copy.

## What the Go runtime patches fix

The base port is korli's `haiku/386` work. On top of it:

| patch | what it fixes |
| --- | --- |
| `go-haiku386.patch` | the base port (fetched separately by `build.sh`) |
| `go-haiku386-netpoll.patch` | a working `poll(2)` netpoller: readiness for accept/connect/read/write, and no lock held across `poll()` |
| `go-haiku386-preempt.patch` | async preemption. HaikuOS's signal wrapper passes the register set inline on the stack, not a `ucontext` pointer, so the stock `sigtramp` read garbage |
| `go-haiku386-sockets.patch` | put sockets on the netpoller at all. Without this every socket deadline in the tree was silently inert |
| `go-haiku386-osyield.patch` | **the startup hang.** `osyield()` passed `snooze()`'s 64-bit `bigtime_t` as one 32-bit word, so the high half was stack garbage and the "yield" could sleep effectively forever - inside `lock2`'s spin phase, holding a P |
| `go-haiku386-mmap.patch` | same defect class in `mmap`'s `off_t`; latent, since the runtime only maps anonymously |
| `go-haiku386-semacreate.patch` | create each m's semaphore at m-creation instead of inside the first `lock2`, so no libc allocation happens in a runtime critical section |
| `go-haiku386-diag.patch.txt` | opt-in diagnostics, not applied by `build.sh` - makes `sysmon` dump the scheduler's state when nothing has been scheduled for N seconds |

The `osyield` one is the interesting bug. Symptom: the process froze before
`main()` with the CPU at 0%, runnable goroutines queued, and idle threads
sitting unused. It looked random because it depended on stack garbage, and it
was rare at `GOMAXPROCS=1` because `lock2` seldom reaches its spin phase without
contention - which is why pinning to one P appeared to help and hid the real
cause for a long time.

Measured with `testdata/lockstress.go`, alternating builds run-for-run:
0 hangs in 20 with the fix, 12 in 20 without.

General lesson for this port: **any libc function taking a 64-bit value needs
two argument words on 386.** Audit new `sysvicall` calls for it.

## What the tailscale patch does

HaikuOS support across the daemon and CLI: platform files (`paths`, `safesocket`,
`util/prompt`, `net/tstun`), HaikuOS-specific handling in the LocalAPI server and
client, DERP and control-plane timeouts, and a userspace-networking setup that
works without a TUN device. `haiku32/README.md` (installed by `apply.sh`) has
the details.

Known rough edges:

- Everything is pinned to `GOMAXPROCS=1` and `GODEBUG=asyncpreemptoff=1` by the
  launcher. That predates the `osyield` fix and has not been re-evaluated since.
- A failed ssh attempt can leave a `tailscale nc` process behind, and each one
  burns about a fifth of a core. Reap them; see SSH.md.
- No inbound support: Tailscale SSH and serving are untested here.

## Licensing

The port's own material here - scripts, reproducer, docs, and the patch files as
authored works - is MIT; see `LICENSE`.

Patched code keeps its upstream license. Tailscale's source, including files
added by the tailscale patch, remains BSD-3-Clause, Copyright (c) Tailscale Inc
& contributors. The Go runtime patches modify Go, which is BSD-3-Clause,
Copyright (c) The Go Authors. gvisor and wireguard-go keep their own licenses.
