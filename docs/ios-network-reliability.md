# iOS network reliability workload

Run this on the tagged iOS build and export cmux-network.log after each
scenario. The export contains peer aliases and session IDs, never Mac IDs or
addresses.

1. Cold launch: terminate cmux, launch it, attach one Mac, and wait until the
   terminal is usable. Record the time from launch to the first usable terminal.
2. Background resume: leave the connected app in the background for eight
   minutes, return to it, and wait for a usable terminal. This exercises the
   startup recovery owner and the suspended-process deadline guard.
3. Liveness: keep the terminal open, let the liveness watchdog resubscribe
   (or use the existing debug liveness trigger), and verify that recovery has
   one recovery ID and one admitted session.
4. Single and multi-Mac: repeat with one Mac, then switch between two Macs and
   return to the first. The report must not show two active physical sessions
   for one peer.

Check an export with:

~~~sh
./scripts/analyze-ios-network-log.py /path/to/cmux-network.log \
  --expect-background-seconds 480
~~~

Use --json for a machine-readable artifact. A passing run has at least one
usable RPC connection, no duplicate active sessions per peer, and an observed
background gap of at least eight minutes. The output also reports usable
latency, cancellation reasons, recovery outcomes, discovery duration and
shape, relay-policy outcomes, direct-dial phase duration, route-plan counts,
path changes, and liveness resubscriptions. For a `no_route` failure,
`route_policy.assessment` distinguishes an empty plan, a plan with no public
relay URL, a plan that did contain a public relay, and an older build that did
not emit plan diagnostics. A public relay being present proves policy assembly
succeeded; it does not prove that the current network can reach the relay.
