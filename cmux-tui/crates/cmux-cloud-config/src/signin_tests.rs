use super::*;

const LIFE: u64 = 540_000;

fn held(minted_ms: u64) -> Option<Held> {
    Some(Held { minted_ms, expires_ms: minted_ms + LIFE })
}

fn mint(started_ms: u64, step: &str) -> Option<Mint> {
    Some(Mint { started_ms, step: step.into() })
}

#[test]
fn the_mint_bound_answers_after_the_keychain_and_before_the_relay() {
    assert!(MINT_BOUND > crate::keychain::DEADLINE);
    assert!(MINT_BOUND < Duration::from_secs(25));
}

#[test]
fn a_fresh_token_is_used_as_is() {
    let d = lease(&LeaseFacts { now_ms: 1_000 + LIFE / 2, held: held(1_000), mint: None });
    assert!(
        d.use_held
            && !d.start_mint
            && !d.cancel_mint
            && d.wait_until_ms.is_none()
            && d.refusal.is_none()
    );
    assert_eq!(d.state, State::Ready { expires_in_ms: LIFE / 2 });
}

#[test]
fn at_two_thirds_of_its_life_the_held_token_answers_and_a_renewal_starts_beside_it() {
    let at = renew_at_ms(0, LIFE);
    assert_eq!(at, 360_000);
    let before = lease(&LeaseFacts { now_ms: at - 1, held: held(0), mint: None });
    assert!(before.use_held && !before.start_mint);
    let due = lease(&LeaseFacts { now_ms: at, held: held(0), mint: None });
    assert!(due.use_held && due.start_mint && !due.cancel_mint);
    assert_eq!(due.state, State::Renewing { expires_in_ms: LIFE - at, step: FIRST_STEP.into() });
}

#[test]
fn a_running_renewal_is_joined_not_doubled() {
    let d = lease(&LeaseFacts {
        now_ms: 400_000,
        held: held(0),
        mint: mint(395_000, "signing the challenge"),
    });
    assert!(d.use_held && !d.start_mint && !d.cancel_mint);
    assert_eq!(
        d.state,
        State::Renewing { expires_in_ms: 140_000, step: "signing the challenge".into() }
    );
}

#[test]
fn a_stalled_renewal_is_replaced_while_the_held_token_still_answers() {
    let d = lease(&LeaseFacts {
        now_ms: 420_000,
        held: held(0),
        mint: mint(400_000, "POST /v1/auth/token"),
    });
    assert!(d.use_held && d.start_mint && d.cancel_mint && d.refusal.is_none());
}

#[test]
fn a_token_at_its_expiry_margin_is_not_handed_out() {
    let d = lease(&LeaseFacts { now_ms: LIFE - 5_000, held: held(0), mint: None });
    assert!(!d.use_held && d.start_mint);
    assert_eq!(d.wait_until_ms, Some(LIFE - 5_000 + 15_000));
}

#[test]
fn a_clock_that_went_back_renews() {
    let d = lease(&LeaseFacts { now_ms: 10_000, held: held(20_000), mint: None });
    assert!(d.use_held && d.start_mint);
}

#[test]
fn with_no_token_a_caller_waits_on_one_mint_up_to_its_bound() {
    let first = lease(&LeaseFacts { now_ms: 100, held: None, mint: None });
    assert!(!first.use_held && first.start_mint && first.wait_until_ms == Some(15_100));
    assert_eq!(
        first.state,
        State::Minting { since_ms: 100, bound_ms: 15_000, step: FIRST_STEP.into() }
    );
    let joined =
        lease(&LeaseFacts { now_ms: 5_000, held: None, mint: mint(100, "registering this Mac") });
    assert!(!joined.start_mint && joined.wait_until_ms == Some(15_100));
}

#[test]
fn a_mint_past_its_bound_names_its_step_and_is_replaced() {
    let d =
        lease(&LeaseFacts { now_ms: 15_100, held: None, mint: mint(100, "POST /v1/auth/token") });
    assert!(!d.use_held && !d.start_mint && d.cancel_mint && d.wait_until_ms.is_none());
    let refusal = d.refusal.expect("a refusal");
    assert_eq!(refusal["code"], STALLED_CODE);
    assert_eq!(refusal["retryable"], true);
    assert_eq!(
        refusal["message"],
        "this Mac is still minting its cmux install token (POST /v1/auth/token, 15 s, past its 15 s bound); \
         cmux starts a fresh mint on the next try"
    );
    assert!(!refusal["message"].as_str().unwrap_or("").contains("did not answer"));
    assert_eq!(
        d.state,
        State::MintStalled { since_ms: 100, bound_ms: 15_000, step: "POST /v1/auth/token".into() }
    );
}

#[test]
fn facts_and_decisions_read_as_the_app_sends_them() {
    let facts: LeaseFacts = serde_json::from_value(serde_json::json!({
        "nowMs": 400_000, "held": { "mintedMs": 0, "expiresMs": LIFE }, "mint": null
    }))
    .expect("facts");
    let answer = serde_json::to_value(lease(&facts)).expect("decision");
    assert_eq!(answer["useHeld"], true);
    assert_eq!(answer["startMint"], true);
    assert_eq!(answer["state"]["state"], "renewing");
    assert_eq!(answer["state"]["expiresInMs"], 140_000);
}
