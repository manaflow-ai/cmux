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

/// A delivery its peer took and no copy ever proved (the prompt id a loaded host sent 38
/// times, 2026-11-23) meets links that come back every 3 minutes for its whole 30 days open:
/// each link's redelivery reaches it (`redeliver_all`) and claims a resend as `redeliver_one`
/// does. It is sent at most `MAX_RESENDS` times in all, the first at once, and 8 times in its
/// first 3 hours, where every link sent it before (60).
#[tokio::test]
async fn a_never_proven_delivery_is_resent_a_logarithmic_number_of_times() {
    use crate::hub::open_delivery::{self as od, MAX_RESENDS};
    let live = RefCell::new(open(1).remove(0));
    let (sends, links) = (Cell::new(0_u32), Cell::new(0_u32));
    let (link_every, three_hours) = (3 * 60_000, 3 * 60 * 60_000);
    let (mut now, mut in_three_hours) = (0, 0);
    while now < crate::hub::outbox::OPEN_ON_PEER_FOR_MS {
        let one = |_: Delivery| {
            links.set(links.get() + 1);
            if od::claim_resend(&mut live.borrow_mut(), now) {
                sends.set(sends.get() + 1);
            }
            async {}
        };
        let snapshot = live.borrow().clone();
        redeliver_all(vec![snapshot], None, || true, one).await;
        if now < three_hours {
            in_three_hours = sends.get();
        }
        now += link_every;
    }
    assert_eq!(links.get(), 14_400, "a link every 3 minutes for 30 days");
    assert_eq!(sends.get(), MAX_RESENDS, "sent again over its days open, and capped");
    assert_eq!(in_three_hours, 8, "resends in its first 3 hours");
    assert_eq!(live.borrow().resends, MAX_RESENDS);

    // A delivery its proof or a refusal closed is never claimed.
    let mut closed = open(1).remove(0);
    closed.open_on_peer = false;
    assert!(!od::claim_resend(&mut closed, 0));
}

/// Two open deliveries of one prompt id to one session go once on a link: the machine answers
/// every copy of that id with its first outcome. Another session's copy still goes.
#[test]
fn a_link_sends_one_delivery_per_prompt_id_and_session() {
    let pin = |session: &str| crate::hub::outbox::Pin {
        peer: "p".into(),
        session: session.into(),
        generation: 1,
        link: (1, 1),
    };
    let mut all = open(3);
    for d in &mut all {
        d.request = serde_json::json!({"_meta": {"acpmux": {"promptId": "same"}}});
    }
    all[0].pin = Some(pin("a"));
    all[1].pin = Some(pin("a"));
    all[2].pin = Some(pin("b"));
    let kept: Vec<String> = one_per_prompt(all).into_iter().map(|d| d.id).collect();
    assert_eq!(kept, ["d0000", "d0002"]);
}

/// A resend a machine answers with no such session (the chat was closed there) fails the
/// delivery at once: it is settled and no later link sends it again.
#[test]
fn a_resend_to_a_closed_session_fails_once_and_is_not_sent_again() {
    use crate::hub::open_delivery::{self as od, Again};
    let e = RpcError::invalid_params("no session: x")
        .with_data(serde_json::json!({"reason": "no_session"}));
    assert_eq!(next(&e), Next::NoSession);
    let mut d = open(1).remove(0);
    assert!(od::after_again(&mut d, Again::Refused(e.message.clone())), "settled at once");
    assert!(!d.open_on_peer, "no link's redelivery picks it up again");
    assert_eq!(d.state, State::Failed);
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
