//! A local webhook end to end: the runner's listener on loopback, a signed
//! POST over TCP, the event through the watches' queue, a run started.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_automations::watch::Watches;
use cmux_automations::webhook::{self, Server, WebhookFilter};
use cmux_automations::{
    AutomationSpec, Body, EventOutcome, Executor, Job, Store, Trigger, start_event,
};

fn temp_root(tag: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-automations-webhook-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[derive(Default)]
struct Recorder {
    started: Vec<Job>,
}

impl Executor for Recorder {
    fn start(&mut self, job: &Job) -> Result<u32, String> {
        self.started.push(job.clone());
        Ok(4_000_000 + self.started.len() as u32)
    }
    fn is_alive(&self, _pid: u32) -> bool {
        false
    }
}

#[test]
fn a_signed_delivery_over_loopback_starts_one_run() {
    let root = temp_root("e2e");
    let store = Store::open(&root).unwrap();
    let a = store
        .create(
            AutomationSpec {
                name: "on-push".into(),
                trigger: Trigger::Webhook {
                    filters: vec![WebhookFilter::parse_json("ref=refs/heads/main").unwrap()],
                    dedupe_seconds: 600,
                },
                body: Body::Command { command: "true".into(), folder: None },
                catch_up: Default::default(),
                timeout_seconds: 60,
                enabled: true,
                gate: Default::default(),
            },
            0,
        )
        .unwrap();
    assert!(webhook::wanted(&store.list().unwrap()));
    let secret = store.webhook_secret(&a.id).unwrap();
    let mut watches = Watches::new(store.clone());
    let server = Server::start(store.clone(), "127.0.0.1:0", watches.sender()).unwrap();
    let addr = server.addr().to_string();
    assert!(server.addr().ip().is_loopback());
    assert_eq!(store.webhook_listener().unwrap().addr, addr);

    let delivery = [("X-GitHub-Delivery".to_string(), "g-1".to_string())];
    let body = br#"{"ref":"refs/heads/main","after":"abc"}"#;
    let (status, answer) = webhook::send(&addr, &a.id, &secret, body, &delivery).unwrap();
    assert_eq!((status, answer.get("status").and_then(|s| s.as_str())), (202, Some("accepted")));
    let (status, answer) = webhook::send(&addr, &a.id, &secret, body, &delivery).unwrap();
    assert_eq!((status, answer.get("status").and_then(|s| s.as_str())), (200, Some("duplicate")));
    let (status, _) = webhook::send(&addr, &a.id, "not-the-secret", body, &[]).unwrap();
    assert_eq!(status, 401);
    let (status, answer) =
        webhook::send(&addr, &a.id, &secret, br#"{"ref":"refs/heads/dev"}"#, &[]).unwrap();
    assert_eq!((status, answer.get("status").and_then(|s| s.as_str())), (200, Some("ignored")));

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut events = Vec::new();
    while events.is_empty() && Instant::now() < deadline {
        watches.wait(Duration::from_millis(200), &|| 0);
        events = watches.due_events(0);
    }
    assert_eq!(events.len(), 1, "one accepted delivery, one event");
    let mut exec = Recorder::default();
    let e = events.first().unwrap();
    let outcome = start_event(&store, &e.automation, &e.text, &e.key, 10, &mut exec).unwrap();
    let EventOutcome::Started(run) = outcome else { panic!("not started: {outcome:?}") };
    let row = store.run(&a.id, &run).unwrap().unwrap();
    assert_eq!(row.trigger, "webhook");
    assert!(row.event.as_deref().unwrap().contains("\"after\":\"abc\""));
    assert_eq!(exec.started.len(), 1);
    drop(server);
    let _ = std::fs::remove_dir_all(&root);
}
