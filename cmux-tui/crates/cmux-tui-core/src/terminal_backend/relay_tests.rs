//! p05-ipc-150: a relay's pumps carry the person's daemon connection for a
//! far session, so they run at the echo path class while they serve; its
//! accept thread runs at the request class. Each check reads the running
//! thread's live class through the thread registry (`pthread_get_qos_class_np`
//! on macOS, the nice value on Linux).

use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_threads::{ThreadInfo, ThreadQos};

use super::{ACCEPT_QOS, ClientGone, Emit, PUMP_QOS, RelaySet};
use crate::terminal_backend::links::LinkMeta;
use crate::terminal_backend::{BackendId, LinkRegistry, LocalId};

/// The registered threads named `name`, once at least one runs.
fn running(name: &str) -> Vec<ThreadInfo> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let rows: Vec<_> =
            cmux_threads::snapshot().into_iter().filter(|row| row.name == name).collect();
        if !rows.is_empty() || Instant::now() >= deadline {
            return rows;
        }
        std::thread::yield_now();
    }
}

/// Every running `name` thread declared `class` and runs at it: the class
/// itself where this process can reach it, else the test thread's own
/// (a thread starts at its creator's class or nice).
fn assert_runs_at(name: &str, class: ThreadQos) {
    let rows = running(name);
    assert!(!rows.is_empty(), "{name} runs while the relay serves its client");
    let live = if cmux_threads::reachable(class) {
        crate::request_qos::tests::live_at(class)
    } else {
        cmux_threads::current()
    };
    for row in rows {
        assert_eq!((row.declared, row.live), (class, live), "{name}");
    }
}

#[test]
fn the_pumps_of_a_relayed_connection_run_at_the_echo_path_class() {
    assert_eq!(PUMP_QOS, ThreadQos::UserInteractive);
    let links = Arc::new(LinkRegistry::default());
    let meta = LinkMeta {
        id: BackendId::app("cmux/ssh", &LocalId::new("ssh").unwrap()),
        target: "relay-qos".to_owned(),
    };
    let channel = links.channels().insert("cmux/ssh", meta, 64 * 1024, false);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("crq-{}-{stamp}", std::process::id()));
    let relays = RelaySet::default();
    let emit: Emit = Arc::new(|_frame| {});
    let gone: ClientGone = Arc::new(|_channel| {});
    let socket = relays.start(&dir, &links, &channel, emit, gone).expect("the relay starts");

    let client = UnixStream::connect(&socket).expect("the relay accepts its client");
    assert_runs_at("cmux-link-accept", ACCEPT_QOS);
    assert_runs_at("cmux-link-in", PUMP_QOS);
    assert_runs_at("cmux-link-out", PUMP_QOS);

    relays.stop(&channel);
    let _ = links.close(&channel);
    drop(client);
    let _ = std::fs::remove_dir_all(&dir);
}
