//! In-place hot-patching of the daemon's Rust with Dioxus `subsecond`
//! (HQ#7149 R4): an edited function runs in the same daemon process, with
//! its terminals, sockets and state, on the next request, with no restart.
//!
//! Built only with the `hotpatch` cargo feature, which no shipped build
//! enables, and only patches when `subsecond` sees debug assertions. Run the
//! daemon under the Dioxus CLI (0.7.10), which builds it with the patchable
//! link, watches the workspace and sends each patch over a websocket:
//!
//! ```text
//! dx serve --hot-patch --interactive false --platform linux \
//!   -p cmux-tui --bin cmux-tui --features hotpatch -- --headless --socket S --state D
//! ```
//!
//! Every socket request runs through [`call`], so an edit anywhere below the
//! request dispatch (cmux-tui-core included, not only the binary's crate)
//! applies to the next request. Like `subsecond` itself: a change to a
//! struct's layout, a static or a thread-local needs a rebuild, and code a
//! thread is already running (a worker loop) keeps its old version until it
//! returns through a patched call.
//!
//! [`connect`] is this crate's version of `dioxus_devtools::connect_subsecond`
//! over the workspace's own tungstenite and serde_json, so the feature adds
//! `subsecond` alone instead of dioxus-core and its tree.

use std::io;

use serde::Deserialize;

/// The part of the Dioxus devserver's message this daemon reads
/// (`dioxus_devtools_types::DevserverMsg::HotReload`).
#[derive(Deserialize)]
enum DevserverMsg {
    HotReload(HotReloadMsg),
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct HotReloadMsg {
    jump_table: Option<subsecond::JumpTable>,
    for_pid: Option<u32>,
}

/// Connect to the `dx serve` devserver named by its environment
/// (`DIOXUS_DEVSERVER_IP`, `DIOXUS_DEVSERVER_PORT`) and apply each patch
/// built for this process. Does nothing when the daemon runs outside `dx`.
pub fn connect() {
    let (Ok(ip), Ok(port)) =
        (std::env::var("DIOXUS_DEVSERVER_IP"), std::env::var("DIOXUS_DEVSERVER_PORT"))
    else {
        return;
    };
    let build_id = std::env::var("DIOXUS_BUILD_ID").unwrap_or_else(|_| "0".into());
    let uri = format!(
        "ws://{ip}:{port}/_dioxus?aslr_reference={}&build_id={build_id}&pid={}",
        subsecond::aslr_reference(),
        std::process::id()
    );
    let spawned = std::thread::Builder::new().name("cmux-hotpatch".into()).spawn(move || {
        if let Err(error) = receive(&uri) {
            eprintln!("cmux-tui: hotpatch: devserver link ended: {error}");
        }
    });
    if let Err(error) = spawned {
        eprintln!("cmux-tui: hotpatch: could not start the devserver link: {error}");
    }
}

fn receive(uri: &str) -> io::Result<()> {
    let (mut socket, _) = tungstenite::connect(uri).map_err(io::Error::other)?;
    eprintln!("cmux-tui: hotpatch: connected to the devserver");
    loop {
        let tungstenite::Message::Text(text) = socket.read().map_err(io::Error::other)? else {
            continue;
        };
        let Ok(DevserverMsg::HotReload(message)) = serde_json::from_str(&text) else {
            continue;
        };
        let Some(table) = message.jump_table else {
            continue;
        };
        if message.for_pid != Some(std::process::id()) {
            continue;
        }
        // SAFETY: the table comes from the devserver that built this very
        // process (its pid and ASLR reference were sent on connect), which
        // is subsecond's contract for `apply_patch`.
        match unsafe { subsecond::apply_patch(table) } {
            Ok(()) => eprintln!("cmux-tui: hotpatch: applied a patch"),
            Err(error) => eprintln!("cmux-tui: hotpatch: patch refused: {error}"),
        }
    }
}

/// Run `f(args)` through the current jump table, so the newest patched
/// version of `f` and of everything it calls runs.
pub(crate) fn call<A, M, F>(f: F, args: A) -> anyhow::Result<F::Return>
where
    F: subsecond::HotFunction<A, M>,
{
    subsecond::HotFn::current(f)
        .try_call(args)
        .map_err(|_| anyhow::anyhow!("a hot patch replaced this request's caller; send it again"))
}
