//! The owner's Auto mode client against the fake server: the route, body and headers each call
//! sends, the answer it reads, and how a refusal reads.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
use cmux_auto_session::wire::{
    ErrorCode, EventsAppend, Fence, Holder, InboxAck, InboxPost, LeaseRequest, MachineSetting,
    MoveRefusal, MoveRequest, MoveTo, MoveWish, PutRequest, Role, SeqRecord, State,
};
use serde_json::{Value, json};

use super::{Reply, Seen, fake, ok};
use crate::auto_sessions::{OwnerAutoCloud, OwnerSignIn, SignedIn};

const CHAT: &str = "ses_1.a:b-c";

fn signed_in(origin: &str) -> SignedIn {
    SignedIn { api: origin.to_owned(), credential: "access".into(), team: Some("team-1".into()) }
}

fn cloud(origin: &str) -> OwnerAutoCloud<SignedIn> {
    OwnerAutoCloud::new(signed_in(origin))
}

fn run<T>(future: impl Future<Output = T>) -> T {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(future)
}

/// The store's view of a chat this laptop holds at `epoch`.
fn session(epoch: u64) -> Value {
    json!({
        "id": CHAT, "title": "Fix the build", "harness": "claude", "team": "team-1", "owner": "u1",
        "auto": true, "keepInCloud": false, "holder": "device:mac-1", "epoch": epoch,
        "state": "local", "blocked": null, "needsRun": true, "standby": [],
        "lastSeq": 7, "snapshot": 2, "inbox": 3, "inboxAcked": 1, "repo": null,
        "version": 9, "createdAt": 1, "updatedAt": 2, "leaseExpiresAt": 3,
    })
}

fn answers(body: Value) -> impl Fn(&Seen) -> Reply + Send + Sync + 'static {
    move |_| ok(&body.to_string())
}

#[test]
fn a_renewal_posts_the_lease_and_reads_the_role() {
    let (origin, seen) =
        fake(answers(json!({ "session": session(4), "role": "holder", "leaseMs": 45_000 })));
    let request =
        LeaseRequest { holder: Holder::device("mac-1"), epoch: 4, needs_run: true, standby: None };
    let answer = run(cloud(&origin).lease(CHAT, &request)).unwrap();
    assert_eq!(answer.role, Role::Holder);
    assert_eq!(answer.lease_ms, 45_000);
    assert_eq!(answer.session.epoch, 4);
    assert_eq!(answer.session.state, State::Local);
    assert!(answer.session.inbox_pending());

    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].target(), format!("POST /v1/auto-sessions/{CHAT}/lease"));
    assert_eq!(seen[0].json(), json!({ "holder": "device:mac-1", "epoch": 4, "needsRun": true }));
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team-1"));
}

#[test]
fn a_standby_renewal_says_so() {
    let (origin, seen) =
        fake(answers(json!({ "session": session(4), "role": "standby", "leaseMs": 45_000 })));
    let request = LeaseRequest {
        holder: Holder::device("mac-1"),
        epoch: 3,
        needs_run: false,
        standby: Some(true),
    };
    assert_eq!(run(cloud(&origin).lease(CHAT, &request)).unwrap().role, Role::Standby);
    assert_eq!(
        seen.lock().unwrap()[0].json(),
        json!({ "holder": "device:mac-1", "epoch": 3, "needsRun": false, "standby": true })
    );
}

#[test]
fn switching_auto_on_puts_the_chat_and_reads_its_session() {
    let (origin, seen) = fake(answers(json!({ "session": session(1) })));
    let request = PutRequest {
        auto: true,
        title: "Fix the build".into(),
        harness: "claude".into(),
        device: "mac-1".into(),
        keep_in_cloud: None,
        repo: None,
    };
    let view = run(cloud(&origin).put(CHAT, &request)).unwrap();
    assert_eq!(view.holder, Holder::device("mac-1"));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("PUT /v1/auto-sessions/{CHAT}"));
    assert_eq!(
        seen[0].json(),
        json!({ "auto": true, "title": "Fix the build", "harness": "claude", "device": "mac-1" })
    );
}

