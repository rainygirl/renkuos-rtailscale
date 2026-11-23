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
| x86 (32-bit) | [`i386/`](../i386/), a separate and much larger port | the port is unchanged; packaged with R Tailscale as `renkuos_rtailscale_x86` and run up to sign-in on Haiku x86_gcc2 |

## Layout

```
build.sh                 build tailscale + tailscaled for arm64 or x86_64
install.sh               install dist/<arch>/ into ~/config/non-packaged
patches/                 the 64-bit change to the tailscale source
patches/haiku/           a Haiku network stack fix for IPv6 on TUN (not shipped)
deps/                    changes to three dependencies (wireguard-go, gvisor, pkg/sftp)
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
over. The 64-bit patch adds about 1,500 lines in 39 files and only does
what Haiku itself requires:

| change | why |
| --- | --- |
| `wgengine/router/osrouter`: a router for Haiku | sets the tun interface's addresses (IPv4, and IPv6 where the stack allows it) and the tailnet routes with `ifconfig` and `route`; an exit node's default route goes in as eight routes from `1.0.0.0/8` to `128.0.0.0/1` |
| `net/dns`: write the system's `resolv.conf` | Haiku's resolver reads `/boot/system/settings/network/resolv.conf`, not `/etc/resolv.conf` |
| `cmd/tailscaled`: default to `userspace-networking` | the tunnel driver is not in every image; the service asks for `tun` first and falls back |
| `paths`: socket and state under `~/config/settings/tailscale` | Haiku has no `/var/run` or `/var/lib` convention |
| `paths`, `cmd/tailscale/cli`: stop calling `golang.org/x/sys/unix` | that module has no Haiku support |
| `ipn/ipnserver`: accept LocalAPI clients without peer credentials | Haiku does not expose them; the socket is mode 0600 in the owner's settings directory |
| `net/netmon`: read the interfaces and the default route with ioctls, and watch for changes | Go's `net.Interfaces()` returns nothing on Haiku, and with no interfaces netcheck skips every STUN probe, leaving the node relay-only. Changes come from the network stack's notifications (see [Network changes](#network-changes)) |
| `net/dns`: watch `resolv.conf` | net_server rewrites it on every DHCP lease; the daemon notices within two seconds and puts its resolver back |
| `ssh/tailssh`, `util/osuser`, `feature/ssh`: the Tailscale SSH server on Haiku | PTYs, terminal modes and window size through libroot's `ioctl`, users and shells from `/etc/passwd`, no `login` or `su` |
| `cmd/tailscaled`: subnets and exit node traffic in netstack | Haiku's IPv4 stack neither forwards packets nor translates addresses |
| `net/netns`, `wgengine/magicsock`: keep the daemon's own traffic out of the tunnel | needed while an exit node holds the default route; Haiku has no policy routing or socket marks |

`deps/` holds three more:

- **wireguard-go**: four build tags, so its stub implementations are used,
  and `tun/tun_haiku.go`, the TUN device. Haiku's tunnel driver has no clone
  device: configuring an interface named `tun/<n>` creates it and publishes
  `/dev/tun/<n>`, which carries bare IP packets, one per read or write.
- **gvisor**: 64 IP-identifier buckets instead of 2048. Each bucket is seeded
  from `crypto/rand`, and Haiku's `getentropy` can be very slow to produce
  8 KiB: on RenkuOS/arm64 this one initialization held startup for 36 to 45
  seconds. With the change the backend is ready in 2 seconds or less.
- **pkg/sftp**: two build tags, for the SFTP subsystem of Tailscale SSH.

Some of these need functions Go's `syscall` package for Haiku does not
offer (`ioctl`, ports, the generic syscall the network notifications use).
They are plain functions in `libroot.so`, which every Go binary on Haiku
links against, so they are called the way `golang.org/x/sys/unix` calls
libc on Solaris: a `//go:cgo_import_dynamic` declaration and
`syscall.sysvicall6`, without cgo. `net/netmon` and `ssh/tailssh` each
declare `__ioctl`; the linker merges the two into one import.

