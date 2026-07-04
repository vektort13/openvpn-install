## openvpn-install (hardened fork)

OpenVPN [road warrior](http://en.wikipedia.org/wiki/Road_warrior_%28computing%29) installer for Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS and Fedora.

This is a hardened fork of [Nyr/openvpn-install](https://github.com/Nyr/openvpn-install). It keeps the original "install in under a minute" experience and **full compatibility with the official OpenVPN clients** (OpenVPN Connect and the community GUI/CLI), while adding stronger defaults for security, speed and resilience on restrictive networks.

### Installation

Run the script and follow the assistant:

```bash
wget https://raw.githubusercontent.com/vektort13/openvpn-install/master/openvpn-install.sh -O openvpn-install.sh && bash openvpn-install.sh
```

Once it finishes, run it again to add clients, revoke clients or uninstall OpenVPN.

The generated `.ovpn` works as-is in the official clients on Windows, macOS, Linux, iOS and Android — no third-party software required.

## What this fork adds

### Reaching restrictive networks
- **Port 443 by default (no 1194).** The installer defaults to port **443** instead of the easily-blocked 1194, so the primary instance already blends in with HTTPS/QUIC. With the default UDP choice you get **UDP 443 as primary + TCP 443 as fallback** and no 1194 listener at all.
- **Automatic port 443 fallbacks (always on).** Alongside the primary instance, the missing 443 variant is deployed automatically:
  - **UDP 443** (subnet `10.8.2.0/24`) — looks like QUIC / HTTP-3 to DPI and keeps full UDP speed. Many networks that block other UDP ports still pass UDP 443.
  - **TCP 443** (subnet `10.8.1.0/24`) — last resort for networks that block all UDP.

  Every client profile ships with multiple `remote` lines, so the official client tries the primary protocol first and **falls back to UDP 443, then TCP 443, automatically** (`connect-timeout 10`). Each 443 instance is skipped only when the primary instance already uses that exact protocol/port.
- **`port-share` decoy against active probing.** The TCP 443 instance forwards any connection that is **not** a valid OpenVPN handshake to a local nginx serving a neutral landing page (`127.0.0.1:8080`). Probes and browsers hitting your `IP:443` see a real website instead of silence.

### Security
- **tls-crypt-v2** instead of tls-crypt v1: every client gets an **individual** control-channel key embedded in its `.ovpn`. A leaked client config no longer exposes a key shared by everyone, and the server stays silent to scans and invalid probes.
- **Download integrity check**: the EasyRSA tarball is verified against its official **SHA256** digest before use (supply-chain protection); installation aborts on mismatch.
- **Modern crypto**: `tls-version-min 1.3` and an explicit `data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305` (weak ciphers excluded).
- **`verify-x509-name`** on the client to prevent impersonation with another certificate from the same CA.
- **Tighter file permissions**: `chmod 600` on `ca.key`, `server.key`, the tls-crypt-v2 key and on every generated `.ovpn` (which contains the client private key).
- **Shorter client certificate lifetime** (3 years) while the server certificate and CRL remain long-lived.

### Performance
- Larger socket buffers (`sndbuf`/`rcvbuf` 512 KB, pushed to clients) and `fast-io` for UDP.
- `mssfix 1420` to avoid fragmentation on mobile and PPPoE links.
- Kernel tuning: raised `net.core.rmem_max`/`wmem_max`, and **BBR + fq** congestion control enabled when the kernel supports it (helps the TCP 443 fallback on lossy links).

### Resilience
- **Idle-aware nightly restart**: a systemd timer restarts server instances around 04:30 (±30 min), but **skips any instance with connected clients**, so nobody is disconnected.
- **Auto-restart on failure**: a systemd drop-in brings a crashed daemon back after 5 seconds.
- **Status logging** (`status-version 2`) so you can always see who is connected.

Uninstalling through the menu cleanly removes every added component (timer, drop-ins, sysctl file, decoy site, firewall/SELinux rules).

## Notes on censorship resistance

The anti-blocking features above (TCP 443 fallback, `port-share`, tls-crypt-v2) defeat port blocking and **active probing**, and remove OpenVPN's static protocol signature. They do **not** obfuscate the traffic's entropy.

Advanced DPI systems (for example Russia's TSPU or Iran's filtering) can still block OpenVPN by its protocol signature and by analysing the entropy of the first packets, **regardless of the port used** — the official client cannot be made to emit a genuine TLS ClientHello. Defeating that requires **client-side obfuscation** (Cloak/stunnel, AmneziaWG, XTLS-Reality, Xray/VLESS/Trojan, obfuscated WireGuard, etc.), which needs software beyond the official OpenVPN client and is therefore out of scope for this fork.

## I want to run my own VPN but don't have a server

Any small VPS with a public IPv4 address will do.

## Credits

Based on [Nyr/openvpn-install](https://github.com/Nyr/openvpn-install). Released under the MIT License (see `LICENSE.txt`).
