# CmuxLiteIroh

`CmuxLiteIroh` is the Swift adapter boundary for a native Iroh binding. It
contains no Rust, C headers, static libraries, endpoint key storage, or relay
configuration yet.

The package owns the contracts that must be stable before native code enters:

- `IrohConnection` describes one native bidirectional connection;
- `IrohConnectionProvider` owns endpoint binding and dialing;
- `IrohConnector` maps generic Iroh routes into the transport dialer;
- `IrohByteStream` enforces the `ByteStream` lifecycle and rejects overlapping
  operations; its owner must explicitly await `close()` before releasing it;
- classified Iroh failures map into retryable or terminal transport outcomes.

The test target injects a fake provider and connection. The next native slice
will implement the provider with a small Rust C ABI, then run the same tests
against a local Iroh listener before any app integration.
