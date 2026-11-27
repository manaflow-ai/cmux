# Network requirements for the iPhone app

The hosts, ports and protocols the cmux iPhone app and your Mac need to connect, in the order they try them, for IT admins.

The cmux iPhone app connects to your Mac directly when it can, and through a relay when it cannot. It tries the ways below in order and uses the first that works. Every way carries the same end-to-end encrypted tunnel (WireGuard) between the phone and the Mac: no relay can read it. Both the phone's network and the Mac's network need at least one of them.

## Always needed

Sign-in, the list of your Macs, and the setup of each connection use HTTPS on port 443. The app and the Mac need these hosts:

- mobile-api.cmux.dev, TCP 443: the cmux service (HTTPS, and a WebSocket for connection setup).
- api.stack-auth.com, TCP 443: sign-in.
- cmux.com, TCP 443: the sign-in page.

> If these are blocked, the app cannot sign in or find your Mac, and nothing below helps.

## 1. Direct

Fastest. The phone and the Mac send UDP to each other, on any port, after learning their public addresses from a STUN server:

- stun.cloudflare.com, UDP 3478: STUN.
- UDP between the phone and the Mac, any port (on the same network, or through NAT).

## 2. Relay over TURN

When direct UDP fails, traffic goes through Cloudflare's TURN service. The app tries UDP first, then TLS:

- turn.cloudflare.com, UDP 3478 (and 53): TURN over UDP.
- turn.cloudflare.com, TCP 443 (and 5349): TURN over TLS.

## 3. Relay through cmux (HTTPS)

When neither UDP nor the TURN host gets through, for example on a network that allows only approved hosts, the phone and the Mac carry the tunnel in a WebSocket to the cmux service. It is a normal HTTPS request on port 443 to the same host as sign-in:

- mobile-api.cmux.dev, TCP 443: wss://mobile-api.cmux.dev/v1/relay/... (HTTP/1.1 with Upgrade: websocket).

A proxy or firewall must allow WebSocket upgrades to that host and keep the connection open. This way is slower than the others, so the app moves off it about a minute after a direct or TURN path works again.

## TLS inspection

The app checks the certificates of cmux's hosts and of the TURN host against the public certificate authorities. A proxy that decrypts HTTPS and re-signs it with its own certificate makes those checks fail. Exempt mobile-api.cmux.dev, api.stack-auth.com, cmux.com and turn.cloudflare.com from TLS inspection.

## When nothing works

If every way is blocked, the app says which part of the network is in the way and what to try: another network (a hotspot, or Wi-Fi outside the office), or the hosts and ports above for your IT team. It keeps retrying on its own. On the Mac, the same hosts and ports apply.

## Summary for a firewall rule

```text
Required:   TCP 443  mobile-api.cmux.dev, api.stack-auth.com, cmux.com
Recommended: UDP 3478 stun.cloudflare.com
            UDP 3478, TCP 443  turn.cloudflare.com
            UDP, any port, between the phone and the Mac
```

- [Remote machines and Tailscale](remote.md)
- [Settings reference](settings.md)
