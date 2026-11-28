//! Reads keep their own delivery slots while sends and starts hang (`mesh_relay.rs` `inbox`).

use super::*;
use crate::mesh::{AckState, Sender, Target};
use futures::future::BoxFuture;

/// A hub fake: leases each queued batch to one inbox poll, then waits; records every ack.
struct Queued {
    batches: std::sync::Mutex<std::collections::VecDeque<Vec<InMessage>>>,
    acks: std::sync::Mutex<Vec<(String, Ack)>>,
}

impl MeshHub for Queued {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        let next = self.batches.lock().unwrap().pop_front();
        Box::pin(async move {
            match next {
                Some(batch) => Ok(batch),
                None => std::future::pending().await,
            }
        })
    }
    fn ack<'a>(&'a self, id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        self.acks.lock().unwrap().push((id.to_owned(), ack.clone()));
        Box::pin(async { Ok(()) })
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        Box::pin(async {
            Ok(crate::mesh::HeartbeatReply { daemon_id: "inst_a".into(), ttl_seconds: 90 })
        })
    }
    fn send<'a>(
        &'a self,
        _: &'a crate::mesh::OutMessage,
    ) -> BoxFuture<'a, Result<crate::mesh::Receipt, HubError>> {
        unreachable!()
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<crate::mesh::Receipt, HubError>> {
        unreachable!()
    }
}

/// Starts hang forever; a read answers at once.
struct HangingStarts;

impl ControlHook for HangingStarts {
    fn control<'a>(
        &'a self,
        _: &'a Arc<Hub>,
        message: &'a InMessage,
    ) -> futures::future::BoxFuture<'a, Option<Ack>> {
        let read = message.op.as_deref() == Some("read");
        Box::pin(async move {
            if read { Some(Ack::answered("r", "{}".into())) } else { std::future::pending().await }
        })
    }
}

fn from(host: &str, name: &str) -> InMessage {
    InMessage {
        message_id: "m".into(),
        to: Target::default(),
        from: Sender { name: Some(name.into()), host: Some(host.into()), ..Sender::default() },
        body: "x".into(),
        mode: Mode::TurnEnd,
        attempt: 1,
        kind: Kind::Prompt,
        op: None,
        start_work: Some(StartWork::Information),
        state: Some("queued".into()),
        subject: None,
    }
}

fn control_message(id: &str, op: &str) -> InMessage {
    let mut message = from("", "");
    message.message_id = id.to_owned();
    message.kind = Kind::Control;
    message.op = Some(op.into());
    message
}

/// Hangs 40 starts (more than the 32 send and start slots) and then asks a read: the read
/// answers from its own slots at once, and the hung starts free their slots at their bound.
#[tokio::test(start_paused = true)]
async fn a_read_answers_while_more_than_thirty_two_deliveries_hang() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let starts: Vec<InMessage> =
        (0..40).map(|n| control_message(&format!("msg_{:032x}", n + 1), "start")).collect();
    let read = control_message(&format!("msg_{:032x}", 1000), "read");
    let fake = Arc::new(Queued {
        batches: std::sync::Mutex::new(vec![starts, vec![read]].into()),
        acks: Default::default(),
    });
    let options =
        RelayOptions { heartbeat_every: Duration::from_secs(60), ..RelayOptions::default() };
    let bound = options.delivery_bound;
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(HangingStarts), options);
    let answered = async {
        loop {
            if fake.acks.lock().unwrap().iter().any(|(id, _)| id.ends_with("3e8")) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(10), answered)
        .await
        .expect("a read answers while 32 starts hang");
    let acks = fake.acks.lock().unwrap().clone();
    assert_eq!(
        acks.len(),
        1,
        "no hung start was acked: {:?}",
        acks.iter().take(3).collect::<Vec<_>>()
    );
    assert_eq!(acks[0].1.state, AckState::Delivered);
    // The hung starts free their slots at their bound, unacked: the lease brings them back.
    tokio::time::sleep(bound + Duration::from_secs(1)).await;
    assert_eq!(fake.acks.lock().unwrap().len(), 1);
    relay.stop().await;
}

/// Door A timing run (huge-blue/door-a-join-timing, 2026-11-16): `cmux chat --on doora-vm-1`
/// was refused "this harness has no reviewed asking mode for a remote WebSocket connection
/// (code -32602)", a text two refusals share. The ack names the refusal's reason, so the Mac
/// says which one it was.
#[test]
fn a_refused_control_ack_names_the_refusals_reason() {
    let error = crate::rpc::RpcError::invalid_params("no reviewed asking mode")
        .with_data(serde_json::json!({"reason": "remote.executable_refused"}));
    let detail = refusal_detail(&error);
    assert!(detail.contains("no reviewed asking mode"), "{detail}");
    assert!(detail.contains("code -32602"), "{detail}");
    assert!(detail.contains("reason remote.executable_refused"), "{detail}");
    // An error with no reason reads as before.
    let plain = crate::rpc::RpcError::invalid_params("bad params");
    assert_eq!(refusal_detail(&plain), "bad params (code -32602)");
}

#[test]
fn heartbeats_come_at_a_third_of_the_ttl_at_most_every_heartbeat_every() {
    let options = RelayOptions::default();
    assert_eq!(heartbeat_wait(&options, 90), Duration::from_secs(30));
    assert_eq!(heartbeat_wait(&options, 30), Duration::from_secs(10));
    assert_eq!(heartbeat_wait(&options, 0), Duration::from_secs(30));
    let mut backoff = Backoff::new(Duration::from_secs(1), Duration::from_secs(4));
    let limited =
        HubError { retry_after: Some(Duration::from_secs(9)), ..HubError::unavailable("") };
    assert_eq!(after_failure(&mut backoff, &limited), Duration::from_secs(9));
}

#[test]
fn an_ack_detail_is_clipped_to_what_the_hub_takes() {
    let ack = clip(Ack::refused("é".repeat(5000)));
    assert_eq!(ack.detail.unwrap().chars().count(), MAX_DETAIL_CHARS);
    assert_eq!(clip(Ack::refused("short")).detail.as_deref(), Some("short"));
}
