# HaikuOS에서 tailnet 호스트에 SSH 접속하기

HaikuOS에서 `tailscaled`는 **userspace networking** 모드로 동작합니다. TUN 장치가 없으므로 운영체제의 트래픽을 라우팅하지 않습니다. 즉 HaikuOS에서 그냥 `ssh myserver`를 실행하면 평소 네트워크로 나갈 뿐 tailnet에는 닿지 않습니다. tailscaled를 *거쳐 가는* 프로그램만 tailnet 주소에 도달합니다.

통로는 ssh의 `ProxyCommand`로 쓰는 `tailscale nc`입니다. ssh는 자신의 stdin/stdout으로 대화하고, `tailscale nc`가 데몬의 다이얼러로 목적지에 연결하며, 연결은 tailnet을 타고 갑니다. 이 포트가 쓰는 유일한 데이터 경로인 DERP를 경유합니다.

```
ssh -- stdin/stdout -- tailscale nc -- tailscaled -- DERP -- 피어 -- 목적지 호스트
```

영문 문서: [SSH.md](SSH.md)

## 시작하기 전에

노드가 단순히 시작된 것이 아니라 **Running** 상태여야 합니다. `Starting`에서 멈춘 노드는 모든 `tailscale nc`가 실패합니다. `tailscale-haiku`는 Running에 도달하기 전에는 성공을 보고하지 않습니다. `tailscaled`를 직접 띄웠다면 확인하세요.

```sh
tailscale --socket=$HOME/config/settings/tailscale/tailscaled.sock status
```

## 명령

```sh
SOCK=$HOME/config/settings/tailscale/tailscaled.sock

ssh -o ProxyCommand="env GOMAXPROCS=1 GODEBUG=asyncpreemptoff=1 \
        tailscale --socket=$SOCK nc %h %p" \
    -o ConnectTimeout=45 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    -i ~/my-key.pem \
    user@100.x.y.z
```

여기서 네 가지는 장식이 아닙니다.

- **`GOMAXPROCS=1`** — CLI용입니다. Go 런타임이 `main` 실행 전에 읽으므로 반드시 환경변수로 줘야 합니다. 기본값이면 이 짧게 사는 프로세스가 시작 중에 자주 멈춥니다.
- **`GODEBUG=asyncpreemptoff=1`** — 같은 이유입니다.
- **`ConnectTimeout=45`** — 피어와의 WireGuard 세션이 만료된 뒤 첫 연결은 DERP 위에서 핸드셰이크를 다시 해야 하고, 이 하드웨어에서 10~15초 걸립니다. 20초로는 매번 집니다. 그래서 유휴 후 첫 시도가 실패하고 두 번째가 성공하는데, 불안정해 보이지만 실제로는 타임아웃이 짧았던 것뿐입니다.
- **`ServerAliveCountMax=3`** (간격 10초) — 중간에 조용해진 세션은 회복되지 않습니다. 30초에 실패하고 재시도하는 편이 1분을 기다리는 것보다 낫습니다.

## 이름 대신 주소를 쓰세요

MagicDNS는 HaikuOS의 리졸버에 연결돼 있지 않고, `tailscale nc`는 데몬을 통해 이름을 해석하는데 데몬은 당신 워크스테이션의 `/etc/hosts` 별칭을 모릅니다. tailnet IP(`100.x.y.z`)나 서브넷 라우터가 광고하는 경로에 포함된 주소를 쓰세요. 로컬에만 있는 이름은 `502 Bad Gateway`와 `no such host`로 돌아옵니다.

`tailscale status`로 노드가 아는 주소를 확인할 수 있습니다.

## 준비해 두면 좋은 래퍼

재시도는 자동화할 가치가 있습니다. 유휴 후 첫 시도는 핸드셰이크 비용을 치르는 경우가 많기 때문입니다.

```sh
#!/bin/sh
set -u
host=${TS_SSH_HOST:?TS_SSH_HOST를 설정하세요}
user=${TS_SSH_USER:-root}
port=${TS_SSH_PORT:-22}
key=${TS_SSH_KEY:-$HOME/.ssh/id_ed25519}
bin=${TS_BIN:-tailscale}
sock=${TS_SOCKET:-$HOME/config/settings/tailscale/tailscaled.sock}

# 남은 `tailscale nc` 프로세스를 수거합니다. HaikuOS에는 pkill이 없고 `ps ax`는
# 이 team들을 숨기므로, 평범한 `ps`를 파싱해 team id(줄 끝에서 4번째 필드)로
# 죽입니다. 중요합니다. 실패한 시도는 프로세스를 남길 수 있고, 하나당 코어의
# 약 1/5을 소모하며, 몇 개만 쌓여도 데몬이 굶어 아무것도 연결되지 않습니다.
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
	# 0 = 정상 로그아웃, 130 = Ctrl-C. 이 둘은 재시도하지 않습니다.
	[ "$rc" -eq 0 ] || [ "$rc" -eq 130 ] && exit "$rc"
	echo "ssh가 $rc 로 종료됨. 재시도합니다..." >&2
	i=$((i + 1))
	sleep 2
done
exit 1
```

이 구성으로 측정한 결과: 5회 연결 중 5회 성공, 모두 첫 시도, 각 2~3초, 잔여 프로세스 없음.

## 연결이 안 될 때

**첫 시도는 타임아웃, 두 번째는 성공.** 유휴 후에는 정상입니다. 위의 `ConnectTimeout` 설명을 보세요. 재시도하거나 타임아웃을 늘리면 됩니다.

**전부 실패하고 머신이 느립니다.** 남아 있는 `tailscale nc` 프로세스를 찾아보세요.

```sh
ps | grep 'tailscale --'
```

하나당 코어의 약 1/5을 소모하며, 2코어 머신에서는 몇 개만 쌓여도 데몬이 굶어 아무것도 연결되지 않습니다. team id로 죽이세요(`kill -9 <id>`, `ps` 줄 끝에서 4번째 필드). 위 래퍼의 수거 로직이 이 누적을 막아줍니다.

**노드가 Running에 도달하지 못합니다.** 데몬 로그에서 확인하세요. 런처를 썼다면 `$HOME/config/settings/tailscale/err.log`입니다.

```sh
grep -- '-> Running' $HOME/config/settings/tailscale/err.log
```

이것이 없으면 `tailscale nc`는 동작할 수 없습니다.

## Tailscale SSH는 왜 안 쓰나요?

`tailscale ssh`는 SSH 서버를 위해 데몬이 인바운드 연결을 받아야 하는데, 이는 이 포트에서 검증한 범위가 아닙니다. `ProxyCommand` 방식은 아웃바운드 다이얼만 필요하고, 그건 userspace-networking 모드가 잘 하는 일입니다.
