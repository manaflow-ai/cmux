//! `sign_in_follow.rs`'s tests: what the app's `CloudSignInEnroll` decided before (its
//! `CloudSignInEnrollLeaveRetryTests`), now decided here.
use super::*;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicUsize, Ordering};

/// The join as a change sees it: every call, in order, and what an enroll answers.
#[derive(Default)]
struct Fake {
    calls: StdMutex<Vec<String>>,
    /// The account each leave named (None: none).
    leaves: StdMutex<Vec<Option<String>>>,
    /// Enrolls that answer `Unavailable` before the rest answer `AlreadyJoined`.
    unavailable: AtomicUsize,
}

impl Fake {
    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
    fn leaves(&self) -> Vec<Option<String>> {
        self.leaves.lock().unwrap().clone()
    }
    fn enrolls(&self) -> usize {
        self.calls().iter().filter(|call| call.starts_with("enroll:")).count()
    }
}

impl Port for Fake {
    fn record(&self, account: String) -> Boxed<'_, bool> {
        self.calls.lock().unwrap().push(format!("record:{account}"));
        Box::pin(async { true })
    }
    fn leave(&self, account: Option<String>) -> Boxed<'_, ()> {
        self.calls.lock().unwrap().push("leave".to_owned());
        self.leaves.lock().unwrap().push(account);
        Box::pin(async {})
    }
    fn enroll(&self, user: String, _access: Zeroizing<String>) -> Boxed<'_, EnrollOutcome> {
        self.calls.lock().unwrap().push(format!("enroll:{user}"));
        let unavailable = self
            .unavailable
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
            .is_ok();
        Box::pin(async move {
            if unavailable { EnrollOutcome::Unavailable } else { EnrollOutcome::AlreadyJoined }
        })
    }
}

/// The tests' owner: the runtime ends what is left of it with the test.
fn scope() -> &'static cmux_scope::Scope {
    Box::leak(Box::new(cmux_scope::Scope::new("sign-in follow test")))
}

/// A wait no test outlives: only a change ends it.
const LONG: Duration = Duration::from_secs(3600);

fn signed_in(user: &str) -> Change {
    Change {
        user_id: Some(user.to_owned()),
        previous: None,
        access: Some(Zeroizing::new("access".to_owned())),
    }
}

fn signed_out(previous: Option<&str>) -> Change {
    Change { user_id: None, previous: previous.map(str::to_owned), access: None }
}

async fn change(follow: &Arc<Follow>, fake: &Arc<Fake>, change: Change) -> Accepted {
    let port: Arc<dyn Port> = Arc::clone(fake) as Arc<dyn Port>;
    follow.change(scope(), port, change).await
}

