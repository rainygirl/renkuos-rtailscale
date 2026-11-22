<img src="icon.png" width="64" align="left" alt="">

# RenkuOS용 Tailscale

[English](README.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · 한국어

Tailscale을 RenkuOS(Haiku)로 옮긴 비공식 포트입니다. `tailscaled` 데몬,
`tailscale` CLI, 그리고 이 둘을 위한 네이티브 창 **R Tailscale**로 이루어져
있습니다. Tailscale Inc.와는 관련이 없습니다.

![RenkuOS arm64에서 연결된 R Tailscale](docs/rtailscale.png)

## pkgman으로 설치

| 시스템 | 명령 |
| --- | --- |
| arm64 | `pkgman add-repo https://pkgman.rainygirl.com/arm64`<br>`pkgman install renkuos_rtailscale` |
| x86_64 | `pkgman add-repo https://pkgman.rainygirl.com/x86_64`<br>`pkgman install renkuos_rtailscale` |
| 32비트 x86 (x86_gcc2) | `pkgman add-repo https://pkgman.rainygirl.com/x86_gcc2`<br>`pkgman install renkuos_rtailscale_x86` |

`pkgman add-repo`가 `Operation not supported`로 실패하면 그 시스템의 네트워크
키트가 TLS 없이 빌드된 것입니다(RenkuOS arm64 이미지에는 있습니다). 주소의
`https://`를 `http://`로 바꿔 쓰세요.

패키지는 `tailscale`, `tailscaled`, R Tailscale(Deskbar -> 응용 프로그램),
로그인할 때 서비스를 시작하는 launch 작업을 설치합니다. 설치 직후 다음
로그인 전까지는 R Tailscale이 서비스를 직접 시작합니다.

arm64와 x86_64에서는 서비스가 TUN 인터페이스를 씁니다. 모든 프로그램이
tailnet에 바로 접속하고 MagicDNS 이름이 시스템 전체에서 풀리며, 이를 위해
서비스가 도는 동안 시스템의 `resolv.conf`가 바뀝니다. tailnet에는 IPv4로
접속합니다. IPv6는 아직 배포된 이미지에 들어 있지 않은 수정이 적용된 Haiku
네트워크 스택이 있어야 합니다. 네트워크 변화(케이블이나 Wi-Fi 링크가
끊겼다 돌아오는 것 등)는 서비스가 스스로 따라갑니다. 자세한 내용과 대체
동작은 [docs/PORTING.ko.md](docs/PORTING.ko.md#사용)에 있습니다.

같은 문서에 Tailscale SSH 서버(`tailscale up --ssh`), 서브넷 라우트 광고와
이 기기를 exit node로 제공하는 방법, 다른 기기를 exit node로 쓰는 방법
(`tailscale set --exit-node=<이름>`)도 있습니다.

## 로그인

Deskbar -> 응용 프로그램에서 **R Tailscale**을 열고 **로그인**을 누릅니다.
로그인 링크가 표시되고 브라우저로 열립니다. 링크는 다른 기기에서 열어도
됩니다.

## 체크아웃에서 설치

패키지 없이, `dist/<arch>/`가 빌드된 체크아웃에서 설치합니다.

```sh
./install.sh                 # ~/config/non-packaged에 설치, --uninstall로 제거
```

## 제거

```sh
pkgman uninstall renkuos_rtailscale
```

32비트 x86에서 제거할 패키지는 `renkuos_rtailscale_x86`입니다.

## 32비트 x86

32비트 패키지는 `renkuos_rtailscale_x86`입니다. 데몬과 CLI는 별도의 훨씬 큰
포트에서 나오며, 자체 실행기(`tailscale-haiku`)와 빌드 방법, 참고 사항이 따로
있습니다. [`i386/`](i386/)를 보세요.

## AI 사용 고지

R Tailscale의 일부는 AI 코딩 도구(Anthropic Claude)의 도움을 받아 개발했습니다.
모든 코드는 작성자가 검토하고 테스트했습니다.
