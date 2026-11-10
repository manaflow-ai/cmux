//! The drill's event source over a stand-in carrier session: one daemon log behind both carriers, a session that
//! is on one carrier at a time, and a kill that moves it to the next, as the Cloud dial's own reconnect does.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::time::Instant;

use super::{SendPrompt, SessionRoutes};
use crate::carrier::drill::{EventRoutes, run_drill};
use crate::carrier::drill_dial::{CarrierSession, Lines};
use crate::carrier::fault::tests::{judged_after_kill, seqs};
use crate::carrier::fault::{FaultPlan, FaultSpec, Route};

pub(crate) const SURFACE: u64 = 7;

/// The turn's records as the machine's acpmux logged them: `last` of them, the last one its `turn_end`.
fn log(last: u64) -> Vec<Value> {
    (1..=last)
        .map(|seq| {
            let kind = if seq == last { "turn_end" } else { "agent_message_chunk" };
            json!({"seq": seq, "dir": "mux", "kind": kind})
        })
        .collect()
}

/// A stand-in carrier session over one daemon log.
pub(crate) struct FakeSession {
    log: Vec<Value>,
    route: Mutex<Option<Route>>,
    /// Records an attach page holds at most; the rest are pushed, from the page's last one again (the attach's own
    /// overlap: it subscribes before it reads the page).
    page: usize,
    /// Every attach the daemon answered: the carrier the session was on and its `after_seq`.
    pub(crate) attaches: Arc<Mutex<Vec<(Route, u64)>>>,
    pub(crate) kills: Mutex<Vec<Route>>,
    /// The stream's lines opened over each carrier, killed with it.
    streams: Mutex<Vec<(Route, tokio::sync::watch::Sender<bool>)>>,
}

impl FakeSession {
    pub(crate) fn new(last: u64, on: Route) -> Arc<Self> {
        Arc::new(Self {
            log: log(last),
            route: Mutex::new(Some(on)),
            page: 2,
            attaches: Arc::default(),
            kills: Mutex::default(),
            streams: Mutex::default(),
        })
    }

    /// The session moves to `route` by itself (its own reconnect), with no kill.
    pub(crate) fn move_to(&self, route: Route) {
        *self.route.lock().unwrap() = Some(route);
    }
}

#[async_trait]
impl CarrierSession for FakeSession {
    fn route(&self) -> Option<Route> {
        *self.route.lock().unwrap()
    }

    async fn lines(&self) -> Result<Lines, String> {
        let on = self.route().ok_or("no carrier")?;
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let (killed, mut dead) = tokio::sync::watch::channel(false);
        self.streams.lock().unwrap().push((on, killed));
        let (log, page, attaches) = (self.log.clone(), self.page, self.attaches.clone());
        let daemon = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(theirs);
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let request: Value = serde_json::from_str(&line).unwrap();
                let id = request["id"].clone();
                match request["cmd"].as_str() {
                    Some("identify") => {
                        let answer = json!({"id": id, "ok": true,
                                            "data": {"capabilities": ["agent-session-attach-v1"]}});
                        writer.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                    }
                    Some("agent-session-attach") => {
                        assert_eq!(request["surface"], SURFACE);
                        let after = request["after_seq"].as_u64().unwrap();
                        attaches.lock().unwrap().push((on, after));
                        let rest: Vec<&Value> =
                            log.iter().filter(|r| r["seq"].as_u64().unwrap() > after).collect();
                        let paged: Vec<&Value> = rest.iter().take(page).copied().collect();
                        let answer = json!({"id": id, "ok": true,
                                            "data": {"events": paged, "hasMore": false}});
                        writer.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                        // Live records, from the page's last one again, one at a time until the carrier dies.
                        for record in rest.iter().skip(page.saturating_sub(1)) {
                            tokio::time::sleep(Duration::from_millis(2)).await;
                            if *dead.borrow_and_update() {
                                return;
                            }
                            let push = json!({"event": "agent-session-record", "surface": SURFACE,
                                              "record": record});
                            if writer.write_all(format!("{push}\n").as_bytes()).await.is_err() {
                                return;
                            }
                        }
                    }
                    other => panic!("unexpected command {other:?}"),
                }
            }
        });
        let (reader, writer) = tokio::io::split(ours);
        Ok(Lines::new(
            Box::new(BufReader::new(reader)),
            Box::new(writer),
            Some(daemon.abort_handle()),
        ))
    }

    async fn kill(&self, route: Route) -> usize {
        self.kills.lock().unwrap().push(route);
        for (on, killed) in self.streams.lock().unwrap().iter() {
            if *on == route {
                killed.send_replace(true);
            }
        }
        let mut now = self.route.lock().unwrap();
        if *now == Some(route) {
            // The session's reconnect: on to the other carrier.
            *now = Some(if route == Route::Relay { Route::Ssh } else { Route::Relay });
        }
        1
    }
}

