use super::*;
use std::cell::{Cell, RefCell};

fn open(n: usize) -> Vec<Delivery> {
    (0..n)
        .map(|i| {
            let mut d = retry_delay_tests::delivery(1_000 + i as u64, false);
            d.id = format!("d{i:04}");
            d.open_on_peer = true;
            d
        })
        .collect()
}

/// Review of #37284 at 0c98c292, F3: more open deliveries than one batch, none of them
/// captured by a copy, all go on one link, oldest first, each once; a link that drops midway
/// leaves the rest to the next one, which starts where it stopped and comes round.
#[tokio::test]
async fn every_open_delivery_goes_on_one_link_in_batches_and_the_next_link_goes_on() {
    let n = 3 * REDELIVER_BATCH + 7;
    let sent = RefCell::new(Vec::new());
    let one = |d: Delivery| {
        sent.borrow_mut().push(d.id);
        async {}
    };
    assert_eq!(redeliver_all(open(n), None, || true, one).await, n);
    let ids: Vec<String> = open(n).into_iter().map(|d| d.id).collect();
    assert_eq!(*sent.borrow(), ids, "each once, oldest first");

    // A link that drops after 300 of them; the next starts after the last one reached.
    sent.borrow_mut().clear();
    let left = Cell::new(300_usize);
    let up = || {
        let up = left.get() > 0;
        left.set(left.get().saturating_sub(1));
        up
    };
    let one = |d: Delivery| {
        sent.borrow_mut().push(d.id);
        async {}
    };
    assert_eq!(redeliver_all(open(n), None, up, one).await, 300);
    let reached = open(n).into_iter().nth(299).map(|d| (d.created_at, d.id)).unwrap();
    sent.borrow_mut().clear();
    let one = |d: Delivery| {
        sent.borrow_mut().push(d.id);
        async {}
    };
    assert_eq!(redeliver_all(open(n), Some(reached), || true, one).await, n);
    let mut expected = ids.clone();
    expected.rotate_left(300);
    assert_eq!(*sent.borrow(), expected, "the next link starts after the one reached");
}