/// Waits (bounded) until `done` holds, letting the follow's tasks run.
async fn until(what: &str, done: impl Fn() -> bool) {
    tokio::time::timeout(Duration::from_secs(30), async {
        while !done() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{what} did not happen"));
}

/// Swift's aSignOutDuringAnEnrollsRetryWaitRecordsTheAccountAtOnce: the enroll got no join and
/// waits to retry; a sign-out meanwhile records the account before its reply, never behind that
/// wait, and the wait ends: the leave follows, and the retry never goes.
#[tokio::test]
async fn a_sign_out_during_an_enrolls_retry_wait_records_the_account_at_once() {
    let follow = Arc::new(Follow::new(LONG));
    let fake = Arc::new(Fake::default());
    fake.unavailable.store(1, Ordering::SeqCst);
    change(&follow, &fake, signed_in("user_a")).await;
    until("the first enroll", || fake.enrolls() == 1).await;
    let accepted = change(&follow, &fake, signed_out(None)).await;
    assert_eq!(accepted.recorded, Some(true));
    assert_eq!(fake.calls()[..2], ["enroll:user_a".to_owned(), "record:user_a".to_owned()]);
    follow.settled().await;
    assert_eq!(fake.calls(), ["enroll:user_a", "record:user_a", "leave"]);
    assert_eq!(fake.leaves(), [Some("user_a".to_owned())]);
}

/// Swift's anAccountSwitchRecordsTheLastAccountAtOnce: switched while the enroll waits to retry,
/// the last account is recorded at once, then its leave and the next person's enroll follow.
#[tokio::test]
async fn an_account_switch_records_the_last_account_at_once() {
    let follow = Arc::new(Follow::new(LONG));
    let fake = Arc::new(Fake::default());
    fake.unavailable.store(1, Ordering::SeqCst);
    change(&follow, &fake, signed_in("user_a")).await;
    until("the first enroll", || fake.enrolls() == 1).await;
    let accepted = change(&follow, &fake, signed_in("user_b")).await;
    assert_eq!(accepted, Accepted { recorded: Some(true), leave: true, enroll: true });
    assert_eq!(fake.calls().last().map(String::as_str), Some("record:user_a"));
    follow.settled().await;
    assert_eq!(fake.calls(), ["enroll:user_a", "record:user_a", "leave", "enroll:user_b"]);
}

/// An enroll the hub did not answer goes once more after the wait while the person is still
/// signed in; anything else, or a second miss, is final.
#[tokio::test]
async fn an_unanswered_enroll_is_retried_once() {
    let follow = Arc::new(Follow::new(Duration::ZERO));
    let fake = Arc::new(Fake::default());
    fake.unavailable.store(5, Ordering::SeqCst);
    change(&follow, &fake, signed_in("user_a")).await;
    follow.settled().await;
    assert_eq!(fake.calls(), ["enroll:user_a", "enroll:user_a"]);
    let follow = Arc::new(Follow::new(Duration::ZERO));
    let fake = Arc::new(Fake::default());
    change(&follow, &fake, signed_in("user_a")).await;
    follow.settled().await;
    assert_eq!(fake.calls(), ["enroll:user_a"], "an answered enroll is final");
}

/// Swift's theSigningOutAccountIsRecordedBeforeTheLeaveAndResentFromIt and
/// eachLeaveNamesTheAccountSigningOutAndOnlyThatOne: every leave names the account signing out,
/// recorded first; signed out with no account known names none and records nothing.
#[tokio::test]
async fn each_leave_names_the_account_signing_out_recorded_first() {
    let follow = Arc::new(Follow::new(LONG));
    let fake = Arc::new(Fake::default());
    // The first change, signed out, with no account known: the leave names none.
    let accepted = change(&follow, &fake, signed_out(None)).await;
    assert_eq!(accepted, Accepted { recorded: None, leave: true, enroll: false });
    change(&follow, &fake, signed_in("user_a")).await;
    change(&follow, &fake, signed_out(Some("user_a"))).await;
    change(&follow, &fake, signed_in("user_a")).await;
    change(&follow, &fake, signed_in("user_b")).await;
    change(&follow, &fake, signed_out(Some("user_b"))).await;
    follow.settled().await;
    assert_eq!(
        fake.leaves(),
        [None, Some("user_a".to_owned()), Some("user_a".to_owned()), Some("user_b".to_owned())]
    );
    let calls = fake.calls();
    for account in ["user_a", "user_b"] {
        let recorded = calls.iter().position(|c| *c == format!("record:{account}")).unwrap();
        let left = calls.iter().skip(recorded).position(|c| c == "leave");
        assert!(left.is_some(), "{account} is recorded before its leave: {calls:?}");
    }
}

/// Swift's aLeaveWithNoReplyIsSentAgainWhenAcpmuxComesBack: a sign-out this daemon never took
/// (it was restarting) comes again from the app, and the restarted daemon leaves as the account
/// the app names, recorded first.
#[tokio::test]
async fn a_restarted_daemon_leaves_as_the_account_the_resent_sign_out_names() {
    let follow = Arc::new(Follow::new(LONG));
    let fake = Arc::new(Fake::default());
    let accepted = change(&follow, &fake, signed_out(Some("user_a"))).await;
    assert_eq!(accepted, Accepted { recorded: Some(true), leave: true, enroll: false });
    follow.settled().await;
    assert_eq!(fake.calls(), ["record:user_a", "leave"]);
    assert_eq!(fake.leaves(), [Some("user_a".to_owned())]);
}

/// Swift's anAccountSwitchWhoseLeaveGotNoReplyNeverSendsThatLeaveWhileTheNextPersonIsIn: a
/// restarted daemon told B is in (A before) records A but sends no leave, which would leave B's
/// own join; B's enroll finishes A's sign-in join's leave itself (`enroll.rs`).
#[tokio::test]
async fn a_restarted_daemon_told_the_next_person_is_in_only_enrolls() {
    let follow = Arc::new(Follow::new(LONG));
    let fake = Arc::new(Fake::default());
    let change_b = Change { previous: Some("user_a".to_owned()), ..signed_in("user_b") };
    let accepted = change(&follow, &fake, change_b).await;
    assert_eq!(accepted, Accepted { recorded: Some(true), leave: false, enroll: true });
    follow.settled().await;
    assert_eq!(fake.calls(), ["record:user_a", "enroll:user_b"]);
}

/// Swift's aReturnWithNoLeavePendingSendsNothing and aSignInDropsTheLeaveNotAnswered: the same
/// person again (a resend this daemon already took) changes nothing.
#[tokio::test]
async fn the_same_person_again_changes_nothing() {
    let follow = Arc::new(Follow::new(LONG));
    let fake = Arc::new(Fake::default());
    change(&follow, &fake, signed_in("user_me")).await;
    change(&follow, &fake, signed_out(Some("user_me"))).await;
    follow.settled().await;
    let before = fake.calls();
    let again = change(&follow, &fake, signed_out(Some("user_me"))).await;
    assert_eq!(again, Accepted { recorded: None, leave: false, enroll: false });
    follow.settled().await;
    assert_eq!(fake.calls(), before);
    change(&follow, &fake, signed_in("user_me")).await;
    let again = change(&follow, &fake, signed_in("user_me")).await;
    assert_eq!(again, Accepted { recorded: None, leave: false, enroll: false });
    follow.settled().await;
    assert_eq!(fake.enrolls(), 2);
}

/// The RPC is the person's local line only: a connection that did not prove the person is
/// refused before anything runs.
#[tokio::test]
async fn signed_in_from_a_connection_that_is_not_the_person_is_refused() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let (input, incoming) = tokio::sync::mpsc::channel(8);
    let (out, mut output) = tokio::sync::mpsc::channel(64);
    // task-owner: the test's one connection; ends when `input` drops at the test's end.
    tokio::spawn(crate::server::serve_connection(hub, incoming, out));
    let init = crate::rpc::Message::request(
        1,
        crate::rpc::method::INITIALIZE,
        json!({"protocolVersion": 1}),
    );
    input.send(init.to_line()).await.unwrap();
    let ask = crate::rpc::Message::request(
        2,
        crate::rpc::method::MUX_MACHINE_SIGNED_IN,
        json!({"userId": "someone-else", "accessToken": "chosen", "hub": "http://127.0.0.1:9"}),
    );
    input.send(ask.to_line()).await.unwrap();
    let reply = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let reply: Value = serde_json::from_str(&output.recv().await.unwrap()).unwrap();
            if reply["id"] == 2 {
                return reply;
            }
        }
    })
    .await
    .expect("the reply comes");
    assert!(reply.get("result").is_none(), "{reply}");
    assert_eq!(reply["error"]["data"]["reason"], crate::hub::person::REASON, "{reply}");
}
