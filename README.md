<img src="icon.png" width="64" align="left" alt="">

# Tailscale for RenkuOS

English · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

An unofficial port of Tailscale to RenkuOS (Haiku): the `tailscaled` daemon,
the `tailscale` CLI, and **R Tailscale**, a native window for them. Not
affiliated with Tailscale Inc.

![R Tailscale connected, on RenkuOS arm64](docs/rtailscale.png)

## Install with pkgman

| System | Commands |
| --- | --- |
| arm64 | `pkgman add-repo http://pkgman.rainygirl.com/arm64`<br>`pkgman install renkuos_rtailscale` |
| x86_64 | `pkgman add-repo https://pkgman.rainygirl.com/x86_64`<br>`pkgman install renkuos_rtailscale` |
| 32-bit x86 (x86_gcc2) | `pkgman add-repo https://pkgman.rainygirl.com/x86_gcc2`<br>`pkgman install renkuos_rtailscale_x86` |

If `pkgman add-repo` fails with `Operation not supported`, the network kit of
that image has no TLS; use `http://` instead of `https://` in the address.

The package installs `tailscale`, `tailscaled`, R Tailscale (in Deskbar ->
Applications), and a launch job that starts the service at login. Right
after installing, before the next login, R Tailscale starts the service
itself.

## Sign in

Open **R Tailscale** from Deskbar -> Applications and press **Sign in**. It
shows the sign-in link and opens it in the browser; the link can be opened on
any other device instead.

## Install from a checkout

Without a package, from a checkout that has `dist/<arch>/` built:

```sh
./install.sh                 # into ~/config/non-packaged; --uninstall removes it
```

## Uninstall

```sh
pkgman uninstall renkuos_rtailscale
```

On 32-bit x86 the package to remove is `renkuos_rtailscale_x86`.

## 32-bit x86

The 32-bit package is `renkuos_rtailscale_x86`. Its daemon and CLI come from a
separate, much larger port with its own launcher (`tailscale-haiku`), build
instructions and notes: see [`i386/`](i386/).

## AI disclosure

Parts of R Tailscale were developed with the assistance of AI coding tools
(Anthropic's Claude). All code has been reviewed and tested by the author.
