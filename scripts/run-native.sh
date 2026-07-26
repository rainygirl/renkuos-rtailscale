#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
state_dir=${TS_STATE_DIR:-/boot/home/config/settings/tailscale}
socket=${TS_SOCKET:-$state_dir/tailscaled.sock}
state=${TS_STATE:-$state_dir/tailscaled.state}
ready_file=$state_dir/tailscaled.ready
pid_file=$state_dir/tailscaled.pid
log_file=${TS_LOG_FILE:-$state_dir/err.log}
startup_timeout=${TS_STARTUP_TIMEOUT:-60}

# Disable Go's signal-based async preemption for every tailscale binary we
# launch. On the Haiku/386 Go runtime async preemption is BROKEN: the signal
# handler cannot read the correct interrupted register context, so it can never
# inject the preemption, and stop-the-world (e.g. GC during startup) then spins
# SIGURG forever - one core stuck ~99% in runtime.sighandler with the daemon
# wedged (profiled and confirmed). With asyncpreemptoff=1 there is no signal
# storm: a wedged attempt stays idle (cheap for the retry loop) and the startup
# success rate rises. See the "Haiku/386 Go netpoller / preemption" notes in
# AGENTS.md. Appended so a user-set GODEBUG is preserved.
export GODEBUG="${GODEBUG:+$GODEBUG,}asyncpreemptoff=1"

mkdir -p "$state_dir"

stop_pid()
{
	target_pid=$1
	case $target_pid in
		''|*[!0-9]*) return ;;
	esac
	if ! kill -0 "$target_pid" 2>/dev/null; then
		return
	fi
	kill "$target_pid" 2>/dev/null || true
	stop_tries=0
	while kill -0 "$target_pid" 2>/dev/null && [ "$stop_tries" -lt 5 ]; do
		sleep 1
		stop_tries=$((stop_tries + 1))
	done
	if kill -0 "$target_pid" 2>/dev/null; then
		echo "tailscaled pid $target_pid did not stop; terminating it" >&2
		kill -9 "$target_pid" 2>/dev/null || true
		sleep 1
	fi
}

# kill_all_tailscaled force-kills every lingering tailscaled AND tailscale (CLI)
# team.
#
# Haiku has NO pkill (the binary does not exist), and `ps ax` does not list
# these teams, so the usual `pkill tailscaled` is a silent no-op - leftover
# daemons/CLIs then pile up, spin CPU (a wedged team busy-loops one core), and
# hold the proxy ports. Instead, parse plain `ps` (which DOES show them) and kill
# each by its team id. In Haiku `ps` output the trailing columns are
# <team> <threads> <gid> <uid>, so the team id is the 4th field from the end
# (NF-3), even though the command text contains spaces. The pattern matches both
# "dist/haiku32/tailscaled" and "dist/haiku32/tailscale" (the CLI), since a
# wedged `up`/`nc` spins just like a wedged daemon.
kill_all_tailscaled()
{
	kill_round=0
	while [ "$kill_round" -lt 5 ]; do
		# Match the daemon ("tailscaled ") and the CLI ("tailscale --socket..."),
		# but NOT this launcher ("tailscale-haiku") or the grep itself.
		kill_ids=$(ps 2>/dev/null \
			| grep -E 'dist/haiku32/tailscaled |dist/haiku32/tailscale --' \
			| grep -v grep | awk '{print $(NF-3)}')
		[ -z "$kill_ids" ] && return
		for kill_id in $kill_ids; do
			case $kill_id in
				''|*[!0-9]*) continue ;;
			esac
			kill -9 "$kill_id" 2>/dev/null || true
		done
		sleep 1
		kill_round=$((kill_round + 1))
	done
}

if [ "${1:-}" = stop ]; then
	old_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
	if [ -n "$old_pid" ] && [ -S "$socket" ]; then
		stop_pid "$old_pid"
	else
		# Compatibility with an invalid/stale PID file or a daemon started by
		# an older launcher that did not yet create one.
		kill_all_tailscaled
	fi
	rm -f "$socket" "$ready_file" "$pid_file"
	exit 0
fi

# Never unlink the socket of a daemon that is still running. Doing so leaves
# the old process alive but unreachable and lets a second daemon contend for
# the proxy ports and state file.
old_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
	if [ ! -S "$socket" ]; then
		echo "error: pid file names a live process ($old_pid), but its LocalAPI socket is missing" >&2
		echo "run '$0 stop' before starting another daemon" >&2
		exit 1
	fi
	echo "Stopping previous tailscaled (pid $old_pid)..."
	stop_pid "$old_pid"
