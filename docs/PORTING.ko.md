# RenkuOS용 Tailscale

[English](PORTING.md) | [한국어](PORTING.ko.md)

RenkuOS(Haiku)용 비공식 Tailscale 포트입니다. `tailscaled` 데몬, `tailscale`
CLI, 그리고 이 둘을 다루는 네이티브 창 **R Tailscale**로 이루어집니다.
Tailscale Inc.와는 관계가 없습니다.

포크가 아닙니다. 수정하지 않은 `tailscale/tailscale` 체크아웃에 적용하는
패치와 빌드 스크립트이므로, 무엇을 왜 바꿨는지 그대로 볼 수 있습니다.

| 아키텍처 | 구성 | 상태 |
| --- | --- | --- |
| arm64 | `patches/` + `build.sh`, Go는 [renkuos-golang](https://github.com/rainygirl/renkuos-golang) | RenkuOS arm64에서 빌드하고 실행함 ([검증](#검증) 참고) |
| x86_64 | 같은 `patches/` + `build.sh`, Go는 [korli/go](https://github.com/korli/go) | `build.sh x86_64`로 빌드해 Haiku x86_64에서 실행, tailnet 로그인까지 확인([검증](#검증) 참고). RenkuOS x86_64에서는 실행하지 않음 |
| x86 (32비트) | [`i386/`](../i386/), 별도의 훨씬 큰 포트 | 포트는 그대로이며, R Tailscale과 함께 `renkuos_rtailscale_x86`으로 패키징해 Haiku x86_gcc2에서 로그인 전까지 실행 |

## 구성

```
build.sh                 arm64 또는 x86_64용 tailscale + tailscaled 빌드
install.sh               dist/<arch>/를 ~/config/non-packaged에 설치
patches/                 tailscale 소스에 대한 64비트용 변경
patches/haiku/           TUN에서 IPv6를 위한 Haiku 네트워크 스택 수정 (패키지에 미포함)
deps/                    의존성 세 개(wireguard-go, gvisor, pkg/sftp)에 대한 변경
packaging/               tailscaled-service(데몬 실행 방식), launch 작업
tools/make-hpkg.sh       설치 패키지 생성 (RenkuOS에서 실행)
gui/                     네이티브 창 R Tailscale
i386/                    32비트 x86 포트 (자체 README와 스크립트 포함)
```

## 32비트를 따로 둔 이유

32비트 포트는 믿을 수 없는 Go 런타임을 우회해야 했습니다. 쓸 만한 네트워크
폴러가 없었고, 비동기 선점이 깨져 있었고, 스케줄러가 시작 중에 멈췄습니다.
그래서 tailscale 패치가 약 2,700줄이고 대부분이 이 결함을 피하는 코드이며,
런처는 시작이 성공할 때까지 데몬을 다시 띄웁니다.

64비트 Go 포트에는 이런 결함이 없으므로 그 코드를 가져오지 않았습니다.
64비트 패치는 39개 파일에 약 1,500줄을 더하며, Haiku 자체가 요구하는 것만
합니다.

| 변경 | 이유 |
| --- | --- |
| `wgengine/router/osrouter`: Haiku용 라우터 | `ifconfig`와 `route`로 tun 인터페이스의 주소(IPv4, 스택이 허용하면 IPv6도)와 tailnet 경로를 설정. exit node의 기본 경로는 `1.0.0.0/8`부터 `128.0.0.0/1`까지 경로 여덟 개로 넣음 |
| `net/dns`: 시스템의 `resolv.conf` 기록 | Haiku의 리졸버는 `/etc/resolv.conf`가 아니라 `/boot/system/settings/network/resolv.conf`를 읽음 |
| `cmd/tailscaled`: 기본값을 `userspace-networking`으로 | 터널 드라이버가 모든 이미지에 있지는 않음. 서비스가 `tun`을 먼저 요청하고 안 되면 전환 |
| `paths`: 소켓과 상태를 `~/config/settings/tailscale`에 | Haiku에는 `/var/run`, `/var/lib` 관례가 없음 |
| `paths`, `cmd/tailscale/cli`: `golang.org/x/sys/unix` 호출 제거 | 이 모듈은 Haiku를 지원하지 않음 |
| `ipn/ipnserver`: 피어 자격 증명 없이 LocalAPI 클라이언트 허용 | Haiku가 이를 제공하지 않음. 소켓은 소유자 설정 디렉터리의 0600 모드 |
| `net/netmon`: ioctl로 인터페이스와 기본 경로를 읽고 변화를 감시 | Haiku에서 Go의 `net.Interfaces()`가 빈 목록을 돌려주고, 인터페이스가 없으면 netcheck가 STUN 탐색을 모두 건너뛰어 릴레이 전용이 됨. 변화는 네트워크 스택의 알림으로 받음([네트워크 변화](#네트워크-변화) 참고) |
| `net/dns`: `resolv.conf` 감시 | net_server가 DHCP 임대마다 이 파일을 새로 씀. 데몬이 2초 안에 알아채고 자기 리졸버를 되돌려 놓음 |
| `ssh/tailssh`, `util/osuser`, `feature/ssh`: Haiku에서 Tailscale SSH 서버 | PTY, 터미널 모드, 창 크기를 libroot의 `ioctl`로 처리하고, 사용자와 셸은 `/etc/passwd`에서 읽으며, `login`이나 `su`를 쓰지 않음 |
| `cmd/tailscaled`: 서브넷과 exit node 트래픽을 netstack에서 처리 | Haiku의 IPv4 스택은 패킷 전달도 주소 변환도 하지 않음 |
| `net/netns`, `wgengine/magicsock`: 데몬 자신의 트래픽을 터널 밖으로 | exit node가 기본 경로를 가진 동안 필요함. Haiku에는 정책 라우팅도 소켓 마크도 없음 |

`deps/`에는 세 가지가 더 있습니다.

- **wireguard-go**: 빌드 태그 네 개를 고쳐 스텁 구현이 쓰이게 하고, TUN 장치인
  `tun/tun_haiku.go`를 더합니다. Haiku의 터널 드라이버에는 클론 장치가 없습니다.
  `tun/<n>`이라는 인터페이스를 설정하면 그때 만들어지고 `/dev/tun/<n>`이
  생기며, 읽기와 쓰기 한 번에 IP 패킷 하나가 오갑니다.
- **gvisor**: IP 식별자 버킷을 2048개에서 64개로 줄입니다. 버킷마다
  `crypto/rand`로 초기화하는데 Haiku의 `getentropy`가 8KiB를 만들어내는 데
  매우 오래 걸릴 수 있어, RenkuOS/arm64에서 이 초기화 하나가 시작을 36~45초
  붙잡았습니다. 변경 후에는 2초 안에 백엔드가 준비됩니다.
- **pkg/sftp**: Tailscale SSH의 SFTP 하위 시스템을 위한 빌드 태그 두 개.

이 중 일부는 Go의 Haiku용 `syscall` 패키지가 제공하지 않는 함수(`ioctl`,
포트, 네트워크 알림이 쓰는 generic syscall)가 필요합니다. 모두 Haiku의 모든
Go 바이너리가 링크하는 `libroot.so`의 평범한 함수이므로,
`golang.org/x/sys/unix`가 Solaris에서 libc를 부르는 방식대로
`//go:cgo_import_dynamic` 선언과 `syscall.sysvicall6`로 cgo 없이 부릅니다.
`net/netmon`과 `ssh/tailssh`가 각각 `__ioctl`을 선언하며, 링커가 둘을 하나의
import로 합칩니다.

`patches/haiku/haiku-tun-ipv6.patch`는 빌드에 쓰이지 않습니다. Haiku 자체에
대한 변경입니다. [IPv6](#ipv6)를 보세요.

## 설치

패키지 없이, `dist/<arch>/`가 빌드된 체크아웃에서 설치할 수 있습니다.

```sh
./install.sh                 # ~/config/non-packaged에 설치, --uninstall로 제거
```

또는 `tools/make-hpkg.sh`로 만든 패키지로 설치합니다.

```sh
pkgman install ./renkuos_rtailscale-1.102.0-6-arm64.hpkg
```

패키지는 `tailscale`, `tailscaled`, `tailscaled-service`, R Tailscale(응용
프로그램 메뉴), 로그인할 때 서비스를 시작하는 launch 작업을 설치합니다.
`install.sh`는 launch 작업을 뺀 같은 파일을 설치합니다.

그다음 **R Tailscale**을 열고 **로그인**을 누릅니다. 로그인 링크가 표시되고
브라우저에서 열립니다. 이 링크는 다른 기기에서 열어도 됩니다.

## 사용

arm64와 x86_64에서 `tailscaled`는 TUN 인터페이스(`tun/0`, 또는 비어 있는 첫
번째)를 엽니다. 그러면 시스템에 tailnet의 모든 기기로 가는 경로가 생기고
MagicDNS 이름이 풀리므로, 어떤 프로그램이든 tailnet에 바로 접속합니다. 다른
기기도 이 기기의 서비스(sshd 포함)에 바로 접속합니다.

```sh
ping mac-mini
ssh user@mac-mini
```

이 모드에서 알아 둘 세 가지입니다.

- **IPv4는 되고, IPv6는 수정된 네트워크 스택에서만 됩니다.** [IPv6](#ipv6)를
  보세요.
- **서비스가 도는 동안 `resolv.conf`가 바뀝니다.** 원본은 옆에
  `resolv.pre-tailscale-backup.conf`로 보관됩니다. `tailscale set
  --accept-dns=false`를 쓰면 건드리지 않습니다. 데몬은 SIGTERM이나 SIGINT로
  멈출 때 파일을 되돌리고, `tailscaled-service`는 데몬이 끝난 뒤와 다음 시작
  전에 `tailscaled --cleanup`을 실행하므로 `kill -9`로 죽은 경우도
  처리됩니다. net_server가 인터페이스를 다시 설정할 때(예: DHCP 갱신) 이
  파일을 새로 쓰면, 데몬이 파일을 감시하다가 2초쯤 안에 자기 내용을 다시
  씁니다.
- **서비스가 멈출 때 인터페이스는 지우지 않고 내립니다.** 다음 시작에서 다시
  씁니다. 장치를 닫은 직후에 인터페이스를 지우면 그 이름을 한동안 쓸 수 없게
  될 수 있습니다.

터널 드라이버가 없는 이미지와 32비트 x86에서는 userspace-networking 모드로
동작합니다. 이때는 운영체제의 트래픽을 라우팅하지 **않고** MagicDNS로 이름이
풀리지도 않습니다. `tailscaled-service`의 환경에 `TS_TUN=userspace-networking`을
주면 이 모드를 강제합니다. 어느 모드인지는 R Tailscale의 맨 아래 줄에
표시됩니다.

두 모드 모두 서비스가 프록시 두 개를 엽니다. userspace 모드에서는 응용
프로그램이 이 프록시로 tailnet에 접속합니다.

| | 주소 |
| --- | --- |
| SOCKS5 | `127.0.0.1:1055` |
| HTTP 프록시 | `127.0.0.1:1056` |

userspace 모드에서 ssh는 CLI를 거칩니다.

```sh
ssh -o ProxyCommand='tailscale nc %h %p' user@100.x.y.z
```

R Tailscale의 **SSH** 버튼은 선택한 기기에 대해 바로 이 명령을 터미널 창에서
실행합니다.

### 네트워크 변화

데몬은 Haiku의 `ifconfig`와 `route`가 쓰는 ioctl로 커널에서 인터페이스,
주소, 플래그, 기본 경로를 읽습니다. 인터페이스가 생기거나 사라지거나 바뀔 때,
링크가 올라가거나 내려갈 때 오는 네트워크 스택의 알림(`start_watching_network()`가
감싸는 포트 인터페이스)을 구독하고, 경로 변화에는 알림이 없으므로 5초마다
라우팅 테이블도 확인합니다. 장치의 링크가 끊긴 인터페이스는 내려간 것으로
봅니다. 그래서 케이블을 뽑거나 Wi-Fi가 끊기면 노드가 멈추고("all links
down"), 링크가 돌아오면 재시작 없이 소켓을 다시 묶고 공인 주소를 다시 찾아
다시 연결합니다.

### IPv6

라우터는 tun 인터페이스에 IPv4와 함께 노드의 IPv6 주소(`fd7a:...`)와
tailnet의 IPv6 경로도 설정합니다. 배포된 이미지의 Haiku 네트워크 스택은 터널
인터페이스에 이 주소를 거부합니다(`ifconfig: Setting address failed: Invalid
Argument`). 터널 장치용 IPv6 datalink 프로토콜을 등록하지 않기 때문입니다.
그러면 데몬은 한 번 로그를 남기고 IPv4만으로 계속하며, IPv4는 전과 같이
동작합니다.

`patches/haiku/haiku-tun-ipv6.patch`가 그 수정으로, tailscale이 아니라
Haiku 네트워크 스택(`stack`과 `loopback_frame` datalink 프로토콜)에 대한
것입니다. 이것을 적용하면 인터페이스가 IPv6 주소를 받아들이고 tailnet에
IPv6로도 접속됩니다. 커널 애드온을 바꿔야 하므로 이 패키지에는 넣지
않았습니다. 패치의 설명을 보세요. IPv6 기본 경로(exit node의 `::/0`)는 넣지
않으므로, exit node를 쓸 때 인터넷으로 가는 IPv6 트래픽은 exit node를 거치지
않습니다.

### Tailscale SSH

데몬이 키나 비밀번호 대신 tailnet의 신원과 접근 규칙으로 tailnet에 SSH를
직접 제공할 수 있습니다.

```sh
tailscale up --ssh            # 또는: tailscale set --ssh
ssh user@this-machine         # tailnet의 다른 기기에서
```

누가 어떤 사용자로 로그인할 수 있는지는 tailnet 정책의 `ssh` 규칙이 정하고,
`check` 규칙은 다른 곳과 마찬가지로 먼저 브라우저에서 다시 로그인하게 합니다.
사용자 이름은 이 기기의 것입니다. Haiku에는 계정이 하나 있고(Haiku는 `user`,
RenkuOS는 `baron`), 홈과 셸은 `/etc/passwd`에서 읽습니다. 정책의 `ssh`
규칙에서 그 이름을 허용하세요(`"users": ["baron"]`).

Linux와 다른 점입니다.

- `login`, `su`, PAM이 없습니다. `/etc/passwd`의 셸을 사용자 홈에서 바로
  실행하고, `PATH`는 Haiku의 Terminal과 같게 설정합니다.
- Haiku의 모든 사용자는 UID 0이므로, 세션은 로컬 Terminal처럼 기기 전체에
  대한 권한을 가집니다.
- 대화형 세션은 클라이언트의 터미널 모드와 창 크기를 적용한 의사 터미널을
  받습니다. SFTP 하위 시스템이 들어 있습니다.

### 서브넷 라우터와 exit node

이 기기가 LAN이나 인터넷 전체로 가는 경로를 tailnet에 제공할 수 있고, 자신의
인터넷 트래픽을 다른 기기로 보낼 수도 있습니다.

```sh
tailscale set --advertise-routes=192.168.1.0/24   # 그다음 관리 콘솔에서 승인
tailscale set --advertise-exit-node               # 마찬가지
tailscale set --exit-node=<기기>                  # 다른 기기를 사용, 승인 불필요
tailscale set --exit-node=                        # 사용 중지
```

**경로나 exit node 제공**은 FreeBSD, Windows와 같이 netstack으로 동작합니다.
tailnet에서 광고한 네트워크로 가는 패킷은 데몬 자체의 TCP/IP 스택에서 끝나고,
데몬이 실제 목적지로 평범한 소켓을 엽니다. Haiku의 IPv4 스택은 패킷 전달도
주소 변환도 하지 않으므로 커널 라우팅 테이블은 여기에 쓰이지 않습니다. TCP와
UDP를 전달하고, ping에는 Haiku의 `ping`을 실행해 응답합니다.

**exit node 사용**은 시스템 경로를 바꿉니다. 기본 경로를 바꾸지 않고,
`tun/0`을 거치는 `1.0.0.0/8`부터 `128.0.0.0/1`까지의 경로 여덟 개가 인터넷을
덮어 기본 경로보다 우선하며, 물리 기본 경로는 남습니다(`route`가 `0.0.0.0`으로
가는 경로를 모두 기본 경로로 받아들이므로 `0.0.0.0/8`은 뺍니다). LAN은 그
on-link 경로가 더 구체적이므로 계속 닿습니다. 데몬 자신의 트래픽(컨트롤
서버, DERP, STUN, exit node와 다른 피어로 가는 WireGuard)이 터널로 되돌아
들어가지 않도록, 데몬이 통신하는 원격 주소마다 첫 패킷 전에 물리 게이트웨이를
거치는 호스트 경로를 넣습니다. exit node를 끄거나 데몬을 SIGTERM으로 멈추면
이 경로를 모두 다시 지웁니다. 이 경로들은 있는 동안 상태 디렉터리의
`bypass-routes`에도 기록되므로, `kill -9`로 죽은 데몬의 경로는
`tailscaled --cleanup`(`tailscaled-service`가 데몬이 끝난 뒤 실행함)이나 다음
시작이 지웁니다.

한계입니다.

- IPv4만: IPv6 기본 경로는 없습니다(위 참고).
- 호스트 경로는 exit node를 켰을 때의 기본 게이트웨이를 거칩니다. exit node를
  쓰는 중에 네트워크의 게이트웨이가 바뀌면 서비스를 다시 시작하세요.

CLI에는 `--socket` 옵션이 필요 없습니다. 포트의 기본 경로가 서비스가 쓰는
경로와 같습니다.

```sh
tailscale status
tailscale netcheck
```

### R Tailscale

![RenkuOS arm64에서 연결된 R Tailscale](rtailscale.png)

- 연결 상태, 이 기기의 이름과 주소, tailnet 이름
- 로그인, 로그아웃, 연결, 연결 끊기
- tailnet의 기기 목록: 온라인 여부, 주소, 운영체제, 직접 연결인지 릴레이인지
- 기기 주소 복사(행을 더블 클릭) 또는 ssh 열기
- 서비스가 실행 중이 아니면 시작

데몬의 LocalAPI와 유닉스 소켓으로 직접 통신하므로, CLI를 실행하지 않고도
`tailscale status`와 같은 내용을 보여줍니다. 영어와 한국어를 지원합니다.

## 빌드

Go 바이너리는 대상 아키텍처용 Haiku를 지원하는 Go가 있는 아무 기기에서나
빌드합니다(Go를 구하는 방법은 `build.sh` 머리말 참고).

```sh
GO=/path/to/go ./build.sh arm64      # -> dist/arm64/
```

RenkuOS arm64에서는 `pkgman install golang_bin`으로 그 Go를 설치할 수 있고,
`./build.sh arm64`가 네이티브로 빌드합니다.

R Tailscale:

```sh
cd gui && make                        # RenkuOS에서
gui/tools/cross-build.sh arm64        # 또는 Docker로 크로스 컴파일
cp gui/dist/arm64/RTailscale dist/arm64/
```

패키지는 RenkuOS에서 만듭니다.

```sh
tools/make-hpkg.sh
```

## 검증

RenkuOS arm64(QEMU, hrev60072), Go 1.27.4, tailscale v1.102.0에서 확인한
내용입니다.

- `tailscaled`가 시작되고 2초 안에 백엔드가 준비됨
- `tailscale netcheck`: UDP 동작, 공인 IPv4 주소 확인, DERP 지연 시간 측정
- 제어 서버에 접속해 로그인 링크를 받음
- R Tailscale이 서비스 중지 상태, 로그인 필요 상태, 링크를 표시하고, 버튼으로
  서비스를 시작함
- 깨끗한 체크아웃에서 `build.sh arm64` 성공, R Tailscale을 arm64와 x86_64로
  크로스 컴파일
- `install.sh` 동작, `tools/make-hpkg.sh`가 예상한 내용의 패키지를 생성함
- 실제 tailnet에 로그인: `tailscale status`가 피어를 나열하고,
  `tailscale ping`이 한 피어에는 직접(LAN에서 13 ms), 다른 피어에는 DERP를
  거친 뒤 직접 연결로 도달함
- `tailscale nc`, SOCKS5 프록시, HTTP 프록시(CONNECT)가 각각 피어의 sshd에
  MagicDNS 이름으로 연결해 배너를 읽음. SOCKS5 프록시로 인터넷에도 도달함
- SSH 버튼이 실행하는 명령인, `tailscale nc`를 ProxyCommand로 쓴 `ssh`가
  피어의 인증 단계까지 진행됨
- R Tailscale이 연결됨 상태, 이 기기의 이름과 주소, 피어 목록(직접 연결,
  릴레이, 오프라인)을 표시함
- R Tailscale의 버튼을 눌러 확인: **IP 복사**가 선택한 기기의 주소를
  클립보드에 넣고, **SSH**가 터미널을 열어 피어의 호스트 키 확인 단계까지
  진행됨
- 들어오는 연결: tailnet의 다른 기기가 이 기기의 tailnet 주소로 sshd에 ssh
  세션을 엶
- 패키지: `~/config/packages`에 복사하면 바로 활성화되고, 바이너리가
  `~/config/bin`에, R Tailscale이 응용 프로그램 메뉴에 나타남
- launch 작업: 재시작 후 아무도 실행하지 않아도 서비스가 작업으로 실행 중이고
  (`launch_roster info`에 표시됨) 노드가 tailnet에 다시 연결됨. 작업 파일은
  `data/launch`에 둠. `data/user_launch`는 `/system`에서만 읽으므로
  `~/config/packages`의 패키지가 거기에 넣으면 무시됨

Haiku x86_64(QEMU의 nightly hrev60450, RenkuOS 아님)에서 `build.sh x86_64`와
korli/go(golang-1.27-haiku, Go 1.27.4)로 만든 바이너리로 확인한 내용입니다.

- `install.sh` 동작, `tailscaled`가 시작되고 1초 안에 백엔드가 준비됨
- `tailscale netcheck`: UDP 동작, 공인 IPv4 확인, DERP 지연 시간 측정
- 제어 서버가 로그인 링크를 돌려주고 R Tailscale이 이를 표시함
- 실제 tailnet에 로그인: `tailscale status`가 피어를 나열하고,
  `tailscale ping`이 한 피어에는 직접(10 ms), 다른 피어에는 DERP로 도달함
- `tailscale nc`, SOCKS5 프록시, HTTP 프록시(CONNECT)가 각각 MagicDNS
  이름으로 피어의 sshd에 닿아 배너를 읽음. SOCKS5 프록시는 인터넷에도 도달함
- `tailscale nc`를 ProxyCommand로 쓴 `ssh`가 피어의 인증 단계까지 진행됨
- R Tailscale이 연결됨 상태와 직접/릴레이/오프라인이 표시된 피어 목록을
  보여 줌

pkgman.rainygirl.com에 게시한 패키지로 확인한 내용입니다.

- arm64(RenkuOS)와 x86_64(Haiku nightly): 저장소에서 `pkgman install
  renkuos_rtailscale`로 `/system`에 설치되고, 거기서 시작한 서비스가 tailnet에
  다시 연결되며, R Tailscale이 연결됨 상태를 보여 주고 Deskbar에 아이콘이 나옴
- 32비트(QEMU의 Haiku x86_gcc2 nightly hrev60450): `pkgman install
  renkuos_rtailscale_x86` 후 `tailscaled-service`가 i386 실행기를 실행하고,
  데몬이 준비되며, R Tailscale이 로그인 링크를 표시함

TUN 모드는 `1.102.0-2` 패키지로, 로그인한 상태에서 확인했습니다(먼저 파일로
설치하고, 다시 pkgman.rainygirl.com에서 `pkgman install`로 설치).

- arm64(RenkuOS, hrev60072)와 x86_64(Haiku nightly hrev60450): 서비스가
  `tun/0`을 엶. 프록시 없이 `ping`과 `curl`이 MagicDNS 이름으로 피어에 닿음.
  다른 기기에서 이 기기로 ping이 되고 sshd 배너를 읽음. 인터넷 접속은 그대로
  됨
- arm64: 서비스를 시작하고 데몬을 `kill -9`로 죽이기를 다섯 번 반복. 매번
  `resolv.conf`와 라우팅 테이블이 이전 상태로 돌아왔고 다음 시작이 `tun/0`을
  다시 씀. 쓸 수 없는 tun 이름을 주면 userspace networking으로 전환됐고
  SOCKS5 프록시가 동작함. R Tailscale에 TUN 안내 줄이 표시됨
- x86_64: 데몬이 SIGTERM으로 멈추고 인터페이스를 내림

revision 3은 arm64 전용입니다. 같은 소스를, 시작할 때 `234567`을 더 이상
출력하지 않는 Go 툴체인으로 빌드했습니다. RenkuOS arm64에서 revision 2 위에
파일로 설치한 뒤 다시 pkgman.rainygirl.com에서 설치했고, `tailscale
version`이 버전만 출력하고, 서비스가 `tun/0`을 열고, MagicDNS 이름으로 피어에
`ping`과 sshd 배너 읽기가 되고, Mac mini에서 ping이 돌아옴을 확인했습니다.

arm64의 revision 5(RenkuOS 라이브 이미지, hrev60072, 시그널 수정이 들어간
Go 툴체인)와 x86_64의 revision 4(Haiku nightly hrev60450)를 둘 다 QEMU에서,
파일로 `pkgman install`해 설치하고 `tailscaled-service`로 서비스를 시작해
로그인한 TUN 모드에서 확인했습니다.

- 둘 다: `tun/0`이 노드의 IPv4 주소로 올라옴. MagicDNS 이름으로 `ping
  mac-mini`와 그 피어의 HTTP 서버에 `curl`이 됨. `tailscaled`에 `kill -TERM`을
  보내면 멈추고 서비스 스크립트가 끝나며, `tun/0`이 내려가고 tailnet 경로가
  사라지고 `resolv.conf`가 DHCP의 것으로 돌아옴. 다시 시작하면 노드가 돌아오고
  피어가 응답함
- 둘 다: 기본 스택이 IPv6 주소를 거부하고, 한 번 로그를 남긴 뒤 IPv4는 그대로
  동작함
- arm64: QEMU `set_link`로 가상 NIC의 링크를 껐다 켬. 데몬이 "all links down;
  pausing"을 남기고, 링크가 돌아오자 "LinkChange: major, rebinding"을 남김.
  피어에 다시 직접 연결됨
- arm64: `tailscale up --ssh`가 받아들여지고 호스트 키가 게시됨. tailnet의
  Mac(OpenSSH)에서 정책의 check를 브라우저로 승인한 뒤: 명령이 `baron`(UID 0,
  셸 `/bin/bash`)으로 실행되고 종료 상태가 돌아옴. 원격 명령에 파이프한
  stdin이 도착함. 대화형 세션이 클라이언트 창 크기로 `/dev/tt/p0`을 받고,
  크기 변경(SIGWINCH)을 따르며, Ctrl-C가 `cat`을 중단하고, `exit 4`가 4로
  돌아옴. `scp`(SFTP와 예전 `-O` 프로토콜)와 `sftp`가 300KB 파일을 양방향으로
  복사하고 체크섬이 일치함
- arm64: `tailscale set --exit-node=tokyo`. `tun/0`을 거치는 경로 여덟 개와
  데몬의 피어, DERP, 컨트롤 서버로 가는 물리 게이트웨이 경유 호스트 경로가
  생기고, 인터넷에서 보이는 공인 주소가 exit node의 것으로 바뀌며, tailnet
  피어에도 계속 닿음. `--exit-node=`로 경로가 지워지고 라우팅 테이블과
  `resolv.conf`가 이전과 바이트 단위로 같음. exit node를 켠 채 데몬을
  `kill -9`: 서비스의 정리가 `tun/0`과 그 경로를 없애고 `resolv.conf`를
  되돌림. 게이트웨이 경유 호스트 경로 네 개는 한계에 적은 대로 남음. 다시
  시작하니 exit node가 다시 쓰임(설정이 유지됨)
- x86_64: 패키지가 `/system`에 있는 상태로 기기를 다시 시작하니 launch 작업이
  서비스를 시작했고(`launch_roster info`에 실행 중으로 표시됨) 노드가 tailnet에
  돌아옴. 지켜본 6분 동안 계속 떠 있었고 피어에 닿음
- x86_64, 미해결: 패키지를 다시 설치하고 ssh 세션에서 서비스를 손으로 시작한
  지 10분쯤 뒤에 데몬이 없어진 것을 한 번 발견함. 기기를 꺼 버려 로그를 잃었고,
  다시 재현되지 않음

확인하지 않은 내용입니다.

- **TUN 모드에서**: 연결 중의 DHCP 갱신, 잠자기 후 깨어남, 서브넷 라우트
  수락. x86_64에서의 네트워크 변화와 exit node
- tailnet 위의 **IPv6**: Haiku 스택 수정이 필요하며 이 시험에는 포함하지 않음
- 이 패키지로 서브넷 라우트나 exit node를 **제공**하는 것(관리자 승인이 필요함)

- **x86_64에서**: R Tailscale의 SSH와 IP 복사 버튼, 들어오는 연결
- **32비트에서**: 이 패키지로 로그인 링크 이후의 동작(i386 포트 자체는 로그인된
  기기에서 개발했습니다. `i386/` 참고)
- **arm64에서 `/system`에 설치된 패키지의 launch 작업**: x86_64와
  `~/config/packages`의 패키지로는 동작을 확인했습니다.
- serve/funnel, Taildrop 등 최소 빌드에서 빠진 기능

## 알려진 한계

- 출력을 일찍 끝나는 프로그램으로 파이프한 `tailscale` 명령
  (`tailscale netcheck | head`)이 SIGPIPE로 죽지 않고 멈추는 것이
  관찰됐습니다. 파일로 리다이렉트하거나 끝까지 실행하세요.
- `kill -9`로 죽은 데몬은 스스로 정리하지 못합니다. 그 뒤 `tailscaled-service`가
  실행하는 `tailscaled --cleanup`이 `resolv.conf`를 되돌리고 인터페이스를 내리고
  exit node용 호스트 경로를 지웁니다. 서비스 없이 손으로 시작한 데몬이 그렇게
  죽었다면 다음 시작 때 같은 일을 합니다. 깔끔하게 멈추려면 여전히
  `kill <team>`(SIGTERM)을 쓰세요.
- R Tailscale은 로그인 링크를 기본 브라우저로 엽니다. arm64 시험 이미지에서는
  WebPositive가 시작 중에(WebKit의 시간대 설정 단계에서, 아무것도 불러오기
  전에) 죽었습니다. 링크는 창에 남아 있고 **링크 복사** 버튼이 있으며, 다른
  기기에서 열어도 됩니다.
- Deskbar 트레이 항목은 아직 없습니다. R Tailscale은 창입니다.

## 라이선스

이 포트 고유의 자료(스크립트, R Tailscale, 문서, 저작물로서의 패치 파일)는
MIT입니다. `LICENSE`를 보세요.

패치된 코드는 원래 라이선스를 따릅니다. 패치가 추가한 파일을 포함해
Tailscale 소스는 BSD-3-Clause이고 저작권은 Tailscale Inc & contributors에
있습니다. gvisor와 wireguard-go도 각자의 라이선스를 따릅니다. Tailscale은
Tailscale Inc.의 상표입니다.

## AI 사용 고지

R Tailscale의 일부는 AI 코딩 도구(Anthropic Claude)의 도움을 받아 개발했습니다.
모든 코드는 작성자가 검토하고 테스트했습니다.
