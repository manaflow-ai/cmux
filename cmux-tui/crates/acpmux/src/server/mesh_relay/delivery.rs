//! One leased message's delivery, bounded, for `mesh_relay.rs` `inbox`.

use super::*;

/// Delivers `message` and acks it. Past `bound` the delivery is dropped and its slot freed: a read
/// answers with a retryable error, a send or start is left unacked and its lease brings it back.
#[allow(clippy::too_many_arguments)]
pub(super) async fn run(
    hub: Arc<Hub>,
    message: InMessage,
    control: Arc<dyn ControlHook>,
    own_id: Option<String>,
    client: Arc<dyn MeshHub>,
    beat: Arc<Beat>,
    in_flight: Arc<StdMutex<HashSet<String>>>,
    bound: Duration,
    is_read: bool,
) {
    let delivery = async {
        let ack = deliver(&hub, &message, control.as_ref(), own_id.as_deref()).await;
        // A started session is in the hub's address book before its sender hears the start went
        // through.
        if message.kind == Kind::Control
            && message.op.as_deref() == Some("start")
            && ack.as_ref().is_some_and(|a| a.state == crate::mesh::AckState::Delivered)
        {
            beat.now(START_LISTED_WAIT).await;
        }
        if let Some(ack) = ack
            && let Err(e) = client.ack(&message.message_id, &clip(ack)).await
        {
            // Its lease brings it back, and that delivery answers with this one.
            tracing::warn!("mesh relay: ack of {} failed: {e}", message.message_id);
        }
    };
    // timeout: a hung delivery frees its slot at its bound.
    if tokio::time::timeout(bound, delivery).await.is_err() {
        tracing::warn!(
            "mesh relay: delivery of {} ran past {bound:?}; its slot is freed",
            message.message_id
        );
        if is_read {
            let _ = client.ack(&message.message_id, &clip(Ack::refused("mesh.read_timeout"))).await;
        }
    }
    in_flight.lock_or_recover().remove(&message.message_id);
}