elif [ -z "$old_pid" ] && [ -S "$socket" ]; then
	echo "error: an existing tailscaled socket has no matching PID file: $socket" >&2
	echo "run '$0 stop' once to clean up an older daemon safely" >&2
	exit 1
fi
rm -f "$socket" "$ready_file" "$pid_file"

# The experimental Haiku/386 Go runtime has a flaky scheduler that
# intermittently wedges one of the many goroutines spun up during startup
# (WireGuard, gVisor netstack, DERP). When that happens the backend never
# finishes initializing and the readiness marker is never written. A wedged
# process does not recover, but a fresh start usually gets past it, so we
# start the daemon under a bounded retry loop: give each attempt a short
# window to signal readiness and, if it wedges, kill it and try again.
attempt_timeout=${TS_ATTEMPT_TIMEOUT:-18}
max_attempts=${TS_MAX_ATTEMPTS:-8}
# Base proxy ports. On the Haiku/386 kernel a daemon that has already bound its
# SOCKS5/HTTP proxy ports and is then killed (because it wedged during startup)
# leaks those ports: they stay unavailable even though the process is gone. To
# keep the retry loop from failing with "address already in use", each attempt
# uses a fresh pair of ports. The attempt that succeeds prints the ports it
# actually bound.
base_socks=${TS_SOCKS5_PORT:-1055}
base_http=${TS_HTTP_PORT:-1056}
socks_port=$base_socks
http_port=$base_http

daemon_pid=""
# Ensure a wedged/lingering daemon is always cleaned up on exit or interrupt.
trap 'if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; sleep 1; kill -9 "$daemon_pid" 2>/dev/null || true; fi; rm -f "$socket" "$ready_file" "$pid_file"; trap - EXIT; exit 130' INT TERM
trap 'if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; rm -f "$socket" "$ready_file" "$pid_file"' EXIT

ready=0
attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
	rm -f "$socket" "$ready_file"
	# Send the daemon's output to a log file rather than the terminal. On the
	# Haiku/386 runtime a regular file is a reliable, non-wedging destination
	# for the daemon's log writes, and it preserves the successful attempt's
	# log for inspection.
	socks_port=$((base_socks + (attempt - 1) * 2))
	http_port=$((base_http + (attempt - 1) * 2))
	: > "$log_file"
	# GOMAXPROCS=1 for the daemon too. On Haiku/386 the runtime's cross-M wakeup
	# is unreliable, and with the default (2 P here) startup wedges constantly:
	# on a freshly booted box, GOMAXPROCS=1 gives ready in ~1s, Running, and a
	# DERP connection within ~6s, where the default sits at "connecting to
	# derp-N" or a control TLS handshake forever with the CPU idle. Single-P
	# costs some parallelism but this hardware is a 1.33GHz Atom anyway.
	GOMAXPROCS=1 TS_HAIKU_READY_FILE="$ready_file" TS_HAIKU_DEFER_START=1 "$script_dir/tailscaled" \
		--tun=userspace-networking \
		--socket="$socket" \
		--state="$state" \
		--socks5-server=127.0.0.1:$socks_port \
		--outbound-http-proxy-listen=127.0.0.1:$http_port >"$log_file" 2>&1 &
	daemon_pid=$!
	printf '%s\n' "$daemon_pid" > "$pid_file"
	echo "Starting tailscaled (attempt ${attempt}/${max_attempts}, pid $daemon_pid, socks=$socks_port http=$http_port)..."

	tries=0
	while [ "$tries" -lt "$attempt_timeout" ]; do
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			echo "tailscaled exited during startup; retrying..." >&2
			break
		fi
		if [ -f "$ready_file" ] && [ -S "$socket" ]; then
			ready=1
			break
		fi
		sleep 1
		tries=$((tries + 1))
	done

	if [ "$ready" -eq 1 ]; then
		break
	fi

	# This attempt wedged or exited. Kill it and try a fresh start. Give the
	# OS a moment to release the SOCKS5/HTTP proxy ports before retrying so the
	# next attempt does not fail with "address already in use".
	echo "LocalAPI not ready after ${tries}s (Haiku startup wedge); restarting tailscaled..." >&2
	kill "$daemon_pid" 2>/dev/null || true
	sleep 1
	kill -9 "$daemon_pid" 2>/dev/null || true
	kill_all_tailscaled
	daemon_pid=""
	sleep 3
	attempt=$((attempt + 1))
done

if [ "$ready" -ne 1 ]; then
	echo "error: tailscaled LocalAPI did not become ready after $max_attempts attempts" >&2
	echo "The Haiku/386 runtime wedged on every startup attempt." >&2
	exit 1
fi

echo "LocalAPI is ready: $socket"

