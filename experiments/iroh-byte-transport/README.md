# Iroh Byte Transport Experiment

This is a deliberately small Rust experiment for the cmux mobile Iroh path. It is not linked into the iOS app. It proves the byte-stream shape we need before we decide whether the production bridge is an FFI library, a local helper, or a later Swift-native Iroh package.

The experiment uses one Iroh ALPN:

```text
dev.cmux.mobile.terminal/0
```

Run the same-process smoke test:

```bash
cargo run -- self-test
```

Run a listener and print an attach-route JSON snippet:

```bash
cargo run -- listen
```

Dial that listener from another terminal:

```bash
cargo run -- dial --endpoint-id <id> --direct-addrs "<ip:port>" --relay-url <relay-url> --message ping
```

Use `--no-relay` with `listen` and `dial` when you want a local-only smoke test.

The printed route matches the Swift `CmxAttachRoute` schema:

```json
{
  "id": "iroh",
  "kind": "iroh",
  "endpoint": {
    "type": "peer",
    "id": "<iroh endpoint id>",
    "direct_addrs": ["<ip:port>"],
    "relay_url": "<relay url>"
  },
  "priority": 20
}
```

Production implication: the Swift app can keep the route selection and framing code in Swift. Only the Iroh endpoint/dialer needs Rust unless a Swift-native Iroh implementation becomes available.
