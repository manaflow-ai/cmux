# Terminal delivery recovery on iOS

A quiet terminal does not prove that its connection has died. Heartbeat-capable
Macs emit an event every three seconds through the same event reader as terminal
updates. Older Macs can legitimately send nothing while the shell is idle.

The watchdog starts a bounded subscription probe after nine seconds without an
event. A successful probe proves that the control request reached the Mac. It
does not prove that queued terminal events have reached the phone.

## Delayed delivery

For a heartbeat-capable host whose subscription is still registered:

1. The first successful probe starts a delivery grace period after its reply.
   The grace is the larger of nine seconds or twice the elapsed probe time.
2. Any received event clears that suspicion. Events received during either
   probe invalidate its recovery decision, even if the reply arrives more than
   nine seconds after that event.
3. After the grace expires, a second probe may repair the reader if no event
   has arrived. This replaces the event reader and requests authoritative
   output on the existing connection.

For example, with instant probes and watchdog checks at seconds 10 and 20,
the first probe at second 10 allows delivery through second 19. A heartbeat at
second 18 cancels recovery. Continued silence permits reader repair at second
20. If the first probe instead takes six seconds, its reply at second 16 grants
twelve more seconds, through second 28. The periodic watchdog and the second
probe can make actual recovery later.

Previously, a successful registration probe immediately restarted the reader.
It could do so even after output resumed during the probe. This converted
network delay into unnecessary restart and replay work.

## Failed probes and missing registration

Each probe and its existing subscription repair attempts have bounded deadlines.
Two failed checks without intervening delivery permit reader repair. A fresh
event also invalidates recovery while the app awaits native transport status.
The probe retains ownership until that status check finishes, preventing an
overlapping watchdog decision.

The watchdog replaces the shared connection only when the native transport
explicitly reports closure. An unavailable native status is inconclusive and
uses reader repair. Other connection error and lifecycle handlers retain their
existing behavior.

A host reporting a missing registration is different: updates emitted during
that gap may be lost. Reinstall the subscription and replay mounted terminals
even if an older queued event arrives during the probe. Legacy hosts without
heartbeats continue to treat a successful registration probe as liveness.

No finite timeout can perfectly distinguish a dead reader from arbitrarily slow
delivery. These checks reduce false recovery and limit its scope. They do not
prove that a particular terminal frame has rendered or that every dedicated
terminal lane is healthy.

## Regression coverage

`TerminalEventDeliveryLatencyTests` covers delivery during the first and second
probes, delivery that ages before a delayed reply, a slow probe extending grace,
delivery cancelling prior suspicion, delivery during native status checks,
unknown native status, and replay after lost registration.
`watchdogRestartsHeartbeatCapableStreamWhenDeliveryStops` verifies that sustained
silence still replaces the reader while preserving the client and connection
generation. The other watchdog tests retain legacy-host and transient-failure
coverage.