# The tailscale CLI runs on the same flaky Haiku/386 runtime as the daemon and
# wedges during startup at a similar rate. Unlike the daemon it has no
# readiness marker, so detect a successful start by watching for output: once
# the CLI gets past the startup wedge it dials the LocalAPI and prints progress
# within a couple of seconds. If an attempt produces no output within the grace
# period it has wedged; kill it and retry. An attempt that starts producing
# output is left alone to run to completion (e.g. `up` blocking on the auth
# URL). Output streams to the terminal via tee.
# The tailscale CLI is run with GOMAXPROCS=1 below. On Haiku/386 it otherwise
# wedges during startup nearly every time (0/15 measured for `tailscale version`,
# which does no I/O) because cross-M wakeup is unreliable and a short-lived
# process never recovers; with a single P it is 12/12. It must be set in the
# environment, since the runtime fixes the P count before main runs. The daemon
# is intentionally left at the default - it needs the parallelism.
cli_grace=${TS_CLI_GRACE:-8}
cli_attempts=${TS_CLI_ATTEMPTS:-15}
run_tailscale_cli() {
	cli_ok=0
	k=1
	while [ "$k" -le "$cli_attempts" ]; do
		cli_out=$state_dir/tailscale-cli.out
		: > "$cli_out"
		GOMAXPROCS=1 "$script_dir/tailscale" --socket="$socket" "$@" >"$cli_out" 2>&1 &
		cli_pid=$!
		g=0
		while [ "$g" -lt "$cli_grace" ]; do
			if ! kill -0 "$cli_pid" 2>/dev/null; then
				break # process finished within the grace window
			fi
			if [ -s "$cli_out" ]; then
				break # produced output: past the startup wedge
			fi
			sleep 1
			g=$((g + 1))
		done
		if [ -s "$cli_out" ] || ! kill -0 "$cli_pid" 2>/dev/null; then
			# Past the wedge (or already done). Stream output and wait for it.
			tail -n +1 -f "$cli_out" 2>/dev/null &
			tail_pid=$!
			wait "$cli_pid" 2>/dev/null || true
			sleep 1
			kill "$tail_pid" 2>/dev/null || true
			cli_ok=1
			return 0
		fi
		echo "tailscale CLI wedged on startup (attempt ${k}/${cli_attempts}); retrying..." >&2
		kill -9 "$cli_pid" 2>/dev/null || true
		sleep 1
		k=$((k + 1))
	done
	echo "error: tailscale CLI wedged on every attempt" >&2
	return 1
}

# run_up retries `tailscale up` until the backend actually starts. Unlike other
# CLI calls, `up` can get past its own startup wedge (it prints the initial
# LocalAPI status) and THEN wedge the daemon's backend Start goroutine, so
# "produced output" is not enough. Watch the daemon log for "Switching ipn
# state" (proof Start ran); if it does not appear, kill this up and retry.
# count_log counts matching lines in the daemon log.
#
# Do NOT write this as `$(grep -c ... || echo 0)`. grep -c already prints 0 when
# nothing matches, and it exits 1 at the same time, so the `|| echo 0` appended a
# second line: the value became "0\n0" and every `[ "$n" -gt "$m" ]` test failed
# with "integer expression expected". The visible effect was that run_up never
# recognised a backend that had started - it killed a perfectly healthy `up` and
# retried, over and over, while the node was already Running.
count_log() {
	n=$(grep -ac "$1" "$log_file" 2>/dev/null)
	case $n in
		''|*[!0-9]*) n=0 ;;
	esac
	printf '%s\n' "$n"
}

