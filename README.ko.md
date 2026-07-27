# Haiku(32비트 x86)용 Tailscale

Haiku/x86(`haiku/386`)에서 Tailscale을 네이티브로 빌드·실행하기 위한 패치 모음입니다. 포트에 필요한 Go 런타임 수정도 함께 들어 있습니다.

포크가 아닙니다. 수정하지 않은 `tailscale/tailscale` 체크아웃에 적용하는 패치와, 빌드 스크립트, Go 툴체인 패치로 구성돼 있어 무엇을 왜 바꿨는지 그대로 확인할 수 있습니다.

영문 문서: [README.md](README.md)

## 구성

```
install.sh               Linux/macOS에서 크로스 빌드, Haiku에서 설치
apply.sh                 tailscale 체크아웃에 포트 적용
patches/                 tailscale 소스 변경분
go-runtime/              Go 툴체인 변경분 (gvisor, wireguard-go 포함)
build/                   build.sh, Makefile - haiku/386 빌드
scripts/                 run-native.sh (런처)
testdata/                lockstress.go - 스케줄러 hang 재현기
SSH.md                   Haiku에서 tailnet 호스트에 접속하기 (영문)
SSH.ko.md                같은 문서의 한국어판
```

## 빌드는 어디서 해야 하나

**Haiku 머신에서는 빌드할 수 없습니다.** Linux나 macOS에서 빌드해 바이너리를 옮겨야 합니다.

- Go 컴파일러는 Go로 작성돼 있어, 빌드하려면 이미 동작하는 Go가 필요합니다.
- 32비트 Haiku에는 출발점이 될 Go가 없습니다. `pkgman`에 x86_32용 `go` 패키지가 없습니다.
- 보통의 우회책인 "타깃에서 도는 툴체인을 크로스 빌드하기"(Go의 `src/bootstrap.bash`)도 여기서는 실패합니다. `cmd/vendor/golang.org/x/sys/unix`에 Haiku 지원이 없어 컴파일이 멈춥니다.

  ```
  x/sys/unix/fdset.go:15:12: undefined: FdSet
  x/sys/unix/ioctl_unsigned.go:34:47: undefined: Winsize
  ```

  `x/sys/unix`를 Haiku로 포팅하면 이 문제가 풀리고 기기 내 빌드가 가능해집니다. 다만 별개의 작업이며 이 포트의 범위가 아닙니다.

혹시 Haiku 박스에 동작하는 Go가 있다면 `install.sh`가 그것을 사용합니다. `GO_BOOTSTRAP=/path/to/go`를 넘기면 그 자리에서 빌드합니다.

빌드 호스트에는 Go가 **설치돼 있지 않아도 됩니다.** tailscale의 `tool/go`가 부트스트랩 툴체인을 알아서 내려받습니다.

## 설치

Linux 또는 macOS에서:

```sh
./install.sh --package tailscale-haiku386.tar.gz
scp tailscale-haiku386.tar.gz user@haiku-box:
```

지정된 버전의 tailscale을 clone하고, 포트를 적용하고, 패치된 Go 툴체인과 `haiku/386` 바이너리를 빌드해 아카이브를 만듭니다. Go 툴체인을 컴파일하므로 수 분 걸립니다.

그다음 Haiku 머신에서:

```sh
./install.sh --prebuilt tailscale-haiku386.tar.gz
```

`~/config/non-packaged/bin`에 설치됩니다.

| 바이너리 | 설명 |
| --- | --- |
| `tailscaled` | 데몬 |
| `tailscale` | CLI |
| `tailscale-haiku` | 런처: 데몬을 띄우고 `up`을 실행한 뒤 Running 도달까지 대기 |

`tailscale-haiku`로 시작하고 그대로 두면 됩니다. 최초 실행 시 인증 URL을 출력합니다.

### 직접 패치를 적용하려면

```sh
git clone https://github.com/tailscale/tailscale
cd tailscale && git checkout v1.102.0
/path/to/haiku386-port/apply.sh .
./haiku32/build.sh
```

`apply.sh`는 tailscale 버전이 다르면 절반만 적용된 트리를 남기지 않고 거부합니다. `HAIKU386_FORCE=1`로 우회할 수 있습니다.

## 다른 머신에 접속하기

`tailscaled`는 userspace-networking 모드로 동작합니다. TUN 장치가 없으므로 운영체제의 트래픽을 라우팅하지 않습니다. ssh의 `ProxyCommand`로 `tailscale nc`를 사용하세요. [SSH.ko.md](SSH.ko.md)에 필수 옵션과 그 이유, 이름이 해석되지 않는 이유, 복사해 쓸 수 있는 재시도 래퍼가 정리돼 있습니다.

