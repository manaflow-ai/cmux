# CmuxLiteIroh

`CmuxLiteIroh` is the Swift adapter boundary for the isolated `cmux-lite`
IrohLib binding. It depends on the `cmux-lite` branch of the in-org FFI
package, but keeps generated handles out of the rest of the experiment.

The package owns the contracts that must be stable before native code enters:

- `IrohConnection` describes one native bidirectional connection;
- `IrohConnectionProvider` owns endpoint binding and dialing;
- `IrohLibConnectionProvider` owns one lazily-bound endpoint and shares it
  across concurrent callers;
- `IrohConnector` maps generic Iroh routes into the transport dialer;
- `IrohByteStream` enforces the `ByteStream` lifecycle and rejects overlapping
  operations; its owner must explicitly await `close()` before releasing it;
- classified Iroh failures map into retryable or terminal transport outcomes;
- endpoint configuration keeps ALPN, relay mode, key material, and receive
  limits explicit and validated before native code runs.

The test target injects fake endpoint factories and connections, so endpoint
reuse and close behavior are verified without a relay. The concrete provider
currently uses IrohLib's generated async API and opens one bidirectional stream
per route. A later slice will add a local listener harness and exercise the
same provider against two real endpoints before any app integration.

Native stream close currently sends a FIN and then closes the QUIC connection;
the bounded peer-acknowledgement contract is intentionally deferred until the
binding exposes a cancellable acknowledgement operation.
