# SSH to a tailnet host from HaikuOS

On HaikuOS, `tailscaled` runs in **userspace networking** mode. There is no TUN
device, so it does not route the operating system's traffic: a plain
`ssh myserver` from HaikuOS goes out over your normal network and never touches
the tailnet. Only programs that go *through* tailscaled reach tailnet addresses.

The way through is `tailscale nc` as ssh's `ProxyCommand`. ssh talks to its
stdin/stdout, `tailscale nc` dials the destination with the daemon's own dialer,
and the connection travels the tailnet - including over DERP, which is the only
data path this port uses.

```
ssh -- stdin/stdout -- tailscale nc -- tailscaled -- DERP -- peer -- target host
```

Korean version of this document: [SSH.ko.md](SSH.ko.md).

## Before you start

The node has to be **Running**, not merely started. A node stuck at `Starting`
fails every `tailscale nc`. `tailscale-haiku` waits for Running before it
reports success; if you started `tailscaled` by hand, check:

```sh
tailscale --socket=$HOME/config/settings/tailscale/tailscaled.sock status
```

## The command

```sh
SOCK=$HOME/config/settings/tailscale/tailscaled.sock

ssh -o ProxyCommand="env GOMAXPROCS=1 GODEBUG=asyncpreemptoff=1 \
        tailscale --socket=$SOCK nc %h %p" \
    -o ConnectTimeout=45 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    -i ~/my-key.pem \
    user@100.x.y.z
```

Four details in there are not cosmetic:

- **`GOMAXPROCS=1`** for the CLI. It has to be in the environment, because the Go
  runtime reads it before `main` runs. With the default, this short-lived process
  wedges on startup often enough to matter.
- **`GODEBUG=asyncpreemptoff=1`**, for the same reason.
- **`ConnectTimeout=45`.** After the WireGuard session with the peer expires, the
  first connection has to redo the handshake over DERP, which takes 10-15s on
  this hardware. A 20s budget loses that race every time, so the first attempt
  after an idle period fails and the second succeeds - which looks like
  flakiness but is not.
- **`ServerAliveCountMax=3`** (with a 10s interval). A session that goes silent
  mid-stream is not going to recover; failing in 30s lets you retry instead of
  waiting a minute.

## Use addresses, not names

MagicDNS is not wired into HaikuOS's resolver, and `tailscale nc` resolves through
the daemon, which does not know your workstation's `/etc/hosts` aliases. Use the
tailnet IP (`100.x.y.z`), or an address covered by a route that a subnet router
advertises. A name that only exists locally comes back as `502 Bad Gateway` with
`no such host`.

`tailscale status` lists what your node knows.

## A wrapper worth having

Retrying is worth automating, because the first attempt after an idle period
often pays for the handshake. Something like this:

```sh
#!/bin/sh
set -u
host=${TS_SSH_HOST:?set TS_SSH_HOST}
user=${TS_SSH_USER:-root}
port=${TS_SSH_PORT:-22}
key=${TS_SSH_KEY:-$HOME/.ssh/id_ed25519}
bin=${TS_BIN:-tailscale}
sock=${TS_SOCKET:-$HOME/config/settings/tailscale/tailscaled.sock}

# Reap leftover `tailscale nc` processes. HaikuOS has no pkill, and `ps ax` hides
# these teams, so parse plain `ps` and kill by team id - the 4th field from the
# end of the line. This matters: a failed attempt can leave one behind, each
# leftover burns about a fifth of a core, and a few of them starve the daemon
# until nothing connects at all.
reap() {
	for id in $(ps 2>/dev/null | grep -- "$bin --" | grep -v grep |
			awk '{print $(NF-3)}'); do
		case $id in ''|*[!0-9]*) continue ;; esac
		kill -9 "$id" 2>/dev/null || true
	done
}
trap reap EXIT INT TERM

i=1
while [ "$i" -le "${SSH_ATTEMPTS:-5}" ]; do
	ssh -o ProxyCommand="env GOMAXPROCS=1 GODEBUG=asyncpreemptoff=1 $bin --socket=$sock nc %h %p" \
	    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-45}" \
	    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
	    -o StrictHostKeyChecking=accept-new \
	    -i "$key" -p "$port" "$user@$host" "$@"
	rc=$?
	reap
	# 0 = clean logout, 130 = Ctrl-C: do not retry those.
	[ "$rc" -eq 0 ] || [ "$rc" -eq 130 ] && exit "$rc"
	echo "ssh exited with $rc; retrying..." >&2
	i=$((i + 1))
	sleep 2
done
exit 1
```

Measured with that arrangement: 5 connections out of 5, each on the first
attempt, 2-3s each, with no leftovers.

## When it does not connect

**First attempt times out, second works.** Expected after an idle period; see
`ConnectTimeout` above. Retry, or raise the timeout.

**Everything fails and the machine feels slow.** Look for leftover
`tailscale nc` processes:

```sh
ps | grep 'tailscale --'
```

Each one burns roughly a fifth of a core, and on a 2-core machine a few of them
starve the daemon until nothing connects. Kill them by team id (`kill -9 <id>`,
the 4th field from the end of the `ps` line). The reaper above prevents this from
accumulating.

**Node never reaches Running.** `grep -- '-> Running'` in the daemon log
(`$HOME/config/settings/tailscale/err.log` if you used the launcher). Without it,
`tailscale nc` cannot work.

## Why not Tailscale SSH?

`tailscale ssh` needs the daemon to accept inbound connections for its SSH
server, which is not part of this port's tested surface. The `ProxyCommand`
route only needs outbound dialing, which userspace-networking mode does well.