## Go 런타임 패치가 고치는 것

기반은 korli의 `haiku/386` 작업이고, 그 위에 다음을 얹었습니다.

| 패치 | 내용 |
| --- | --- |
| `go-haiku386.patch` | 기반 포트 (`build.sh`가 별도로 받아옴) |
| `go-haiku386-netpoll.patch` | 동작하는 `poll(2)` netpoller. accept/connect/read/write readiness 전달, `poll()` 호출 중 락 미보유 |
| `go-haiku386-preempt.patch` | 비동기 선점. Haiku의 시그널 래퍼는 레지스터 집합을 `ucontext` 포인터가 아니라 스택에 인라인으로 전달하므로, 기본 `sigtramp`가 쓰레기값을 읽었음 |
| `go-haiku386-sockets.patch` | 소켓을 netpoller에 등록. 이것이 없으면 트리 안의 모든 소켓 데드라인이 조용히 무효였음 |
| `go-haiku386-osyield.patch` | **startup hang.** `osyield()`가 `snooze()`의 64비트 `bigtime_t`를 32비트 워드 하나로 전달해 상위 절반이 스택 쓰레기값이 됐고, 그 "yield"가 사실상 영원히 잠들 수 있었음. 그것도 `lock2`의 스핀 단계에서 P를 쥔 채로 |
| `go-haiku386-mmap.patch` | `mmap`의 `off_t`에 있는 같은 종류의 결함. 런타임이 익명 매핑만 쓰므로 잠재적 |
| `go-haiku386-semacreate.patch` | 각 m의 세마포어를 첫 `lock2` 안이 아니라 m 생성 시점에 만들어, 런타임 임계구역에서 libc 할당이 일어나지 않게 함 |
| `go-haiku386-diag.patch.txt` | 선택 적용 진단. `build.sh`는 적용하지 않음. 일정 시간 아무것도 스케줄되지 않으면 `sysmon`이 스케줄러 상태를 덤프 |

`osyield` 가 버그입니다. 증상은 `main()` 이전에 프로세스가 얼어붙고, CPU는 0%, 실행 가능한 고루틴은 큐에 쌓이고, 유휴 스레드는 놀고 있는 상태였습니다. 스택 쓰레기값에 의존하므로 무작위처럼 보였고, `GOMAXPROCS=1`에서는 경합이 적어 `lock2`가 스핀 단계에 잘 도달하지 않아 드물게 발생했습니다. 

`testdata/lockstress.go`로 두 빌드를 번갈아 실행해 측정한 결과: 수정 적용 시 20회 중 hang 0회, 미적용 시 20회 중 12회.

이 포트 전반에 적용되는 교훈: **64비트 값을 받는 libc 함수는 386에서 인수 워드가 두 개 필요합니다.** 새로 추가하는 `sysvicall` 호출은 이 점을 반드시 확인하세요.

## tailscale 패치가 하는 일

데몬과 CLI 전반의 Haiku 지원입니다. 플랫폼 파일(`paths`, `safesocket`, `util/prompt`, `net/tstun`), LocalAPI 서버·클라이언트의 Haiku 전용 처리, DERP 및 control-plane 타임아웃, TUN 장치 없이 동작하는 userspace-networking 구성. 자세한 내용은 `apply.sh`가 설치하는 `haiku32/README.md`에 있습니다.

알려진 문제:

- 런처가 모든 것을 `GOMAXPROCS=1`, `GODEBUG=asyncpreemptoff=1`로 고정합니다. `osyield` 수정 이전의 설정이며 이후 재평가하지 않았습니다.
- 실패한 ssh 시도는 `tailscale nc` 프로세스를 남길 수 있고, 하나당 코어의 약 1/5을 소모합니다. 수거해야 합니다. SSH.ko.md 참고.
- 인바운드 미지원. Tailscale SSH와 serve는 검증하지 않았습니다.

## 라이선스

이 디렉터리의 포트 자체 산출물(스크립트, 재현기, 문서, 저작물로서의 패치 파일)은 MIT입니다. `LICENSE`를 참고하세요.

패치가 적용된 코드는 원래 라이선스를 유지합니다. tailscale 소스는 패치가 추가하는 파일까지 포함해 BSD-3-Clause, Copyright (c) Tailscale Inc & contributors입니다. Go 런타임 패치가 수정하는 코드는 BSD-3-Clause, Copyright (c) The Go Authors입니다. gvisor와 wireguard-go도 각자의 라이선스를 따릅니다.
