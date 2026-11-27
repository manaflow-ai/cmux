use super::*;
use crate::server::bounded_outbound::{BoundedOutbound, QueuedSink};
use std::sync::Arc;

/// More clients than the 8 watches the daemon once took each hold a lease; a
/// second watch of one client is still refused.
#[test]
fn more_watches_than_the_old_cap_each_hold_a_lease() {
    let mux = Mux::new_for_test("inventory-watch-many", crate::SurfaceOptions::default());
    let watches = Watches::default();
    let watch = |client: u64| {
        let writer = MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        });
        Watch::new(&mux, client, PathBuf::from("/nonexistent"), 0, writer).unwrap()
    };
    for client in 0..12 {
        watches.insert(watch(client)).unwrap();
    }
    assert!((0..12).all(|client| watches.get(client).is_some()));
    assert!(matches!(watches.insert(watch(3)), Err(Failure::Busy)));
}
