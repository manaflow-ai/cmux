//! The holder's delivery and revocation rules. Ported from CloudCodexBrokerTests.swift; each case
//! owns a fake private holder (a shell script) and in-memory machines.

use super::*;
use crate::broker_files::OWN;
use crate::target::{ACCESS_PATH, MODE_PATH};
use crate::test_support::*;

const LONG: Duration = Duration::from_secs(15);

fn scope() -> Scope {
    Scope::new("user-1", None)
}

const ANSWERS_ALL: &str = r#"while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"access-token\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":2147483647}}"
  elif printf '%s' "$line" | grep -q '"method":"login"'; then
    echo "{\"id\":$id,\"result\":{\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"ABCD-EFGH\"}}"
  else
    echo "{\"id\":$id,\"result\":{}}"
  fi
done
"#;

#[tokio::test(flavor = "multi_thread")]
async fn revocation_fences_pending_validation() {
    let root = tempfile::tempdir().unwrap();
    let broker = broker(root.path(), "exit 1\n", fixed_scope(scope()), LONG);
    let gate = Gate::new();
    let mut fake = Fake::new("vm-1", Machine::new());
    let g = gate.clone();
    fake.capability = Some(hook_fn(move |_| {
        let g = g.clone();
        async move {
            g.pause().await;
            Ok(())
        }
    }));
    let target = fake.arc();
    let pending = {
        let (broker, target) = (broker.clone(), target.clone());
        tokio::spawn(async move { broker.transfer(&Cx::new(), &target, true, false).await })
    };
    gate.entered().await;
    broker.revoke(&Cx::never(), &target, false).await.unwrap();
    gate.open();
    assert_eq!(pending.await.unwrap(), Err(BrokerError::Cancelled.into()));
}

#[tokio::test(flavor = "multi_thread")]
async fn requires_explicit_consent_and_owner_capability() {
    let root = tempfile::tempdir().unwrap();
    let broker = broker(root.path(), "exit 1\n", fixed_scope(scope()), LONG);
    let mut fake = Fake::new("vm-1", Machine::new());
    fake.owner = false;
    let target = fake.arc();
    assert_eq!(
        broker.transfer(&Cx::new(), &target, false, false).await,
        Err(BrokerError::ConsentRequired.into())
    );
    assert_eq!(
        broker.transfer(&Cx::new(), &target, true, false).await,
        Err(BrokerError::SharedMachine.into())
    );
}

/// The first renewal's delivery to `machine` pauses at `gate` (its staged access write).
fn held_first_renewal(machine: Arc<Machine>, gate: Arc<Gate>) -> Fake {
    let mut fake = Fake::new("vm-renew", machine.clone());
    let held = Arc::new(std::sync::atomic::AtomicBool::new(false));
    fake.write = Some(hook_fn(move |path| {
        let (machine, gate, held) = (machine.clone(), gate.clone(), held.clone());
        async move {
            if path.contains(".access-")
                && machine.commits.get() > 0
                && !held.swap(true, std::sync::atomic::Ordering::SeqCst)
            {
                gate.pause().await;
            }
            Ok(())
        }
    }));
    fake
}

#[tokio::test(flavor = "multi_thread")]
async fn scheduled_renewal_survives_concurrent_target_revocation() {
    let root = tempfile::tempdir().unwrap();
    let script = counting_holder(
        r#"expiry=$(($(date +%s) + 123)); if [ "$count" -gt 1 ]; then expiry=2147483647; fi; if [ "$count" = 2 ]; then expiry=1; fi"#,
    );
    let broker = broker(root.path(), &script, fixed_scope(scope()), LONG);
    let gate = Gate::new();
    let first = Machine::new();
    let target = held_first_renewal(first.clone(), gate.clone()).arc();
    broker.transfer(&Cx::new(), &target, true, false).await.unwrap();
    let second = Machine::new();
    let target2 = Fake::new("vm-renew-2", second.clone()).arc();
    broker.transfer(&Cx::new(), &target2, true, false).await.unwrap();
    gate.entered().await;
    let revocation = {
        let (broker, target) = (broker.clone(), target.clone());
        tokio::spawn(async move { broker.revoke(&Cx::never(), &target, false).await })
    };
    while broker.registered_machine_ids().contains("vm-renew") {
        tokio::task::yield_now().await;
    }
    gate.open();
    revocation.await.unwrap().unwrap();
    second.commits.wait(2).await;
    assert!(second.commits.get() >= 2);
}

