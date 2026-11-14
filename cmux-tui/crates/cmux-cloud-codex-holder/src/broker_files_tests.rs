//! Renewal that fails while offline tries again later, and the catch-up of a machine taken back
//! after a relaunch. Ported from CloudCodexBrokerRenewalRetryTests.swift.

use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use super::*;
use crate::broker::RENEWAL_RETRY_CAP;
use crate::broker_renewal::retries_later;
use crate::record::Record;
use crate::test_support::*;
use crate::types::Scope;

fn scope() -> Scope {
    Scope::new("user-1", None)
}

const BASE: Duration = Duration::from_millis(200);

/// The machine's API refuses the next `n` commits.
fn away(fake: &mut Fake, n: usize, only_after_first: bool) -> Arc<AtomicUsize> {
    let left = Arc::new(AtomicUsize::new(n));
    let (counter, machine) = (left.clone(), fake.machine.clone());
    fake.before_commit = Some(hook_fn(move |_| {
        let (left, machine) = (counter.clone(), machine.clone());
        async move {
            if only_after_first && machine.commits.get() == 0 {
                return Ok(());
            }
            if left.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1)).is_ok() {
                return Err(BrokerError::RemoteDeliveryFailed.into());
            }
            Ok(())
        }
    }));
    left
}

/// The holder fails the four tries of the first renewal (the old code's whole budget) and
/// answers again after: a later renewal delivers new access. `exit`: the holder dies; else it
/// answers `codex_auth_unavailable`, as the real holder does when a refresh fails offline.
#[tokio::test(flavor = "multi_thread")]
async fn a_renewal_that_fails_while_offline_tries_again_later() {
    for exit in [true, false] {
        let root = tempfile::tempdir().unwrap();
        let counter = root.path().join("count");
        let failure = if exit {
            "exit 1"
        } else {
            r#"echo "{\"id\":$id,\"error\":\"codex_auth_unavailable\"}"; continue"#
        };
        let script = format!(
            r#"counter="{counter}"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    count=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 )); echo "$count" > "$counter"
    if [ "$count" -ge 2 ] && [ "$count" -le 5 ]; then
      {failure}
    fi
    expiry=$(($(date +%s) + 121)); if [ "$count" -gt 1 ]; then expiry=2147483647; fi
    echo "{{\"id\":$id,\"result\":{{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":$expiry}}}}"
  fi
done
"#,
            counter = counter.display()
        );
        let broker = broker(root.path(), &script, fixed_scope(scope()), BASE);
        let machine = Machine::new();
        let target = Fake::new("vm-retry", machine.clone()).arc();
        broker.transfer(&Cx::new(), &target, true, false).await.unwrap();
        machine.commits.wait(2).await;
        assert!(
            machine.text(ACCESS_PATH).contains("access-6"),
            "the renewal after the outage did not deliver"
        );
        broker.shutdown().await;
    }
}

/// The holder refreshes fine but the machine's API is away for the renewal's delivery tries: the
/// next renewal comes after the backoff, not at the refreshed grant's expiry (cmux#33387).
#[tokio::test(flavor = "multi_thread")]
async fn a_delivery_that_fails_after_a_good_refresh_tries_again_later() {
    let root = tempfile::tempdir().unwrap();
    let script = counting_holder(
        r#"expiry=$(($(date +%s) + 121)); if [ "$count" -gt 1 ]; then expiry=2147483647; fi"#,
    );
    let broker = broker(root.path(), &script, fixed_scope(scope()), BASE);
    let machine = Machine::new();
    let mut fake = Fake::new("vm-away", machine.clone());
    let left = away(&mut fake, 4, true);
    let target = fake.arc();
    broker.transfer(&Cx::new(), &target, true, false).await.unwrap();
    machine.commits.wait(2).await;
    assert_eq!(left.load(Ordering::SeqCst), 0);
    assert!(
        !machine.text(ACCESS_PATH).contains("access-1\""),
        "the machine kept its first, expired access"
    );
    broker.shutdown().await;
}

struct Relaunch {
    _root: tempfile::TempDir,
    broker: Arc<Broker>,
    other: TargetRef,
    taken: TargetRef,
    machine: Arc<Machine>,
    left: Arc<AtomicUsize>,
}

/// A holder whose every access answers a long grant, and a machine taken back after a relaunch:
/// it holds this holder's access from the last run, expiring `left_expires_in` seconds from now,
/// and its API refuses the next `refusals` commits.
fn relaunch(left_expires_in: f64, refusals: usize) -> Relaunch {
    let root = tempfile::tempdir().unwrap();
    let holder = Record::new(&root.path().join("holder")).holder_id();
    let broker =
        broker(root.path(), &counting_holder("expiry=2147483647"), fixed_scope(scope()), BASE);
    let other = Fake::new("vm-other", Machine::new()).arc();
    let machine = Machine::new();
    let left = serde_json::json!({"schema": 1, "bridge": "codex-external-access-v1", "accessToken": "left-access",
        "chatgptAccountId": "acct-1", "holder": holder, "previousMode": null,
        "expiresAt": (now() + left_expires_in) as i64});
    machine.write(ACCESS_PATH, left.to_string().as_bytes());
    machine.write(MODE_PATH, OWN);
    let mut fake = Fake::new("vm-taken", machine.clone());
    let left = away(&mut fake, refusals, false);
    Relaunch { _root: root, broker, other, taken: fake.arc(), machine, left }
}

