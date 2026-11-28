use super::*;

#[tokio::test]
async fn a_record_round_trips_and_an_oversized_one_closes_the_reader() {
    let (mut a, mut b) = tokio::io::duplex(1 << 16);
    write_frame(&mut a, &json!({"id": 1, "method": "read"})).await.unwrap();
    assert_eq!(read_frame(&mut b).await, Some(json!({"id": 1, "method": "read"})));
    a.write_u32((MAX_FRAME + 1) as u32).await.unwrap();
    assert_eq!(read_frame(&mut b).await, None);
}

const CAPACITY: &str = "link transport failed: relay allocation is temporarily unavailable \
                        (relay code slot-circuit-capacity)";

/// The 12:52Z round-trip probe's failure: the relay's first capacity refusal failed the move.
/// Now the dial waits and asks again, and a refusal that clears is a dial that works.
#[tokio::test(start_paused = true)]
async fn a_capacity_refusal_is_dialed_again_until_the_relay_has_room() {
    let tries = std::cell::Cell::new(0);
    let started = tokio::time::Instant::now();
    let got = dial_past_capacity(
        || {
            tries.set(tries.get() + 1);
            let n = tries.get();
            async move { if n < 4 { Err(CAPACITY.to_owned()) } else { Ok(n) } }
        },
        || async { None::<Result<u32, String>> },
        &CAPACITY_WAITS,
    )
    .await;
    assert_eq!(got, Ok(4));
    assert_eq!(started.elapsed(), Duration::from_millis(250 + 500 + 1000));
}

#[tokio::test(start_paused = true)]
async fn a_capacity_refusal_rides_an_open_kept_circuit_with_no_wait() {
    let started = tokio::time::Instant::now();
    let got = dial_past_capacity(
        || async { Err::<&str, _>(CAPACITY.to_owned()) },
        || async { Some(Ok("kept")) },
        &CAPACITY_WAITS,
    )
    .await;
    assert_eq!(got, Ok("kept"));
    assert_eq!(started.elapsed(), Duration::ZERO);
}

#[tokio::test(start_paused = true)]
async fn any_other_dial_error_answers_at_once_and_a_lasting_refusal_says_how_long() {
    let tries = std::cell::Cell::new(0);
    let other = dial_past_capacity(
        || {
            tries.set(tries.get() + 1);
            async { Err::<(), _>("service.off: no transfer service".to_owned()) }
        },
        || async { None },
        &CAPACITY_WAITS,
    )
    .await;
    assert_eq!(other, Err("service.off: no transfer service".to_owned()));
    assert_eq!(tries.get(), 1);

    let lasting = dial_past_capacity(
        || async { Err::<(), _>(CAPACITY.to_owned()) },
        || async { Some(Err("the machine keeps no circuits".to_owned())) },
        &CAPACITY_WAITS,
    )
    .await
    .unwrap_err();
    assert!(lasting.contains("slot-circuit-capacity"), "{lasting}");
    assert!(lasting.ends_with("refused again after 15750 ms of retries"), "{lasting}");
}

#[test]
fn only_the_relay_capacity_codes_count_as_capacity() {
    assert!(capacity_refusal(CAPACITY));
    assert!(capacity_refusal("relay allocation is temporarily unavailable (relay code slot-busy)"));
    assert!(!capacity_refusal("relay allocation is temporarily unavailable (relay code other)"));
    assert!(!capacity_refusal("credential-unavailable: the machine's relay ticket expired"));
}
