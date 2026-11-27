use super::*;
use crate::server::RenderService;

/// A failed push whose stream never queued its own overflow notice still closes with a
/// reason, so the client attaches again after the seq it holds; one that did is not told twice.
#[test]
fn a_failed_push_always_leaves_the_client_a_close_reason() {
    let service = RenderService::new();
    let overflow = closed_event(7, "overflow");
    let stream = OutboundStream::new(1, service.serialize_control(&overflow).unwrap());
    assert_eq!(unsent_reason(&stream), Some("send_failed"));
    stream.close();
    assert_eq!(unsent_reason(&stream), Some("send_failed"), "closed with no notice queued");
    stream.terminal_enqueued.store(true, Ordering::Release);
    assert_eq!(unsent_reason(&stream), None, "the overflow notice already told it");
}