`patches/haiku/haiku-tun-ipv6.patch` is not part of the build: it is a
change to Haiku itself, see [IPv6](#ipv6).

## Install

Without a package, from a checkout that has `dist/<arch>/` built:

```sh
./install.sh                 # into ~/config/non-packaged; --uninstall removes it
```

Or with a package built by `tools/make-hpkg.sh`:

```sh
pkgman install ./renkuos_rtailscale-1.102.0-6-arm64.hpkg
```

The package installs `tailscale`, `tailscaled`, `tailscaled-service`,
R Tailscale (in the Applications menu), and a launch job that starts the
service at login. `install.sh` installs the same files without the launch
job.

Then open **R Tailscale** and press **Sign in**. It shows the sign-in link
and opens it in the browser; the link can be opened on any other device
instead.

## Using it

On arm64 and x86_64 `tailscaled` opens a TUN interface (`tun/0`, or the
first one that is free). The system then has a route to every device of the
tailnet and resolves MagicDNS names, so any program reaches the tailnet
directly, and other devices reach this machine's own services, sshd
included:

```sh
ping mac-mini
ssh user@mac-mini
```

Three things to know about this mode:

- **IPv4, and IPv6 only with a fixed network stack.** See [IPv6](#ipv6).
- **`resolv.conf` is replaced** while the service runs, with the original
  kept beside it as `resolv.pre-tailscale-backup.conf`; `tailscale set
  --accept-dns=false` leaves it alone. The daemon puts the file back when it
  stops on SIGTERM or SIGINT, and `tailscaled-service` runs `tailscaled
  --cleanup` after the daemon ends and before the next start, which covers
  a daemon killed with `kill -9`.
  net_server rewrites the file when it reconfigures an interface (a DHCP
  renewal, for one); the daemon watches the file and writes its own
  version back within about two seconds.
- **The interface is taken down, not removed,** when the service stops, and
  reused by the next start. Removing it right after closing the device can
  leave the name unusable for a while.

Where the image has no tunnel driver, and on 32-bit x86, the daemon runs in
userspace-networking mode instead: it does **not** route the operating
system's traffic, and names do not resolve through MagicDNS. `TS_TUN=
userspace-networking` in the environment of `tailscaled-service` forces
that mode. R Tailscale's bottom line says which mode is in effect.

In both modes the service opens two proxies, which in userspace mode are the
way applications reach the tailnet:

| | address |
| --- | --- |
| SOCKS5 | `127.0.0.1:1055` |
| HTTP proxy | `127.0.0.1:1056` |

In userspace mode ssh goes through the CLI:

```sh
ssh -o ProxyCommand='tailscale nc %h %p' user@100.x.y.z
```

R Tailscale's **SSH** button runs exactly that in a Terminal window for the
selected device.

### Network changes

The daemon reads the interfaces, their addresses and flags, and the default
route from the kernel with the ioctls Haiku's own `ifconfig` and `route`
use. It subscribes to the network stack's notifications (the port
interface that `start_watching_network()` wraps) for interfaces that come,
go or change and for links that go up or down, and checks the routing table
every five seconds as well, because route changes have no notification. An
interface whose device has lost its link counts as down. So pulling a cable
or losing Wi-Fi pauses the node ("all links down"), and when the link is
back it rebinds its sockets, finds its public address again and
reconnects, without a restart.

### IPv6

The router gives the tun interface the node's IPv6 address (`fd7a:...`)
and the IPv6 routes of the tailnet next to the IPv4 ones. The Haiku network
stack of released images refuses that address on a tunnel interface
(`ifconfig: Setting address failed: Invalid Argument`): it registers no IPv6
datalink protocol for tunnel devices. The daemon then logs that once and
goes on with IPv4 only, which works as before.

`patches/haiku/haiku-tun-ipv6.patch` is the fix, to Haiku's network stack
(`stack` and the `loopback_frame` datalink protocol), not to tailscale; with
it the interface takes the IPv6 address and the tailnet is reachable over
IPv6 too. It is not part of this package, since it means replacing kernel
add-ons; see the patch's description. An IPv6 default route (an exit node's
`::/0`) is never installed, so with an exit node IPv6 traffic to the
internet does not go through it.

### Tailscale SSH

The daemon can serve SSH to the tailnet itself, with the tailnet's identity
and access rules instead of keys and passwords:

```sh
tailscale up --ssh            # or: tailscale set --ssh
ssh user@this-machine         # from another device in the tailnet
```

The tailnet policy's `ssh` rules decide who may log in as which user, and
`check` rules ask for a fresh sign-in in the browser first, as everywhere.
The user names are this machine's: Haiku has one account (`user` on Haiku,
`baron` on RenkuOS), found in `/etc/passwd` with its home and shell. Allow
that name in the policy's `ssh` rule (`"users": ["baron"]`).

What differs from Linux:

- No `login`, `su` or PAM: the shell from `/etc/passwd` is started directly
  in the user's home, with `PATH` set the way Haiku's Terminal sets it.
- Every Haiku user has UID 0, so a session has full rights over the
  machine, as a local Terminal does.
- Interactive sessions get a pseudo-terminal with the client's terminal
  modes and window size. The SFTP subsystem is built in.

### Subnet router and exit node

The machine can offer routes to its LAN, or all of the internet, to the
tailnet, and can send its own internet traffic through another device:

```sh
tailscale set --advertise-routes=192.168.1.0/24   # then approve in the admin console
tailscale set --advertise-exit-node               # likewise
tailscale set --exit-node=<device>                # use another device; no approval needed
tailscale set --exit-node=                        # stop using it
```

**Offering routes or an exit node** works through netstack, as on FreeBSD
and Windows: packets from the tailnet to the advertised networks end in the
daemon's own TCP/IP stack, which opens ordinary sockets to the real
destination. Haiku's IPv4 stack neither forwards packets nor translates
addresses, so the kernel's route table is not used for this. TCP and UDP
are carried; ping is answered by running Haiku's `ping`.

**Using an exit node** changes the system's routes. The default route is
not replaced: eight routes from `1.0.0.0/8` to `128.0.0.0/1` through
`tun/0` cover the internet and win over it, and the physical default route
stays (`0.0.0.0/8` is left out, as `route` takes any route to `0.0.0.0` for
the default route). The LAN stays reachable, its on-link route being more
specific. So that the daemon's own traffic (control server, DERP, STUN, and
WireGuard to the exit node and the other peers) does not loop into the
tunnel, each remote address it talks to gets a host route through the
physical gateway before its first packet. Turning the exit node off, or
stopping the daemon with SIGTERM, removes all of these routes again.
While they exist they are also listed in `bypass-routes` in the state
directory, so that those of a daemon killed with `kill -9` are removed by
`tailscaled --cleanup` (which `tailscaled-service` runs after the daemon
ends) or by the next start.

Limits:

- IPv4 only: no IPv6 default route (see above).
- The host routes go through the gateway that was the default when the
  exit node was turned on. If the network's gateway changes while the exit
  node is in use, restart the service.

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

The packages, as published on pkgman.rainygirl.com:

- arm64 (RenkuOS) and x86_64 (Haiku nightly): `pkgman install
  renkuos_rtailscale` from the repository installs into `/system`, the
  service started from there rejoins the tailnet, and R Tailscale shows the
  connected state with its icon in the Deskbar
- 32-bit (Haiku x86_gcc2 nightly hrev60450 under QEMU): `pkgman install
  renkuos_rtailscale_x86`, then `tailscaled-service` runs the i386 launcher,
  the daemon becomes ready, and R Tailscale shows the sign-in link

TUN mode, signed in, with the `1.102.0-2` packages (installed from the file
first, then again with `pkgman install` from pkgman.rainygirl.com):

- arm64 (RenkuOS, hrev60072) and x86_64 (Haiku nightly hrev60450): the
  service opens `tun/0`; `ping` and `curl` reach a peer by its MagicDNS name
  with no proxy; another device pings the machine and reads the banner of
  its sshd; the internet is still reached
- arm64: five rounds of starting the service and killing the daemon with
  `kill -9`; each time `resolv.conf` and the routing table were back as
  before and the next start reused `tun/0`. With an unusable tun name the
  daemon fell back to userspace networking and the SOCKS5 proxy worked.
  R Tailscale shows the TUN line.
- x86_64: the daemon stops on SIGTERM and takes the interface down

Revision 3 is arm64 only: the same source built with a Go toolchain that no
longer prints `234567` at startup. On RenkuOS arm64 it was installed from the
file over revision 2 and then from pkgman.rainygirl.com; `tailscale version`
prints only the version, the service opens `tun/0`, a peer answers `ping` and
its sshd banner by MagicDNS name, and the Mac mini pings back.

Revision 5 on arm64 (RenkuOS live image, hrev60072, Go toolchain with the
signal fix) and revision 4 on x86_64 (Haiku nightly hrev60450), both under
QEMU, installed from the file with `pkgman install`, service started with
`tailscaled-service`, signed in, TUN mode:

- both: `tun/0` up with the node's IPv4 address; `ping mac-mini` and `curl`
  to an HTTP server on that peer by MagicDNS name; `kill -TERM` of
  `tailscaled` stops it, the service script ends, `tun/0` is down, the
  tailnet routes are gone and `resolv.conf` is the DHCP one again;
  started again, the node is back and the peer answers
- both: the IPv6 address is refused by the stock stack, logged once, and
  IPv4 works as before
- arm64: the virtual NIC's link switched off and on with QEMU's `set_link`:
  the daemon logs "all links down; pausing", and 20 s after the link is back
  "LinkChange: major, rebinding"; the peer is reached again directly
- arm64: `tailscale up --ssh` is accepted and the host keys are published.
  From a Mac in the tailnet (OpenSSH), after the policy's check was
  approved in the browser: a command runs as `baron` (UID 0, shell
  `/bin/bash`) and its exit status comes back; stdin piped into a remote
  command arrives; an interactive session gets `/dev/tt/p0` with the
  client's window size, follows a resize (SIGWINCH), Ctrl-C interrupts
  `cat`, and `exit 4` comes back as 4; `scp` (SFTP and the legacy `-O`
  protocol) and `sftp` copy a 300 KB file both ways with matching checksums
- arm64: `tailscale set --exit-node=tokyo`: the eight routes through
  `tun/0` and host routes for the daemon's peers, DERP and control servers
  through the physical gateway appear, the public address seen from the
  internet becomes the exit node's, the tailnet peer is still reached;
  `--exit-node=` removes the routes, and the routing table and
  `resolv.conf` are byte-for-byte as before. With the exit node on, a
  `kill -9` of the daemon: the service's cleanup takes `tun/0` and its
  routes away and restores `resolv.conf`; four host routes through the
  gateway stayed, as described under the limits. Started again, the exit
  node was in use again (the preference is kept)
- x86_64: after a restart of the machine with the package in `/system`,
  the launch job started the service (`launch_roster info` shows it
  running) and the node was back in the tailnet; it stayed up and reached
  the peer for the six minutes it was watched
- x86_64, open: once, about ten minutes after the package was reinstalled
  and the service started by hand from an ssh session, the daemon was found
  gone; its log was lost (the machine was powered off) and it was not seen
  again

Not verified:

- **in TUN mode**: a DHCP renewal while connected, a machine that sleeps
  and wakes, accepting subnet routes; network changes and exit nodes on
  x86_64
- **IPv6** over the tailnet: needs the Haiku stack fix, which is not part of
  these tests
- **advertising** subnet routes or an exit node with these packages (it
  needs admin approval)

- **on x86_64**: R Tailscale's SSH and Copy IP buttons, and inbound
  connections
- **on 32-bit**: anything past the sign-in link with this package (the
  i386 port itself was developed on a signed-in machine; see `i386/`)
- **the launch job of a package in `/system` on arm64**: seen working on
  x86_64 and for a package in `~/config/packages`
- serve/funnel, Taildrop and the other features the minimal build omits

## Known limits

- A `tailscale` command whose output is piped into a program that exits
  early (`tailscale netcheck | head`) has been seen to hang instead of
  dying from SIGPIPE. Redirect to a file, or let it finish.
- A daemon killed with `kill -9` cannot clean up itself; the
  `tailscaled --cleanup` that `tailscaled-service` runs afterwards restores
  `resolv.conf`, takes the interface down and removes an exit node's host
  routes. A daemon killed that way and started by hand, without the
  service, does the same when it next starts. `kill <team>` (SIGTERM)
  remains the clean way to stop it.
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
