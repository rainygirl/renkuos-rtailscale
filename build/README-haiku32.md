# Native Tailscale for 32-bit Haiku

This target builds real Haiku/x86 ELF executables. It does not download Linux
binaries, create a guest image, or require QEMU. The port extends korli's Go
1.26 Haiku port with a 386 runtime, linker, and syscall implementation.

Install the bundled native binaries on macOS, Linux, or Haiku/x86:

```sh
make haiku32
```

The output is `dist/haiku32/tailscale`, `tailscaled`, and the convenience
launcher `tailscale-haiku`. Copy that directory to a 32-bit Haiku system and
run:

```sh
cd dist/haiku32
TS_AUTH_KEY=tskey-auth-... ./tailscale-haiku
```

Without an auth key, start the launcher and run the printed `tailscale up`
command in another Terminal. The local SOCKS5 proxy listens on
`127.0.0.1:1055`; the HTTP proxy listens on `127.0.0.1:1056`.

This first native port deliberately uses Tailscale's userspace networking
mode. It does not install a Haiku kernel TUN driver or change Haiku's system
routes. Applications can use `ALL_PROXY=socks5://127.0.0.1:1055`.

`make haiku32` uses the bundled native binaries and needs neither QEMU nor a Go
compiler or network connection. Developers can set `HAIKU32_REBUILD=1` to
rebuild from the pinned Go port. A native Haiku rebuild additionally requires
`GO_BOOTSTRAP` to point at a compatible installed Go tree.
