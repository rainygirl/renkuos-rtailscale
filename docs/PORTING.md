# Tailscale for RenkuOS

[English](PORTING.md) | [한국어](PORTING.ko.md)

An unofficial port of Tailscale to RenkuOS (Haiku): the `tailscaled` daemon,
the `tailscale` CLI, and **R Tailscale**, a native window for them. Not
affiliated with Tailscale Inc.

Nothing here is a fork. It is patches you apply to an unmodified
`tailscale/tailscale` checkout, plus the build scripts, so you can see exactly
what was changed and why.

| architecture | what it is | state |
| --- | --- | --- |
| arm64 | `patches/` + `build.sh`, Go from [renkuos-golang](https://github.com/rainygirl/renkuos-golang) | built and run on RenkuOS arm64 (see [Verified](#verified)) |
| x86_64 | the same `patches/` + `build.sh`, Go from [korli/go](https://github.com/korli/go) | built with `build.sh x86_64` and run on Haiku x86_64, signed in to a tailnet (see [Verified](#verified)); not run on RenkuOS x86_64 |
| x86 (32-bit) | [`i386/`](../i386/), a separate and much larger port | as published in renkuos-i386-tailscale-patch, unchanged |

## Layout

```
build.sh                 build tailscale + tailscaled for arm64 or x86_64
install.sh               install dist/<arch>/ into ~/config/non-packaged
patches/                 the 64-bit change to the tailscale source
deps/                    changes to two dependencies (wireguard-go, gvisor)
packaging/               tailscaled-service (how the daemon is run), launch job
tools/make-hpkg.sh       make the installable package, on RenkuOS
gui/                     R Tailscale, the native window
i386/                    the 32-bit x86 port, with its own README and scripts
```

## Why 32-bit is separate

The 32-bit port had to work around a Go runtime that could not be trusted:
no usable network poller, broken async preemption, a scheduler that hung at
startup. Its tailscale patch is about 2,700 lines, most of it avoiding those
faults, and its launcher restarts the daemon until a start succeeds.

The 64-bit Go ports do not have those faults, so none of that is carried
over. The 64-bit patch is 125 lines in 12 files and only does what Haiku
itself requires:

| change | why |
| --- | --- |
| `net/tstun`: use the stub device | there is no TUN device to open |
| `cmd/tailscaled`: default to `userspace-networking` | follows from the above |
| `paths`: socket and state under `~/config/settings/tailscale` | Haiku has no `/var/run` or `/var/lib` convention |
| `paths`, `cmd/tailscale/cli`: stop calling `golang.org/x/sys/unix` | that module has no Haiku support |
| `ipn/ipnserver`: accept LocalAPI clients without peer credentials | Haiku does not expose them; the socket is mode 0600 in the owner's settings directory |
| `net/netmon`: find the local address by a route lookup | Go's `net.Interfaces()` returns nothing on Haiku, and with no interfaces netcheck skips every STUN probe, leaving the node relay-only |

`deps/` holds two more:

- **wireguard-go**: four build tags, so its stub implementations are used.
- **gvisor**: 64 IP-identifier buckets instead of 2048. Each bucket is seeded
  from `crypto/rand`, and Haiku's `getentropy` can be very slow to produce
  8 KiB: on RenkuOS/arm64 this one initialization held startup for 36 to 45
  seconds. With the change the backend is ready in 2 seconds or less.

## Install

Without a package, from a checkout that has `dist/<arch>/` built:

```sh
./install.sh                 # into ~/config/non-packaged; --uninstall removes it
```

Or with a package built by `tools/make-hpkg.sh`:

```sh
pkgman install ./renkuos_rtailscale-1.102.0-1-arm64.hpkg
```

The package installs `tailscale`, `tailscaled`, `tailscaled-service`,
R Tailscale (in the Applications menu), and a launch job that starts the
service at login. `install.sh` installs the same files without the launch
job.

Then open **R Tailscale** and press **Sign in**. It shows the sign-in link
and opens it in the browser; the link can be opened on any other device
instead.

## Using it

`tailscaled` runs in userspace-networking mode. It does **not** route the
operating system's traffic: there is no `100.x.y.z` route, and names do not
resolve through MagicDNS. Applications reach the tailnet through the two
proxies the service opens:

| | address |
| --- | --- |
| SOCKS5 | `127.0.0.1:1055` |
| HTTP proxy | `127.0.0.1:1056` |

ssh goes through the CLI instead:

```sh
ssh -o ProxyCommand='tailscale nc %h %p' user@100.x.y.z
```

R Tailscale's **SSH** button runs exactly that in a Terminal window for the
selected device.

The CLI needs no `--socket` option; the port's default path is the one the
service uses:

```sh
tailscale status
tailscale netcheck
```

### R Tailscale

![R Tailscale connected, on RenkuOS arm64](rtailscale.png)

- connection state, this device's name and address, the tailnet's name
- sign in, sign out, connect, disconnect
- the devices in the tailnet: online or not, address, operating system, and
  whether the path to it is direct or through a relay
- copy a device's address (double-click the row), or open ssh to it
- starts the service if it is not running

It speaks to the daemon's LocalAPI over its Unix socket directly, so it shows
what `tailscale status` shows without running the CLI. English and Korean.

## Build

The Go binaries, on any machine with a Haiku-capable Go for the target (see
the header of `build.sh` for where to get one):

```sh
GO=/path/to/go ./build.sh arm64      # -> dist/arm64/
```

On RenkuOS arm64 itself, `pkgman install golang_bin` provides that Go and
`./build.sh arm64` builds natively.

R Tailscale:

```sh
cd gui && make                        # on RenkuOS
gui/tools/cross-build.sh arm64        # or cross-compile with Docker
cp gui/dist/arm64/RTailscale dist/arm64/
```

The package, on RenkuOS:

```sh
tools/make-hpkg.sh
```

## Verified

On RenkuOS arm64 (QEMU, hrev60072), with Go 1.27.4 and tailscale v1.102.0:

- `tailscaled` starts and the backend is ready in 2 s or less
- `tailscale netcheck`: UDP works, the public IPv4 address is found, DERP
  latencies are measured
- the control plane is reached and returns a sign-in link
- R Tailscale shows the service-stopped and sign-in states and the link,
  and its button starts the service
- `build.sh arm64` from a clean checkout; R Tailscale cross-compiled for
  arm64 and x86_64
- `install.sh`, and `tools/make-hpkg.sh` producing a package with the
  expected contents
- signed in to a real tailnet: `tailscale status` lists the peers,
  `tailscale ping` reaches one peer directly (13 ms on the LAN) and another
  first over DERP and then directly
- `tailscale nc`, the SOCKS5 proxy and the HTTP proxy (CONNECT) each reach a
  peer's sshd by its MagicDNS name and read its banner; the SOCKS5 proxy
  also reaches the internet
- `ssh` with `tailscale nc` as its ProxyCommand, the command the SSH button
  runs, gets as far as the peer's authentication
- R Tailscale shows the connected state, this device's name and address,
  and the peer list with direct/relay/offline
- R Tailscale's buttons, clicked: **Copy IP** puts the selected device's
  address on the clipboard, **SSH** opens a Terminal that reaches the peer's
  host key prompt
- inbound: another device in the tailnet opens an ssh session to this
  machine's sshd through its tailnet address
- the package: copied into `~/config/packages` it is activated at once, the
  binaries appear in `~/config/bin` and R Tailscale in the Applications
  menu
- the launch job: after a restart the service is running as the job
  (`launch_roster info` shows it) and the node is back in the tailnet with
  no one starting it. The job is in `data/launch`; `data/user_launch` is
  only read from `/system`, so a package in `~/config/packages` shipping
  it there is ignored

On Haiku x86_64 (nightly hrev60450 under QEMU, not RenkuOS), with binaries
from `build.sh x86_64` and korli/go (golang-1.27-haiku, Go 1.27.4):

- `install.sh`; `tailscaled` starts, the backend is ready in under 1 s
- `tailscale netcheck`: UDP works, public IPv4 found, DERP latencies
- the control plane returns a sign-in link, and R Tailscale shows it
- signed in to a real tailnet: `tailscale status` lists the peers,
  `tailscale ping` reaches one peer directly (10 ms) and another over DERP
- `tailscale nc`, the SOCKS5 proxy and the HTTP proxy (CONNECT) each reach a
  peer's sshd by its MagicDNS name and read its banner; the SOCKS5 proxy
  also reaches the internet
- `ssh` with `tailscale nc` as its ProxyCommand gets as far as the peer's
  authentication
- R Tailscale shows the connected state and the peer list with
  direct/relay/offline

Not verified:

- **on x86_64**: R Tailscale's SSH and Copy IP buttons, inbound
  connections, and the package
- Tailscale SSH server, serve/funnel, exit nodes, and subnet routes: the
  minimal build omits them

## Known limits

- The interface monitor reports one synthetic interface per address family
  with a host-length prefix. It notices the network coming and going, but
  knows nothing about interface names or the LAN's prefix.
- A `tailscale` command whose output is piped into a program that exits
  early (`tailscale netcheck | head`) has been seen to hang instead of
  dying from SIGPIPE. Redirect to a file, or let it finish.
- **The daemon does not stop on SIGTERM or SIGINT.** This is the Go runtime,
  not tailscale: a minimal Go program built with the same haiku/arm64
  toolchain ignores both signals too, with or without `signal.Notify`. Stop
  the service with `kill -9 <team>`; the state file is written as it
  changes, and the next start replaces the stale socket.
- R Tailscale opens the sign-in link in the default browser. On the arm64
  test image WebPositive crashed while starting (inside WebKit's time zone
  setup, before loading anything). The link stays in the window with a
  **Copy link** button, and works from any other device.
- No Deskbar tray item yet; R Tailscale is a window.

## Licensing

The port's own material here - scripts, R Tailscale, docs, and the patch
files as authored works - is MIT; see `LICENSE`.

Patched code keeps its upstream license. Tailscale's source, including files
added by the patches, remains BSD-3-Clause, Copyright (c) Tailscale Inc &
contributors. gvisor and wireguard-go keep their own licenses. Tailscale is
a trademark of Tailscale Inc.

## AI disclosure

Parts of R Tailscale were developed with the assistance of AI coding tools
(Anthropic's Claude). All code has been reviewed and tested by the author.
