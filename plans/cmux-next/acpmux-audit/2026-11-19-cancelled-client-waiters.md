# Cancelled client requests release their reply waiters

Owner: `gcp-agent-lane-4/asks-msg-reliability-lock`; integration:
`gcp-agent-lane-2/asks-hq-acpmux-msg`. Scope: the shared Rust CLI/TUI client,
`cmux-tui/crates/acpmux/src/client.rs`.

`send_request` registered a reply sender before awaiting the outgoing queue and
the reply. Only a response, send error or disconnect removed it. Dropping the
request future at a caller deadline left the sender retained for the life of an
unanswered connection.

The request now owns a drop guard for that slot. The map lock covers only map
operations and has no await or I/O, so cleanup is synchronous and constant cost
per cancelled request. A reply removes the same unique request ID; late replies
cannot satisfy another caller. This releases the local waiter without cancelling
or retrying daemon work that may already have taken effect.

Detector: `client::cancel_tests::cancelled_requests_leave_no_waiters_and_late_replies_do_not_close_the_client`.
Its stand-in daemon withholds 256 replies, checks no pending waiters remain after
caller cancellation, then checks a full outgoing queue and a late reply followed
by a successful new request. Fleet execution is required; the test's presence is
not a passing receipt.
