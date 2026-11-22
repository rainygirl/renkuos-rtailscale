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
| arm64 | `pkgman add-repo http://pkgman.rainygirl.com/arm64`<br>`pkgman install renkuos_rtailscale` |
| x86_64 | `pkgman add-repo https://pkgman.rainygirl.com/x86_64`<br>`pkgman install renkuos_rtailscale` |
| 32비트 x86 (x86_gcc2) | `pkgman add-repo https://pkgman.rainygirl.com/x86_gcc2`<br>`pkgman install renkuos_rtailscale_x86` |

`pkgman add-repo`가 `Operation not supported`로 실패하면 그 이미지의 네트워크
키트에 TLS가 없는 것입니다. 주소의 `https://`를 `http://`로 바꿔 쓰세요.

패키지는 `tailscale`, `tailscaled`, R Tailscale(Deskbar -> 응용 프로그램),
로그인할 때 서비스를 시작하는 launch 작업을 설치합니다. 설치 직후 다음
로그인 전까지는 R Tailscale이 서비스를 직접 시작합니다.

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
