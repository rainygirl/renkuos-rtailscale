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
| x86 (32비트) | [`i386/`](../i386/), 별도의 훨씬 큰 포트 | renkuos-i386-tailscale-patch에 공개된 그대로 |

## 구성

```
build.sh                 arm64 또는 x86_64용 tailscale + tailscaled 빌드
install.sh               dist/<arch>/를 ~/config/non-packaged에 설치
patches/                 tailscale 소스에 대한 64비트용 변경
deps/                    의존성 두 개(wireguard-go, gvisor)에 대한 변경
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
64비트 패치는 12개 파일 125줄이고, Haiku 자체가 요구하는 것만 합니다.

| 변경 | 이유 |
| --- | --- |
| `net/tstun`: 스텁 장치 사용 | 열 수 있는 TUN 장치가 없음 |
| `cmd/tailscaled`: 기본값을 `userspace-networking`으로 | 위 항목의 결과 |
| `paths`: 소켓과 상태를 `~/config/settings/tailscale`에 | Haiku에는 `/var/run`, `/var/lib` 관례가 없음 |
| `paths`, `cmd/tailscale/cli`: `golang.org/x/sys/unix` 호출 제거 | 이 모듈은 Haiku를 지원하지 않음 |
| `ipn/ipnserver`: 피어 자격 증명 없이 LocalAPI 클라이언트 허용 | Haiku가 이를 제공하지 않음. 소켓은 소유자 설정 디렉터리의 0600 모드 |
| `net/netmon`: 경로 조회로 로컬 주소 확인 | Haiku에서 Go의 `net.Interfaces()`가 빈 목록을 돌려주고, 인터페이스가 없으면 netcheck가 STUN 탐색을 모두 건너뛰어 릴레이 전용이 됨 |

`deps/`에는 두 가지가 더 있습니다.

- **wireguard-go**: 빌드 태그 네 개를 고쳐 스텁 구현이 쓰이게 합니다.
- **gvisor**: IP 식별자 버킷을 2048개에서 64개로 줄입니다. 버킷마다
  `crypto/rand`로 초기화하는데 Haiku의 `getentropy`가 8KiB를 만들어내는 데
  매우 오래 걸릴 수 있어, RenkuOS/arm64에서 이 초기화 하나가 시작을 36~45초
  붙잡았습니다. 변경 후에는 2초 안에 백엔드가 준비됩니다.

## 설치

패키지 없이, `dist/<arch>/`가 빌드된 체크아웃에서 설치할 수 있습니다.

```sh
./install.sh                 # ~/config/non-packaged에 설치, --uninstall로 제거
```

또는 `tools/make-hpkg.sh`로 만든 패키지로 설치합니다.

```sh
pkgman install ./renkuos_rtailscale-1.102.0-1-arm64.hpkg
```

패키지는 `tailscale`, `tailscaled`, `tailscaled-service`, R Tailscale(응용
프로그램 메뉴), 로그인할 때 서비스를 시작하는 launch 작업을 설치합니다.
`install.sh`는 launch 작업을 뺀 같은 파일을 설치합니다.

그다음 **R Tailscale**을 열고 **로그인**을 누릅니다. 로그인 링크가 표시되고
브라우저에서 열립니다. 이 링크는 다른 기기에서 열어도 됩니다.

## 사용

`tailscaled`는 userspace-networking 모드로 동작합니다. 운영체제의 트래픽을
라우팅하지 **않습니다**. `100.x.y.z` 경로가 없고 MagicDNS로 이름이 풀리지도
않습니다. 응용 프로그램은 서비스가 여는 두 프록시로 tailnet에 접속합니다.

| | 주소 |
| --- | --- |
| SOCKS5 | `127.0.0.1:1055` |
| HTTP 프록시 | `127.0.0.1:1056` |

ssh는 CLI를 거칩니다.

```sh
ssh -o ProxyCommand='tailscale nc %h %p' user@100.x.y.z
```

R Tailscale의 **SSH** 버튼은 선택한 기기에 대해 바로 이 명령을 터미널 창에서
실행합니다.

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

확인하지 않은 내용입니다.

- **x86_64에서**: R Tailscale의 SSH와 IP 복사 버튼, 들어오는 연결, 패키지
- Tailscale SSH 서버, serve/funnel, 출구 노드, 서브넷 라우트: 최소 빌드에서
  빠져 있습니다.

## 알려진 한계

- 인터페이스 모니터는 주소 체계마다 호스트 길이 프리픽스를 가진 가상
  인터페이스 하나를 보고합니다. 네트워크가 붙고 끊기는 것은 알지만
  인터페이스 이름이나 LAN 프리픽스는 모릅니다.
- 출력을 일찍 끝나는 프로그램으로 파이프한 `tailscale` 명령
  (`tailscale netcheck | head`)이 SIGPIPE로 죽지 않고 멈추는 것이
  관찰됐습니다. 파일로 리다이렉트하거나 끝까지 실행하세요.
- **데몬이 SIGTERM이나 SIGINT로 멈추지 않습니다.** tailscale이 아니라 Go
  런타임 문제입니다. 같은 haiku/arm64 툴체인으로 빌드한 최소 Go 프로그램도
  `signal.Notify` 사용 여부와 관계없이 두 시그널을 무시합니다. 서비스는
  `kill -9 <team>`으로 멈추세요. 상태 파일은 바뀔 때마다 기록되고, 다음 시작
  때 남은 소켓을 교체합니다.
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
