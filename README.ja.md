<img src="icon.png" width="64" align="left" alt="">

# RenkuOS 用 Tailscale

[English](README.md) · [Italiano](README.it.md) · 日本語 · [한국어](README.ko.md)

Tailscale を RenkuOS(Haiku)に移植した非公式ポートです。`tailscaled` デーモン、
`tailscale` CLI、そしてそれらのためのネイティブウィンドウ **R Tailscale** から
なります。Tailscale Inc. とは関係ありません。

![RenkuOS arm64 で接続中の R Tailscale](docs/rtailscale.png)

## pkgman でインストール

| システム | コマンド |
| --- | --- |
| arm64 | `pkgman add-repo http://pkgman.rainygirl.com/arm64`<br>`pkgman install renkuos_rtailscale` |
| x86_64 | `pkgman add-repo https://pkgman.rainygirl.com/x86_64`<br>`pkgman install renkuos_rtailscale` |
| 32 ビット x86 (x86_gcc2) | `pkgman add-repo https://pkgman.rainygirl.com/x86_gcc2`<br>`pkgman install renkuos_rtailscale_x86` |

`pkgman add-repo` が `Operation not supported` で失敗する場合、そのイメージの
ネットワークキットに TLS がありません。アドレスの `https://` を `http://` に
置き換えてください。

パッケージは `tailscale`、`tailscaled`、R Tailscale(Deskbar -> Applications)、
ログイン時にサービスを起動する launch ジョブをインストールします。
インストール直後、次のログインまでは R Tailscale がサービスを起動します。

arm64 と x86_64 では、サービスは TUN インターフェースを使います。すべての
プログラムが tailnet に直接接続でき(IPv4)、MagicDNS の名前がシステム全体で
解決されます。そのため、サービスの実行中はシステムの `resolv.conf` が
置き換えられます。詳細と代替動作は
[docs/PORTING.md](docs/PORTING.md#using-it) にあります。

## サインイン

Deskbar -> Applications から **R Tailscale** を開き、**Sign in** を押します。
サインイン用のリンクが表示され、ブラウザで開かれます。リンクは別のデバイスで
開いてもかまいません。

## チェックアウトからインストール

パッケージを使わず、`dist/<arch>/` をビルド済みのチェックアウトから:

```sh
./install.sh                 # ~/config/non-packaged にインストール、--uninstall で削除
```

## アンインストール

```sh
pkgman uninstall renkuos_rtailscale
```

32 ビット x86 で削除するパッケージは `renkuos_rtailscale_x86` です。

## 32 ビット x86

32 ビット版のパッケージは `renkuos_rtailscale_x86` です。デーモンと CLI は別の、
ずっと大きなポートのもので、専用のランチャー(`tailscale-haiku`)、ビルド手順、
注意点があります。[`i386/`](i386/) を参照してください。

## AI の利用について

R Tailscale の一部は AI コーディングツール (Anthropic の Claude) の支援を受けて開発しました。
すべてのコードは作者がレビューし、テストしています。
