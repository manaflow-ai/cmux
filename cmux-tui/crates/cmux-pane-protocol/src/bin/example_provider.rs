//! The `com.example.hello` example provider. Spawned by the router (fd in
//! `CMUX_PANE_ROUTER_FD`) or self-started (`CMUX_PANE_ROUTER_SOCKET` and
//! `CMUX_PANE_APP_CREDENTIAL`). It says hello to the router, then serves
//! pages directly on a loopback WebSocket; the router never sees its calls.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

#[cfg(unix)]
#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    use std::sync::Arc;

    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use cmux_local_auth::ListenerPolicy;
    use cmux_pane_protocol::envelope::Role;
    use cmux_pane_protocol::example::GreetTicks;
    use cmux_pane_protocol::op::Event;
    use cmux_pane_protocol::router::ops::{
        Endpoint, HelloEventRef, HelloIr, HelloOp, HelloOpRef, PROTO, ProviderHello,
    };
    use cmux_pane_protocol::rpc::{NoHandler, Peer};
    use cmux_pane_protocol::{catalog, example, router, token, transport, ws};

    let link = match std::env::var("CMUX_PANE_ROUTER_SOCKET") {
        Ok(path) => transport::unix(tokio::net::UnixStream::connect(path).await?),
        Err(_) => router::connect_inherited()?,
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let provider = Arc::new(example::provider());
    let (peer, link_task) = Peer::start(link, Role::Connecting, Arc::new(NoHandler));
    let catalog = catalog::catalog();
    let declared = |name: &str| catalog.op_decl(name).cloned();
    let hello = ProviderHello {
        proto: PROTO.into(),
        app: example::APP_ID.into(),
        namespaces: vec![example::APP_ID.into()],
        ops: provider
            .op_names()
            .iter()
            .filter_map(|name| declared(name))
            .map(|op| HelloOpRef {
                name: op.name,
                kind: serde_json::to_value(op.kind)
                    .ok()
                    .and_then(|v| v.as_str().map(str::to_owned))
                    .unwrap_or_default(),
                scope: op.scope,
            })
            .collect(),
        events: vec![HelloEventRef {
            name: GreetTicks::NAME.into(),
            scope: GreetTicks::SCOPE.into(),
        }],
        interfaces: Vec::new(),
        ir: HelloIr {
            version: cmux_pane_protocol::ir::IR_VERSION.into(),
            sha256: catalog.digest(),
        },
        endpoints: vec![Endpoint::ws(format!("ws://127.0.0.1:{port}/"))],
        credential: std::env::var("CMUX_PANE_APP_CREDENTIAL").ok(),
    };
    let welcome =
        peer.call_op::<HelloOp>(&hello).await.map_err(|error| anyhow::anyhow!("{error}"))?;
    let key: [u8; 32] = URL_SAFE_NO_PAD
        .decode(&welcome.router_key)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("router public key is not 32 bytes"))?;
    let verifier = Arc::new(token::Verifier::new(key, welcome.provider));
    let mut policy = ListenerPolicy::loopback(port);
    for origin in std::env::var("CMUX_PANE_ALLOWED_ORIGINS").unwrap_or_default().split(',') {
        policy = policy.with_origin(origin);
    }
    // Data plane keeps serving if the router goes away; exit with the router
    // link only so a spawned provider does not outlive its parent.
    tokio::select! {
        () = ws::serve(listener, provider, verifier, policy) => {}
        _ = link_task => {}
    }
    Ok(())
}

#[cfg(not(unix))]
fn main() -> std::process::ExitCode {
    eprintln!("the example provider needs a unix router socket");
    std::process::ExitCode::from(2)
}
