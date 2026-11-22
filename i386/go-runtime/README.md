# Go runtime patches for haiku/386

These patch the Go toolchain, not Tailscale. `../build.sh` (installed as
`haiku32/build.sh`) applies them in the order below to a checkout of
korli's Haiku Go tree; you only need to apply them by hand if you are working on
the runtime itself.

Apply order matters - later patches depend on earlier ones:

1. `go-haiku386.patch` - the base `haiku/386` port
2. `go-haiku386-netpoll.patch` - working netpoller
3. `go-haiku386-preempt.patch` - async preemption
4. `go-haiku386-sockets.patch` - sockets registered with the netpoller
5. `go-haiku386-semacreate.patch` - semaphore creation out of `lock2`
6. `go-haiku386-osyield.patch` - the startup hang
7. `go-haiku386-mmap.patch` - `mmap`'s 64-bit `off_t`

`go-haiku386-diag.patch.txt` is deliberately not applied. It is the
investigation harness: it makes `sysmon` print the scheduler's own view and
throw when no P has scheduled anything for `GOHAIKUSTALLPANIC` seconds. Apply it
by hand when chasing a hang, because on Haiku `strace` will not attach to a
running team, `SIGQUIT` to a wedged process prints nothing, and a watchdog
goroutine cannot run when nothing can be scheduled - `sysmon` can, because it
runs without a P.

`gvisor-haiku386.patch` and `wireguard-go-haiku.patch` patch those dependencies
and are applied to the module cache by the build script.

## The one worth reading

`go-haiku386-osyield.patch` is a one-line fix with a long tail:

```go
sysvicall1(&libc_snooze, 0)      // wrong: pushes one 32-bit word
sysvicall2(&libc_snooze, 0, 0)   // right: bigtime_t is two words
```

`snooze()` takes a 64-bit `bigtime_t` of microseconds. Passing one word left the
high half as whatever the stack held, so when it was non-zero this "yield" slept
for `(garbage << 32)` microseconds. `lock2` calls `osyield()` in its spin phase
while holding `m.locks` and a P, so the thread froze inside libc still holding
the P and the whole scheduler stopped, CPU idle.

General lesson for this port: **any libc function taking a 64-bit value needs
two argument words on 386.** `mmap`'s `off_t` had the same bug (patch 7). Audit
new `sysvicall` calls for it.

## Licensing

These patch files are MIT as authored works (see `../LICENSE`). The code they
modify is the Go standard library and runtime, BSD-3-Clause, Copyright (c) The
Go Authors; patched files remain under that license. gvisor is Apache-2.0 and
wireguard-go is BSD-3-Clause.