#[tokio::test(flavor = "multi_thread")]
async fn foreground_refresh_does_not_cancel_active_renewal_delivery() {
    let root = tempfile::tempdir().unwrap();
    let script = counting_holder(
        r#"expiry=$(($(date +%s) + 123)); if [ "$count" -gt 1 ]; then expiry=2147483647; fi"#,
    );
    let broker = broker(root.path(), &script, fixed_scope(scope()), LONG);
    let gate = Gate::new();
    let machine = Machine::new();
    let target = held_first_renewal(machine.clone(), gate.clone()).arc();
    broker.transfer(&Cx::new(), &target, true, false).await.unwrap();
    gate.entered().await;
    let other = Fake::new("foreground-vm", Machine::new()).arc();
    broker.transfer(&Cx::new(), &other, true, true).await.unwrap();
    gate.open();
    machine.commits.wait(2).await;
    assert_eq!(
        broker.registered_machine_ids(),
        HashSet::from(["vm-renew".to_owned(), "foreground-vm".to_owned()])
    );
    assert!(machine.read(ACCESS_PATH).is_some());
}

#[tokio::test(flavor = "multi_thread")]
async fn retries_with_a_new_session_after_holder_exit() {
    let root = tempfile::tempdir().unwrap();
    let script = r#"if [ ! -f "$3/started" ]; then touch "$3/started"; read -r ignored; exit 1; fi
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  echo "{\"id\":$id,\"result\":{\"accessToken\":\"access\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":2147483647}}"
done
"#;
    let broker = broker(root.path(), script, fixed_scope(scope()), LONG);
    let target = Fake::new("vm-1", Machine::new()).arc();
    assert!(broker.transfer(&Cx::new(), &target, true, false).await.is_err());
    let grant = broker.transfer(&Cx::new(), &target, true, false).await.unwrap();
    assert_eq!(grant.account, "acct-1");
}