run_up() {
	up_attempts=${TS_UP_ATTEMPTS:-15}
	j=1
	while [ "$j" -le "$up_attempts" ]; do
		before=$(count_log "control: doLogin\|Switching ipn state")
		GOMAXPROCS=1 "$script_dir/tailscale" --socket="$socket" up "$@" \
			--accept-dns=false --accept-routes=true \
			>"$state_dir/tailscale-cli.out" 2>&1 &
		up_pid=$!
		w=0
		started=0
		# Give each attempt up to ~40s to make the backend start. "Started"
		# means the backend's control/login machinery began (doLogin) or the ipn
		# state changed - i.e. Start() ran and did not wedge. TLS/login may then
		# take a while; that is fine, we hand off to the running up.
		#
		# Reaching Starting is NOT enough, see wait_for_running below: the
		# backend often gets that far and then never reaches Running, and in that
		# state nothing works - `tailscale nc`, and therefore ssh through the
		# tailnet, fails every time.
		while [ "$w" -lt 40 ]; do
			# Already Running is the strongest possible evidence; take it
			# immediately so a healthy `up` is never killed.
			if grep -aq -- "-> Running" "$log_file" 2>/dev/null; then
				started=1
				break
			fi
			now=$(count_log "control: doLogin\|Switching ipn state")
			if [ "$now" -gt "$before" ]; then
				started=1
				break
			fi
			# If up exited on its own (e.g. printed an auth URL and returned, or
			# errored), stop waiting and surface its output.
			kill -0 "$up_pid" 2>/dev/null || break
			sleep 1
			w=$((w + 1))
		done
		if [ "$started" -eq 1 ]; then
			# Backend is starting. Stream up's output (auth URL etc.) and let it
			# run to completion.
			tail -n +1 -f "$state_dir/tailscale-cli.out" 2>/dev/null &
			up_tail=$!
			wait "$up_pid" 2>/dev/null || true
			sleep 1
			kill "$up_tail" 2>/dev/null || true
			return 0
		fi
		# up wedged the backend (or itself). Kill just the CLI teams (NOT the
		# daemon) so a wedged up stops spinning, then retry.
		echo "tailscale up did not start the backend (attempt ${j}/${up_attempts}); retrying..." >&2
		kill -9 "$up_pid" 2>/dev/null || true
		for cli_id in $(ps 2>/dev/null | grep 'dist/haiku32/tailscale --' \
			| grep -v grep | awk '{print $(NF-3)}'); do
			case $cli_id in ''|*[!0-9]*) continue ;; esac
			kill -9 "$cli_id" 2>/dev/null || true
		done
		sleep 2
		j=$((j + 1))
	done
	echo "error: tailscale up could not start the backend after $up_attempts attempts" >&2
	return 1
}

# wait_for_running waits for the node to actually reach the Running state.
#
# Measured on hardware: a start either reaches Running in about 4-6s or never
# does, and the difference decides everything downstream - when Running is
# reached, ssh through the tailnet works; when the backend stops at Starting,
# every `tailscale nc` fails. About one start in three used to stop at Starting,
# and the launcher declared success anyway, which is why "tailscale is up" was
# not a reliable statement.
wait_for_running() {
	w=0
	while [ "$w" -lt "${TS_RUNNING_TIMEOUT:-30}" ]; do
		if grep -aq -- "-> Running" "$log_file" 2>/dev/null; then
			return 0
		fi
		sleep 2
		w=$((w + 2))
	done
	return 1
}

# Bring the node all the way to Running, restarting the daemon if the backend
# stalls at Starting. Restarting is the only known remedy: the stall is inside
# the daemon's own start path, so retrying `up` against the same daemon does not
# help.
cycles=${TS_START_CYCLES:-5}
cycle=1
running=0
while [ "$cycle" -le "$cycles" ]; do
	if [ -n "${TS_AUTH_KEY:-}" ]; then
		run_up --auth-key="$TS_AUTH_KEY"
	else
		if [ "$cycle" -eq 1 ]; then
			echo "Opening Tailscale authentication..."
		fi
		run_up
	fi
	if wait_for_running; then
		running=1
		break
	fi
	echo "backend reached Starting but not Running (cycle ${cycle}/${cycles}); restarting tailscaled..." >&2
	kill "$daemon_pid" 2>/dev/null || true
	sleep 1
	kill -9 "$daemon_pid" 2>/dev/null || true
	kill_all_tailscaled
	daemon_pid=""
	sleep 3
	rm -f "$socket" "$ready_file"
	: > "$log_file"
	GOMAXPROCS=1 TS_HAIKU_READY_FILE="$ready_file" TS_HAIKU_DEFER_START=1 "$script_dir/tailscaled" \
		--tun=userspace-networking \
		--socket="$socket" \
		--state="$state" \
		--socks5-server=127.0.0.1:$socks_port \
		--outbound-http-proxy-listen=127.0.0.1:$http_port >"$log_file" 2>&1 &
	daemon_pid=$!
	printf '%s\n' "$daemon_pid" > "$pid_file"
	tries=0
	while [ "$tries" -lt "$attempt_timeout" ]; do
		[ -f "$ready_file" ] && [ -S "$socket" ] && break
		kill -0 "$daemon_pid" 2>/dev/null || break
		sleep 1
		tries=$((tries + 1))
	done
	cycle=$((cycle + 1))
done

if [ "$running" -ne 1 ]; then
	echo "error: the node never reached Running after $cycles cycles" >&2
	echo "Nothing that goes through the tailnet will work; see $log_file." >&2
	exit 1
fi

echo "Tailscale is running."
echo "SOCKS5 proxy: 127.0.0.1:$socks_port"
echo "HTTP proxy:   127.0.0.1:$http_port"
echo "Leave this terminal open; press Ctrl+C to stop tailscaled."

wait "$daemon_pid"