#[test]
fn a_gap_in_the_events_reads_the_stores_last_seq_and_chat() {
    let refusal = json!({
        "error": { "code": "auto.seq_gap", "message": "the next event is 8" },
        "lastSeq": 7, "session": session(4),
    });
    let (origin, seen) = fake(move |_| Some((409, refusal.to_string())));
    let request = EventsAppend {
        holder: Holder::device("mac-1"),
        epoch: 4,
        events: vec![SeqRecord { seq: 12, record: json!({ "type": "user", "text": "hi" }) }],
    };
    let error = run(cloud(&origin).append_events(CHAT, &request)).unwrap_err();
    assert_eq!(error.code(), Some(ErrorCode::SeqGap));
    assert_eq!(error.status(), Some(409));
    assert_eq!(error.last_seq(), Some(7));
    assert_eq!(error.session().map(|s| s.epoch), Some(4));
    assert!(!error.retryable());
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("POST /v1/auto-sessions/{CHAT}/events"));
    assert_eq!(seen[0].json()["events"][0]["seq"], json!(12));
}

#[test]
fn events_are_appended_and_read_in_pages() {
    let (origin, seen) = fake(|seen: &Seen| {
        if seen.line.starts_with("POST") {
            ok(r#"{"lastSeq":2}"#)
        } else {
            ok(r#"{"events":[{"seq":2,"record":{"type":"agent"}}],"lastSeq":2}"#)
        }
    });
    let cloud = cloud(&origin);
    let request = EventsAppend {
        holder: Holder::device("mac-1"),
        epoch: 1,
        events: vec![SeqRecord { seq: 1, record: json!({}) }],
    };
    // One runtime for both calls: the client's connections belong to it.
    let (appended, page) = run(async {
        (cloud.append_events(CHAT, &request).await, cloud.events(CHAT, 1, Some(64)).await)
    });
    assert_eq!(appended.unwrap(), 2);
    let page = page.unwrap();
    assert_eq!(page.last_seq, 2);
    assert_eq!(page.events[0].record, json!({ "type": "agent" }));
    assert_eq!(
        seen.lock().unwrap()[1].target(),
        format!("GET /v1/auto-sessions/{CHAT}/events?after=1&limit=64")
    );
}

#[test]
fn a_chunk_goes_up_as_bytes_that_name_their_writer() {
    let (origin, seen) = fake(|_| Some((204, String::new())));
    let bytes = b"a chunk of the folder";
    let name = cmux_auto_session::chunks::name_of(bytes);
    let fence = Fence::new(Holder::device("mac-1"), 6);
    run(cloud(&origin).put_chunk(CHAT, &name, bytes, &fence)).unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("PUT /v1/auto-sessions/{CHAT}/chunks/{name}"));
    assert_eq!(seen[0].body, bytes);
    assert_eq!(seen[0].header("x-cmux-auto-holder").as_deref(), Some("device:mac-1"));
    assert_eq!(seen[0].header("x-cmux-auto-epoch").as_deref(), Some("6"));
    assert_eq!(seen[0].header("content-type").as_deref(), Some("application/octet-stream"));
}

#[test]
fn a_chunk_comes_down_as_its_bytes() {
    let (origin, seen) = fake(|_| ok("the bytes"));
    let name = "ab".repeat(32);
    assert_eq!(run(cloud(&origin).chunk(CHAT, &name)).unwrap(), b"the bytes");
    assert_eq!(
        seen.lock().unwrap()[0].target(),
        format!("GET /v1/auto-sessions/{CHAT}/chunks/{name}")
    );
}

#[test]
fn a_missing_snapshot_is_its_own_refusal() {
    let (origin, _seen) = fake(|_| {
        Some((404, r#"{"error":{"code":"auto.no_snapshot","message":"no snapshot yet"}}"#.into()))
    });
    let error = run(cloud(&origin).snapshot(CHAT)).unwrap_err();
    assert_eq!(error.code(), Some(ErrorCode::NoSnapshot));
}

#[test]
fn the_inbox_is_sent_to_read_after_a_number_and_acked() {
    let (origin, seen) = fake(|seen: &Seen| match seen.target().as_str() {
        t if t.ends_with("/inbox?after=1") => {
            ok(r#"{"messages":[{"n":2,"id":"m2","text":"and the tests","at":5}]}"#)
        }
        t if t.ends_with("/inbox/ack") => ok(&json!({ "session": session(4) }).to_string()),
        _ => ok(&json!({ "state": "resuming", "session": session(4) }).to_string()),
    });
    let cloud = cloud(&origin);
    let message = InboxPost { id: "m2".into(), text: "and the tests".into() };
    let ack = InboxAck { holder: Holder::device("mac-1"), epoch: 4, through: 2 };
    let (posted, messages, acked) = run(async {
        (
            cloud.post_inbox(CHAT, &message).await,
            cloud.inbox(CHAT, 1).await,
            cloud.ack_inbox(CHAT, &ack).await,
        )
    });
    assert_eq!(posted.unwrap().state.as_str(), "resuming");
    let messages = messages.unwrap();
    assert_eq!((messages[0].n, messages[0].id.as_str()), (2, "m2"));
    assert_eq!(acked.unwrap().epoch, 4);
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("POST /v1/auto-sessions/{CHAT}/inbox"));
    assert_eq!(seen[2].target(), format!("POST /v1/auto-sessions/{CHAT}/inbox/ack"));
    assert_eq!(seen[2].json(), json!({ "holder": "device:mac-1", "epoch": 4, "through": 2 }));
}

#[test]
fn a_wait_is_held_no_longer_than_the_store_holds_it() {
    let (origin, seen) = fake(answers(json!({ "session": session(4) })));
    let view = run(cloud(&origin).wait(CHAT, 9, 600_000)).unwrap();
    assert_eq!(view.version, 9);
    assert_eq!(
        seen.lock().unwrap()[0].target(),
        format!("GET /v1/auto-sessions/{CHAT}/wait?after=9&timeoutMs=25000")
    );
}

#[test]
fn a_move_posts_where_to_and_reads_the_wish_and_a_renewal_reads_it_too() {
    let mut moving = session(4);
    moving["keepInCloud"] = json!(true);
    moving["move"] = json!({ "to": "cloud", "at": 12 });
    let moved = json!({ "session": moving });
    let renewed = json!({
        "session": moved["session"], "role": "holder", "leaseMs": 45_000, "move": "cloud",
    });
    let (origin, seen) = fake(move |seen: &Seen| match seen.target().as_str() {
        t if t.ends_with("/lease") => ok(&renewed.to_string()),
        _ => ok(&moved.to_string()),
    });
    let cloud = cloud(&origin);
    let laptop = MoveRequest::laptop(Holder::device("mac-2"));
    let request =
        LeaseRequest { holder: Holder::device("mac-1"), epoch: 4, needs_run: true, standby: None };
    let (to_cloud, to_laptop, lease) = run(async {
        (
            cloud.move_(CHAT, &MoveRequest::cloud()).await,
            cloud.move_(CHAT, &laptop).await,
            cloud.lease(CHAT, &request).await,
        )
    });
    let view = to_cloud.unwrap();
    assert!(view.keep_in_cloud);
    assert_eq!(view.moving, Some(MoveWish { to: MoveTo::Cloud, device: None, at: 12 }));
    assert!(to_laptop.is_ok());
    assert_eq!(lease.unwrap().move_to, Some(MoveTo::Cloud));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("POST /v1/auto-sessions/{CHAT}/move"));
    assert_eq!(seen[0].json(), json!({ "to": "cloud" }));
    assert_eq!(seen[1].json(), json!({ "to": "local", "device": "device:mac-2" }));
}

#[test]
fn a_give_posts_the_fence_and_a_copy_that_is_behind_is_its_own_refusal() {
    let refusal = json!({
        "error": { "code": "auto.not_copied", "message": "the Cloud copy is behind the chat" },
        "session": session(4),
    });
    let given = AtomicBool::new(false);
    let (origin, seen) = fake(move |_| {
        if given.swap(true, Ordering::SeqCst) {
            let mut taken = session(5);
            taken["holder"] = json!("vm:vm_1");
            return ok(&json!({ "session": taken }).to_string());
        }
        Some((409, refusal.to_string()))
    });
    let cloud = cloud(&origin);
    let fence = Fence::new(Holder::device("mac-1"), 4);
    let (first, second) =
        run(async { (cloud.give(CHAT, &fence).await, cloud.give(CHAT, &fence).await) });
    let error = first.unwrap_err();
    assert_eq!(error.move_refusal(), Some(MoveRefusal::NotCopied));
    assert_eq!((error.status(), error.code()), (Some(409), None));
    assert_eq!(error.session().map(|s| s.epoch), Some(4));
    assert!(!error.retryable());
    let view = second.unwrap();
    assert_eq!((view.holder, view.epoch, view.moving), (Holder::vm("vm_1"), 5, None));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("POST /v1/auto-sessions/{CHAT}/give"));
    assert_eq!(seen[0].json(), json!({ "holder": "device:mac-1", "epoch": 4 }));
}

#[test]
fn the_list_and_the_auto_machine_are_the_owners() {
    let (origin, seen) = fake(|seen: &Seen| {
        if seen.target().contains("/machine") {
            if seen.line.starts_with("GET") {
                return Some((
                    404,
                    r#"{"error":{"code":"auto.no_machine","message":"no Auto machine is set"}}"#
                        .into(),
                ));
            }
            return ok(r#"{"team":"team-1","machine":"vm_abcdefghij0123456789"}"#);
        }
        ok(&json!({ "sessions": [session(1)], "nextCursor": "next" }).to_string())
    });
    let cloud = cloud(&origin);
    let setting =
        MachineSetting { team: "team-1".into(), machine: "vm_abcdefghij0123456789".into() };
    let (page, machine, set) = run(async {
        (
            cloud.list(Some(50), Some("c1")).await,
            cloud.machine().await,
            cloud.set_machine(&setting).await,
        )
    });
    let page = page.unwrap();
    assert_eq!(page.sessions.len(), 1);
    assert_eq!(page.next_cursor.as_deref(), Some("next"));
    assert_eq!(machine.unwrap_err().code(), Some(ErrorCode::NoMachine));
    assert_eq!(set.unwrap(), setting);
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "GET /v1/auto-sessions?limit=50&cursor=c1");
    assert_eq!(seen[1].target(), "GET /v1/auto-sessions/machine");
    assert_eq!(seen[2].target(), "PUT /v1/auto-sessions/machine");
}

#[test]
fn a_name_that_is_no_chat_or_chunk_sends_nothing() {
    let (origin, seen) = fake(answers(json!({ "session": session(1) })));
    let cloud = cloud(&origin);
    for id in ["", "a/b", "machine", "assignments", "a b", "../x"] {
        assert_eq!(run(cloud.get(id)).unwrap_err().status(), Some(400), "{id:?}");
    }
    assert_eq!(run(cloud.chunk(CHAT, "../../machine")).unwrap_err().status(), Some(400));
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn a_store_that_does_not_answer_is_a_call_to_try_again() {
    // Nothing listens here.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let error = run(cloud(&format!("http://127.0.0.1:{port}")).get(CHAT)).unwrap_err();
    assert!(error.is_transport(), "{error}");
    assert!(error.retryable());
    // A 5xx with no code is the same to the caller.
    let (origin, _seen) = fake(|_| Some((503, "upstream".into())));
    let error = run(cloud(&origin).get(CHAT)).unwrap_err();
    assert!(matches!(error, AutoCloudError::Http { status: 503, .. }));
    assert!(error.retryable());
}

/// A sign-in the test can take away, which records what the store refused.
struct Lent {
    origin: String,
    signed_out: AtomicBool,
    refused: Mutex<Vec<String>>,
}

impl OwnerSignIn for &Lent {
    async fn sign_in(&self) -> Result<SignedIn, String> {
        if self.signed_out.load(Ordering::SeqCst) {
            return Err("Not signed in to cmux".to_owned());
        }
        Ok(signed_in(&self.origin))
    }

    fn refused(&self, credential: &str) {
        self.refused.lock().unwrap().push(credential.to_owned());
    }
}

#[test]
fn no_sign_in_sends_nothing_and_a_refused_one_is_reported() {
    let (origin, seen) = fake(|_| {
        Some((401, r#"{"error":{"code":"auth.unauthenticated","message":"expired"}}"#.into()))
    });
    let lent = Lent { origin, signed_out: AtomicBool::new(true), refused: Mutex::new(Vec::new()) };
    let cloud = OwnerAutoCloud::new(&lent);
    run(async {
        let error = cloud.get(CHAT).await.unwrap_err();
        assert!(error.is_transport(), "{error}");
        assert!(seen.lock().unwrap().is_empty());

        lent.signed_out.store(false, Ordering::SeqCst);
        let error = cloud.get(CHAT).await.unwrap_err();
        assert_eq!(error.status(), Some(401));
        assert_eq!(*lent.refused.lock().unwrap(), ["access"]);
    });
}
