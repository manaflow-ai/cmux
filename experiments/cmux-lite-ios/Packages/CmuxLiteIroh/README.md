# CmuxLiteIroh

`CmuxLiteIroh` is the Swift adapter boundary for the isolated `cmux-lite`
IrohLib binding. It depends on the `cmux-lite` branch of the in-org FFI
package, but keeps generated handles out of the rest of the experiment.

The package owns the contracts that must be stable before native code enters:

- `IrohConnection` describes one native bidirectional connection;
- `IrohEndpointProvider` owns endpoint binding, route publication, dialing, and
  one explicitly owned inbound accept loop;
- `IrohLibConnectionProvider` owns one lazily-bound endpoint and shares it
  across concurrent callers;
- `IrohEndpointHost` serializes inbound accepts, isolates admission rejection,
  and explicitly owns each accepted protocol session;
- `IrohRouteCatalog` keeps endpoint identity separate from current relay and
  direct-address hints;
- `IrohConnector` maps generic Iroh routes into the transport dialer;
- `IrohByteStream` enforces the `ByteStream` lifecycle and rejects overlapping
  operations; its owner must explicitly await `close()` before releasing it;
- classified Iroh failures map into retryable or terminal transport outcomes;
- endpoint configuration keeps ALPN, relay mode, key material, and receive
  limits explicit and validated before native code runs;
- native stream shutdown drains the final bytes up to a configured deadline,
  then force-closes a vanished peer.

The test target injects fake endpoint factories and connections, so endpoint
reuse, accept ownership, route resolution, and close behavior are verified
without a relay. The concrete provider uses IrohLib's generated async API and
opens one bidirectional stream per route. The real integration suite binds two
ephemeral loopback endpoints and exercises byte exchange, the cmux-lite
handshake, ping/pong, explicit close, repeated sessions, incompatible ALPN
isolation, and the generic transport dialer.

The integration suite is intentionally renderer-independent. It proves the
native endpoint, identity check, route hints, stream framing boundary, and
session lifecycle without claiming pixel or terminal-renderer parity.

Run every cmux-lite package suite with
`./scripts/ci/run-cmux-lite-tests.sh`. This is the single entrypoint intended
for the required CI gate after the experiment is promoted.