/// Routes over `session` whose prompt send counts its runs in `sent`, checking it runs only after an attach.
pub(crate) fn routes_over(session: &Arc<FakeSession>, sent: &Arc<AtomicUsize>) -> SessionRoutes {
    let dialed: Arc<dyn CarrierSession> = session.clone();
    let (attaches, sent) = (session.attaches.clone(), sent.clone());
    let send: SendPrompt = Box::new(move || {
        assert_eq!(
            attaches.lock().unwrap().len(),
            1,
            "the prompt goes once the stream is attached"
        );
        sent.fetch_add(1, Ordering::SeqCst);
        Ok(())
    });
    SessionRoutes::new(Box::new(move || Box::pin(async move { Ok(dialed) })), SURFACE, send)
}

fn plan(after_events: u32) -> FaultPlan {
    let caps = json!({"routes": ["relay", "ssh"], "faults": ["kill-route"]});
    FaultPlan::new(
        FaultSpec { kill: Route::Relay, after_events },
        vec![Route::Relay, Route::Ssh],
        &caps,
    )
    .unwrap()
}

fn caps() -> Value {
    json!({"routes": ["relay", "ssh"], "faults": ["kill-route"]})
}

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(30)
}

/// The first stream opens only on the carrier asked for: a session that came up over ssh is refused for a
/// relay stream, with no attach and no prompt sent.
#[tokio::test]
async fn the_stream_opens_on_the_chosen_carrier_only() {
    let sent = Arc::new(AtomicUsize::new(0));
    let on_ssh = FakeSession::new(5, Route::Ssh);
    let mut routes = routes_over(&on_ssh, &sent);
    let Err(refused) = routes.open(0, Route::Relay, None).await else {
        panic!("a relay stream opened on a session over ssh")
    };
    assert!(refused.contains("over ssh, not relay"), "{refused}");
    assert!(on_ssh.attaches.lock().unwrap().is_empty());
    assert_eq!(sent.load(Ordering::SeqCst), 0);

    let on_relay = FakeSession::new(5, Route::Relay);
    let mut routes = routes_over(&on_relay, &sent);
    let opened = routes.open(0, Route::Relay, None).await.unwrap();
    assert_eq!(*on_relay.attaches.lock().unwrap(), vec![(Route::Relay, 0)], "from the log's start");
    assert_eq!(opened.from_seq, Some(1), "the server's first record");
    assert_eq!(sent.load(Ordering::SeqCst), 1);
}

/// The kill is the session's own carrier kill: the session goes on over ssh, the next stream attaches there
/// after the client's last seq, and its from_seq is the first record the server sent there.
#[tokio::test]
async fn killing_the_relay_fails_over_to_ssh_and_resumes_from_the_server_s_seq() {
    let sent = Arc::new(AtomicUsize::new(0));
    let session = FakeSession::new(9, Route::Relay);
    let mut routes = routes_over(&session, &sent);
    let record = run_drill(&plan(4), &mut routes, caps(), deadline()).await.unwrap();
    assert_eq!(*session.kills.lock().unwrap(), vec![Route::Relay], "only the relay was killed");
    assert_eq!(
        *session.attaches.lock().unwrap(),
        vec![(Route::Relay, 0), (Route::Ssh, 4)],
        "one stream per carrier, the resume after the last seq the client had"
    );
    let resume = &record["resumes"][1];
    assert_eq!((resume["route"].as_str(), resume["phase"].as_str()), (Some("ssh"), Some("resume")));
    assert_eq!((resume["after_seq"].as_u64(), resume["from_seq"].as_u64()), (Some(4), Some(5)));
    assert_eq!(judged_after_kill(&record), vec!["ssh"; 5]);
    assert_eq!(seqs(&record), (1..=9).collect::<Vec<_>>(), "nothing lost or repeated");
    assert_eq!(sent.load(Ordering::SeqCst), 1, "one prompt");
}

/// A session that moved to ssh by itself before the kill ends the relay stream: its records are never labeled
/// the relay's.
#[tokio::test]
async fn a_session_that_moves_carrier_before_the_kill_ends_the_stream() {
    let sent = Arc::new(AtomicUsize::new(0));
    let session = FakeSession::new(9, Route::Relay);
    let mut routes = routes_over(&session, &sent);
    let mut opened = routes.open(0, Route::Relay, None).await.unwrap();
    assert_eq!(opened.stream.next().await.unwrap().unwrap().seq, 1);
    session.move_to(Route::Ssh);
    let moved = opened.stream.next().await.unwrap().unwrap_err();
    assert!(moved.contains("on ssh, not relay"), "{moved}");
}
