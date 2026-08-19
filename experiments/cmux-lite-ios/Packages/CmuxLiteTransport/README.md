# CmuxLiteTransport

`CmuxLiteTransport` is the route-selection layer between discovery and
`CmuxLiteSession`. It does not know how Iroh or Tailscale work internally.
Each implementation conforms to `TransportConnector`, and the dialer owns one
ordered attempt at a time.

The policy is deliberately pure and observable:

- automatic mode tries Iroh, then Tailscale, then loopback by default;
- restricted mode filters to one route kind and never silently falls back;
- concurrent `connect()` calls join the same in-flight attempt;
- every attempt is emitted through `AsyncStream`;
- unavailable and incompatible routes can fall through;
- authorization denials and unknown connector errors stop selection instead of
  silently bypassing a trust decision.

The package contains no Iroh FFI, Tailscale SDK, sockets, timers, or UI. Those
adapters will be added behind this seam after their own focused tests exist.
