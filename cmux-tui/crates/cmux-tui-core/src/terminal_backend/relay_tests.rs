//! p05-ipc-150: a relay's accept thread and both pumps run at the request
//! class while they serve. Each check reads the running thread's live class
//! through the thread registry (`pthread_get_qos_class_np` on macOS, the nice
//! value on Linux).

use std::os::unix::net::UnixStream;
use std::sync::Arc;

use cmux_threads::ThreadQos;

use super::{ACCEPT_QOS, ClientGone, Emit, PUMP_QOS, RelaySet};
use crate::terminal_backend::links::LinkMeta;
use crate::terminal_backend::{BackendId, LinkRegistry, LocalId};

/// The registry ids of the running relay threads.
fn relay_threads() -> Vec<Option<u64>> {
    cmux_threads::snapshot()
        .into_iter()
        .filter(|row| row.name.starts_with("cmux-link-"))
        .map(|row| row.tid)
        .collect()
}

/// Every `name` thread not in `before` declared `class` and rests at it:
/// a thread is listed before its body sets its class, so this waits
/// (bounded) until its applied and live class agree with `class`.
fn assert_runs_at(name: &str, before: &[Option<u64>], class: ThreadQos) {
    for row in crate::thread_qos::tests::new_rows_at_rest(name, before, class) {
        assert_eq!(row.declared, class, "{name}");
    }
}

#[test]
fn the_threads_of_a_relayed_connection_run_at_the_request_class() {
    assert_eq!((ACCEPT_QOS, PUMP_QOS), (ThreadQos::UserInitiated, ThreadQos::UserInitiated));
    let before = relay_threads();
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
    assert_runs_at("cmux-link-accept", &before, ACCEPT_QOS);
    assert_runs_at("cmux-link-in", &before, PUMP_QOS);
    assert_runs_at("cmux-link-out", &before, PUMP_QOS);

    relays.stop(&channel);
    let _ = links.close(&channel);
    drop(client);
    let _ = std::fs::remove_dir_all(&dir);
}