#[tokio::test(flavor = "multi_thread")]
async fn abandoned_login_preserves_existing_mode() {
    for cancel in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let script = r#"while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  echo "{\"id\":$id,\"error\":\"codex_auth_unavailable\"}"
done
"#;
        let broker = broker(root.path(), script, fixed_scope(scope()), LONG);
        let machine = Machine::new();
        machine.write(MODE_PATH, b"team\n");
        let target = Fake::new("vm", machine.clone()).arc();
        assert_eq!(
            broker.transfer(&Cx::new(), &target, true, false).await,
            Err(BrokerError::NotAuthenticated.into())
        );
        let cx = Cx::new();
        if cancel {
            cx.cancel();
        }
        let timeout = if cancel { Duration::from_secs(300) } else { Duration::ZERO };
        assert!(broker.wait_for_login_and_transfer(&cx, &target, true, timeout).await.is_err());
        assert!(broker.registered_machine_ids().is_empty());
        assert_eq!(machine.removals.get(), 0);
        assert_eq!(machine.read(MODE_PATH).as_deref(), Some(&b"team\n"[..]));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_device_login_returns_its_prompt() {
    let root = tempfile::tempdir().unwrap();
    let broker = broker(root.path(), ANSWERS_ALL, fixed_scope(scope()), LONG);
    let target = Fake::new("vm", Machine::new()).arc();
    let prompt = broker.login(&Cx::new(), &target, true).await.unwrap();
    assert_eq!(
        prompt,
        Prompt {
            verification_url: "https://auth.openai.com/codex/device".into(),
            user_code: "ABCD-EFGH".into()
        }
    );
}

/// Every interruption of a delivery (ported case by case from
/// deliversAccessOnlyGrantAndRestoresPriorModeOnRevoke).
#[tokio::test(flavor = "multi_thread")]
async fn delivers_access_only_grant_and_restores_prior_mode_on_revoke() {
    for interruption in 0..=13 {
        interrupted_delivery(interruption).await;
    }
}

async fn interrupted_delivery(interruption: u32) {
    let root = tempfile::tempdir().unwrap();
    let account = Account::new(scope());
    let broker = broker(root.path(), ANSWERS_ALL, account.current(), LONG);
    let gate = Gate::new();
    let machine = Machine::new();
    machine.write(MODE_PATH, b"team\n");
    let mut fake = Fake::new("vm-1", machine.clone());
    {
        let gate = gate.clone();
        fake.before_commit = Some(hook_fn(move |_| {
            let gate = gate.clone();
            async move {
                if interruption == 3 {
                    return Err(BrokerError::RemoteDeliveryFailed.into());
                }
                if interruption == 1 || interruption == 2 {
                    gate.pause().await;
                }
                Ok(())
            }
        }));
    }
    {
        let (machine, account) = (machine.clone(), account.clone());
        fake.after_commit = Some(hook_fn(move |_| {
            let (machine, account) = (machine.clone(), account.clone());
            async move {
                match interruption {
                    5 => return Err(BrokerError::RemoteDeliveryFailed.into()),
                    11 => {
                        machine.set(|f| f.refuse_access_read = true);
                        return Err(BrokerError::RemoteDeliveryFailed.into());
                    }
                    7 => {
                        machine.set(|f| f.refuse_restore = true);
                        account.logout();
                    }
                    10 => machine.set(|f| f.refuse_removal = true),
                    _ => {}
                }
                Ok(())
            }
        }));
    }
    if interruption == 4 {
        let checks = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        fake.live = Some(live_fn(move || {
            let n = checks.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            async move { Ok(n == 0) }
        }));
    }
    let target = fake.arc();
    let cx = Cx::new();
    let transfer = |broker: &Arc<Broker>| {
        let (broker, target) = (broker.clone(), target.clone());
        async move { broker.transfer(&Cx::new(), &target, true, false).await }
    };
    let rdf: Result<(), Error> = Err(BrokerError::RemoteDeliveryFailed.into());
    let revoke = |broker: &Arc<Broker>| {
        let (broker, target) = (broker.clone(), target.clone());
        async move { broker.revoke(&Cx::never(), &target, false).await }
    };
    match interruption {
        8 => {
            machine.set(|f| f.refuse_commit = true);
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            revoke(&broker).await.unwrap();
            assert!(machine.read(ACCESS_PATH).is_none());
            machine.write(MODE_PATH, OWN);
            machine.set(|f| f.refuse_commit = false);
            transfer(&broker).await.unwrap();
            revoke(&broker).await.unwrap();
            assert!(machine.read(ACCESS_PATH).is_none());
            assert_eq!(
                machine.read(MODE_PATH).as_deref(),
                Some(OWN),
                "the person's own mode stays"
            );
            return;
        }
        9 => {
            machine.set(|f| {
                f.refuse_commit = true;
                f.refuse_access_read = true;
            });
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            assert_eq!(machine.staged(), 0);
            machine.set(|f| f.refuse_access_read = false);
            revoke(&broker).await.unwrap();
            return;
        }
        10 => {
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            assert!(machine.staged() > 0);
            assert_eq!(revoke(&broker).await, Err(denied()));
            assert!(machine.staged() > 0);
            machine.set(|f| f.refuse_removal = false);
            revoke(&broker).await.unwrap();
            assert_eq!(machine.staged(), 0);
            return;
        }
        12 => {
            machine.set(|f| {
                f.refuse_commit = true;
                f.refuse_removal = true;
            });
            for _ in 0..2 {
                assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            }
            assert_eq!(machine.staged(), 4);
            machine.set(|f| f.refuse_removal = false);
            revoke(&broker).await.unwrap();
            assert_eq!(machine.staged(), 0);
            return;
        }
        13 => {
            machine.set(|f| {
                f.refuse_commit = true;
                f.refuse_removal = true;
            });
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            assert_eq!(machine.staged(), 2);
            machine.set(|f| {
                f.refuse_commit = false;
                f.refuse_directory = true;
            });
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            machine.set(|f| {
                f.refuse_directory = false;
                f.refuse_removal = false;
            });
            revoke(&broker).await.unwrap();
            assert_eq!(machine.staged(), 0);
            return;
        }
        11 => {
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            machine.set(|f| f.refuse_access_read = false);
            revoke(&broker).await.unwrap();
            assert!(machine.read(ACCESS_PATH).is_none());
            assert_eq!(machine.text(MODE_PATH), "team\n");
            return;
        }
        4 => {
            assert_eq!(transfer(&broker).await.map(|_| ()), Err(BrokerError::TargetOffline.into()));
            assert_eq!(machine.removals.get(), 0);
            return;
        }
        7 => {
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            assert!(machine.read(ACCESS_PATH).is_none());
            assert_eq!(machine.read(MODE_PATH).as_deref(), Some(OWN));
            machine.set(|f| f.refuse_restore = false);
            revoke(&broker).await.unwrap();
            assert_eq!(machine.text(MODE_PATH), "team\n");
            return;
        }
        5 => {
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            assert!(machine.read(ACCESS_PATH).is_none());
            assert_eq!(machine.text(MODE_PATH), "team\n");
            return;
        }
        3 => {
            machine.write(ACCESS_PATH, b"existing-grant");
            assert_eq!(transfer(&broker).await.map(|_| ()), rdf);
            assert_eq!(machine.text(ACCESS_PATH), "existing-grant");
            return;
        }
        1 | 2 => {
            let running = {
                let (broker, target, cx, gate) =
                    (broker.clone(), target.clone(), cx.clone(), gate.clone());
                tokio::spawn(async move {
                    let result = broker.transfer(&cx, &target, true, false).await;
                    // A transfer that fails before its commit ends the wait for the pause.
                    gate.passed();
                    result
                })
            };
            gate.entered().await;
            if interruption == 1 {
                account.logout();
            } else {
                cx.cancel();
            }
            gate.open();
            let expected =
                if interruption == 1 { BrokerError::ScopeChanged } else { BrokerError::Cancelled };
            assert_eq!(
                running.await.unwrap().map(|_| ()),
                Err(expected.into()),
                "interruption {interruption}"
            );
            assert!(machine.read(ACCESS_PATH).is_none());
            assert_eq!(machine.text(MODE_PATH), "team\n");
            assert!(broker.registered_machine_ids().is_empty());
            return;
        }
        _ => {}
    }
    let grant = transfer(&broker).await.unwrap();
    assert_eq!(grant.account, "acct-1");
    let committed = machine.committed.lock().unwrap().clone().unwrap();
    assert_eq!(committed[1], ACCESS_PATH);
    assert_eq!(committed[3], MODE_PATH);
    let object: Value = serde_json::from_slice(&machine.read(ACCESS_PATH).unwrap()).unwrap();
    assert_eq!(object["schema"], 1);
    assert_eq!(object["bridge"], "codex-external-access-v1");
    assert_eq!(object["accessToken"], "access-token");
    assert_eq!(object["previousMode"], "dGVhbQo=", "the mode to restore travels with the access");
    assert!(object.get("refreshToken").is_none());
    assert_eq!(machine.read(MODE_PATH).as_deref(), Some(OWN));

    let second = Machine::new();
    let target2 = Fake::new("vm-2", second.clone()).arc();
    broker.transfer(&Cx::new(), &target2, true, false).await.unwrap();
    assert!(second.read(ACCESS_PATH).is_some());
    assert_eq!(second.read(MODE_PATH).as_deref(), Some(OWN));
    assert_eq!(machine.paths().len(), 2);
    if interruption == 6 {
        machine.write(MODE_PATH, b"team\n");
        revoke(&broker).await.unwrap();
        assert_eq!(machine.text(MODE_PATH), "team\n");
        return;
    }
    machine.set(|f| f.refuse_removal = true);
    assert_eq!(revoke(&broker).await, Err(denied()));
    assert!(machine.read(ACCESS_PATH).is_some());
    assert_eq!(transfer(&broker).await.map(|_| ()), Err(BrokerError::Cancelled.into()));
    assert!(!broker.registered_machine_ids().contains("vm-1"));
    machine.set(|f| {
        f.refuse_removal = false;
        f.refuse_restore = true;
    });
    assert_eq!(revoke(&broker).await, Err(denied()));
    assert!(machine.read(ACCESS_PATH).is_none());
    machine.set(|f| f.refuse_restore = false);
    revoke(&broker).await.unwrap();
    assert!(machine.read(ACCESS_PATH).is_none());
    assert_eq!(machine.paths().len(), 1);
    assert_eq!(machine.text(MODE_PATH), "team\n");
}

/// Refreshes that start together on different workers share one holder request: two would each
/// rotate the Codex credential.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_refreshes_share_one_holder_request() {
    let root = tempfile::tempdir().unwrap();
    let script = counting_holder(r#"expiry=2147483647; sleep 0.3"#);
    let broker = broker(root.path(), &script, fixed_scope(scope()), LONG);
    let calls: Vec<_> = (0..8)
        .map(|_| {
            let broker = broker.clone();
            tokio::spawn(async move { broker.refresh_access(false).await })
        })
        .collect();
    for call in calls {
        assert_eq!(call.await.unwrap().unwrap().access_token, "access-1");
    }
}

/// cmux#37306 review: an `expiresAt` that is huge (1e300), infinite in effect or not a time is a
/// malformed reply, never a renewal timer (whose conversion would panic the holder's task).
#[tokio::test(flavor = "multi_thread")]
async fn a_far_or_malformed_expiry_is_an_invalid_reply() {
    for expiry in ["1e300", "-5", "4102444800"] {
        let root = tempfile::tempdir().unwrap();
        let script = counting_holder(&format!("expiry={expiry}"));
        let broker = broker(root.path(), &script, fixed_scope(scope()), LONG);
        let machine = Machine::new();
        let target = Fake::new("vm-far", machine.clone()).arc();
        let error = broker.transfer(&Cx::new(), &target, true, false).await.unwrap_err();
        assert!(error.is(BrokerError::InvalidReply), "{expiry}: {error:?}");
        assert!(machine.read(ACCESS_PATH).is_none());
    }
}