/// cmux#34010: a machine taken back after a relaunch whose access ends before the scheduled
/// renewal gets new access at once; when that delivery fails it tries again before the access ends.
#[tokio::test(flavor = "multi_thread")]
async fn a_failed_catch_up_after_a_relaunch_tries_again_before_the_access_ends() {
    let r = relaunch(600.0, 2);
    // This run already renews for another machine, with a grant that lasts.
    r.broker.transfer(&Cx::new(), &r.other, true, false).await.unwrap();
    r.broker.resume(&Cx::new(), &r.taken, false).await;
    assert_eq!(
        r.broker.registered_machine_ids(),
        HashSet::from(["vm-other".to_owned(), "vm-taken".to_owned()])
    );
    r.machine.commits.wait(1).await;
    assert_eq!(r.left.load(Ordering::SeqCst), 0);
    assert!(
        !r.machine.text(ACCESS_PATH).contains("left-access"),
        "the machine kept the access it was left"
    );
    r.broker.shutdown().await;
}

/// cmux#34010: the catch-up retry ends when the machine's access does, and an erase or a delete
/// cancels it at once.
#[tokio::test(flavor = "multi_thread")]
async fn the_catch_up_retry_stops_at_the_expiry_and_on_erase_or_delete() {
    let r = relaunch(2.0, usize::MAX);
    r.broker.transfer(&Cx::new(), &r.other, true, false).await.unwrap();
    r.broker.resume(&Cx::new(), &r.taken, false).await;
    let (_, ended) = r.broker.catch_up_task("vm-taken").unwrap();
    ended.wait().await;
    assert!(r.broker.catch_up_machine_ids().is_empty());
    // The machine stays registered: the scheduled renewal still reaches it.
    assert!(r.broker.registered_machine_ids().contains("vm-taken"));
    r.broker.shutdown().await;

    let r = relaunch(600.0, usize::MAX);
    r.broker.transfer(&Cx::new(), &r.other, true, false).await.unwrap();
    r.broker.resume(&Cx::new(), &r.taken, false).await;
    let (erased, _) = r.broker.catch_up_task("vm-taken").unwrap();
    r.broker.revoke(&Cx::never(), &r.taken, false).await.unwrap();
    assert!(erased.is_cancelled());
    assert!(r.broker.catch_up_machine_ids().is_empty());
    assert!(r.machine.read(ACCESS_PATH).is_none() && r.machine.read(MODE_PATH).is_none());
    r.broker.shutdown().await;

    let r = relaunch(600.0, usize::MAX);
    r.broker.transfer(&Cx::new(), &r.other, true, false).await.unwrap();
    r.broker.resume(&Cx::new(), &r.taken, false).await;
    let (deleted, _) = r.broker.catch_up_task("vm-taken").unwrap();
    r.broker.discard_deleted_target("vm-taken");
    assert!(deleted.is_cancelled());
    assert!(r.broker.catch_up_machine_ids().is_empty());
    r.broker.shutdown().await;
}

/// The backoff doubles from its base and stops at the cap.
#[tokio::test]
async fn the_backoff_doubles_up_to_its_cap() {
    let root = tempfile::tempdir().unwrap();
    let broker = broker(root.path(), "exit 1\n", fixed_scope(scope()), Duration::from_secs(15));
    assert!(retries_later(&BrokerError::NotAuthenticated.into()));
    assert!(!retries_later(&BrokerError::AccountChanged.into()));
    assert_eq!(broker.renewal_retry_delay(1), Duration::from_secs(15));
    assert_eq!(broker.renewal_retry_delay(2), Duration::from_secs(30));
    assert_eq!(broker.renewal_retry_delay(9), RENEWAL_RETRY_CAP);
    assert!(retries_later(&BrokerError::BrokerUnavailable.into()));
    assert!(!retries_later(&BrokerError::ScopeChanged.into()));
    assert!(!retries_later(&BrokerError::Cancelled.into()));
    assert!(!retries_later(&Error::Interrupted));
    assert!(Broker::catch_up_retries(&BrokerError::TargetOffline.into()));
}

#[test]
fn a_left_access_file_gives_its_expiry_and_an_unreadable_one_is_expired() {
    let grant = grant_in(br#"{"accessToken":"a","chatgptAccountId":"b","expiresAt":42}"#);
    assert_eq!(grant, Grant { access_token: "a".into(), account: "b".into(), expires_at: 42.0 });
    assert_eq!(grant_in(b"nope").expires_at, 0.0);
    // A machine's own file never sets a timer it could overflow.
    assert_eq!(grant_in(br#"{"expiresAt":1e300}"#).expires_at, 0.0);
}
