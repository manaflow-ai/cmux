# cmux-mux Rust Client

Synchronous Rust client for the cmux-mux Unix-socket JSON-lines protocol.

## Build

```bash
cd mux
cargo build -p cmux-mux-client --locked
```

## Usage

```rust
use cmux_mux_client::{ClientConfig, MuxClient};

let socket = std::env::var("CMUX_MUX_SOCKET")?;
let mut client = MuxClient::connect(ClientConfig::from_socket_path(socket))?;
let surface = client.new_workspace(Some("sdk-demo"), Some(80), Some(24))?.surface;
client.send(surface, Some("echo hello\r"), None)?;
println!("{}", client.read_screen(surface)?.text);
# Ok::<(), Box<dyn std::error::Error>>(())
```

## E2E

```bash
cd mux
CMUX_MUX_SOCKET=/path/to/session.sock cargo run -p cmux-mux-client --example e2e --locked
```
