//! Panic injection for a session's event pump: its end runs on an unwind too, so the
//! Cloud still hears the session ended.

use std::time::Duration;

use super::*;

#[tokio::test]
async fn a_pump_that_panics_still_ends_its_session() {
    let (sink, mut frames) = mpsc::channel(4);
    let agents = Agents::default();
    crate::supervised::spawn_scoped(async move {
        let _end = PumpEnd { agents, session: "s1".to_owned(), sink, route: None };
        panic!("injected in the pump");
    });
    let frame = tokio::time::timeout(Duration::from_secs(5), frames.recv())
        .await
        .expect("a frame within 5 s")
        .expect("the session's end");
    assert_eq!(frame["session"], "s1");
    assert_eq!(frame["event"]["kind"], "session_end");
    assert_eq!(frame["event"]["reason"], "daemon_gone");
}
