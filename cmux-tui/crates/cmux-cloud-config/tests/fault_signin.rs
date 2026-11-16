//! Fault scenarios for the install token's sign-in owner (remote-cloud-durability F13: `mint-stall`), in the
//! style of cmux-remote's `carrier_sim.rs`: a seeded run on a virtual clock that drives
//! `cmux_cloud_config::signin::lease` exactly as the Mac's `MacInstallIdentity` does (ask, cancel, start, use,
//! wait, ask again), with mints that answer, fail or stall. A failing run prints its seed.
//!
//! Invariants: every caller answers within the mint bound; the answer is a token that is valid when handed out
//! or the `credential.minting` refusal naming the step, never a silent wait; a caller that arrives while a
//! valid token is held answers at once with it (make-before-break); at most one mint runs.

use std::time::Duration;

use cmux_cloud_config::signin::{self, Held, LeaseFacts, MINT_BOUND, Mint};

const LIFE_MS: u64 = 540_000;

/// A small xorshift, so the run needs no dependency and replays from its seed.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// How the next mint the owner runs goes.
#[derive(Clone, Copy, Debug)]
enum Fate {
    /// Answers after this many ms.
    Answers(u64),
    /// Fails after this many ms (the owner refused, the network dropped).
    Fails(u64),
    /// Hangs for this many ms (a stalled POST), then answers if nobody cancelled it.
    Stalls(u64),
}

struct RunningMint {
    started_ms: u64,
    ends_ms: u64,
    fails: bool,
}

#[derive(Debug, PartialEq)]
enum Answer {
    Token,
    Refused(String),
    Failed,
}

struct Mac {
    now: u64,
    held: Option<Held>,
    mint: Option<RunningMint>,
    fates: Vec<Fate>,
    mints_started: u32,
}

impl Mac {
    fn new(fates: Vec<Fate>) -> Self {
        Self { now: 0, held: None, mint: None, fates, mints_started: 0 }
    }

    /// Moves the clock to `to`, finishing the mint in flight when it ends first.
    fn advance(&mut self, to: u64) {
        if let Some(m) = &self.mint
            && m.ends_ms <= to
        {
            self.now = self.now.max(m.ends_ms);
            if !m.fails {
                self.held = Some(Held { minted_ms: m.ends_ms, expires_ms: m.ends_ms + LIFE_MS });
            }
            self.mint = None;
        }
        self.now = self.now.max(to);
    }

    fn start_mint(&mut self) {
        assert!(self.mint.is_none(), "two mints at once");
        let fate = if self.fates.is_empty() { Fate::Answers(300) } else { self.fates.remove(0) };
        self.mints_started += 1;
        let (after, fails) = match fate {
            Fate::Answers(ms) | Fate::Stalls(ms) => (ms, false),
            Fate::Fails(ms) => (ms, true),
        };
        self.mint = Some(RunningMint { started_ms: self.now, ends_ms: self.now + after, fails });
    }

    /// One caller, as `MacInstallIdentity.installToken()` runs it.
    fn call(&mut self) -> (Answer, u64) {
        let arrived = self.now;
        loop {
            let facts = LeaseFacts {
                now_ms: self.now,
                held: self.held.clone(),
                mint: self
                    .mint
                    .as_ref()
                    .map(|m| Mint { started_ms: m.started_ms, step: "POST /v1/auth/token".into() }),
            };
            let d = signin::lease(&facts);
            if d.cancel_mint {
                self.mint = None;
            }
            if d.start_mint {
                self.start_mint();
            }
            if d.use_held {
                let held = self.held.as_ref().expect("use_held with a token");
                assert!(self.now < held.expires_ms, "handed out an expired token at {}", self.now);
                return (Answer::Token, self.now - arrived);
            }
            if let Some(refusal) = d.refusal {
                assert_eq!(refusal["code"], signin::STALLED_CODE);
                let message = refusal["message"].as_str().unwrap_or_default().to_owned();
                assert!(
                    message.contains("POST /v1/auth/token"),
                    "the refusal names the step: {message}"
                );
                return (Answer::Refused(message), self.now - arrived);
            }
            let until = d.wait_until_ms.expect("a decision that neither answers nor waits");
            let mint = self.mint.as_ref().expect("a wait with no mint");
            let (ends, fails) = (mint.ends_ms, mint.fails);
            if ends <= until {
                self.advance(ends);
                if fails {
                    // The waiting caller gets the mint's own error at once.
                    return (Answer::Failed, self.now - arrived);
                }
            } else {
                self.advance(until);
            }
        }
    }
}

fn bound_ms() -> u64 {
    u64::try_from(MINT_BOUND.as_millis()).unwrap_or(u64::MAX)
}

/// `fault mint-stall` 30 s at a cold start: the caller hears the step within the bound, and the next caller
/// gets a token from a fresh mint instead of waiting behind the stalled one.
#[test]
fn mint_stall_30s_at_a_cold_start_names_the_step_within_the_bound() {
    let mut mac = Mac::new(vec![Fate::Stalls(30_000), Fate::Answers(400)]);
    let (answer, waited) = mac.call();
    assert!(matches!(answer, Answer::Refused(_)), "{answer:?}");
    assert!(waited <= bound_ms(), "waited {waited} ms");
    let (answer, waited) = mac.call();
    assert_eq!(answer, Answer::Token);
    assert!(waited <= 400);
    assert_eq!(mac.mints_started, 2);
}

/// `fault mint-stall` 30 s on a renewal: with a valid token held, every caller answers at once (the list
/// loads) while the renewal stalls; the stalled renewal is replaced and the token never lapses.
#[test]
fn mint_stall_30s_on_a_renewal_never_holds_a_call() {
    let mut mac = Mac::new(vec![Fate::Answers(200), Fate::Stalls(30_000), Fate::Answers(200)]);
    assert_eq!(mac.call().0, Answer::Token);
    let renew_at = signin::renew_at_ms(200, 200 + LIFE_MS);
    for step in 0..=40 {
        mac.advance(renew_at + step * 1_000);
        let (answer, waited) = mac.call();
        assert_eq!(answer, Answer::Token, "at +{step} s");
        assert_eq!(waited, 0, "at +{step} s");
    }
    assert_eq!(mac.mints_started, 3, "the stalled renewal was replaced once");
    let held = mac.held.as_ref().expect("a token");
    assert!(held.minted_ms > renew_at, "the renewal landed before the old token lapsed");
}

/// Seeded fault mix over two hours of callers: answers, failures and stalls of up to 30 s.
#[test]
fn seeded_mint_faults_keep_every_call_bounded_and_truthful() {
    let runs: u64 =
        std::env::var("CMUX_SIGNIN_FAULT_RUNS").ok().and_then(|v| v.parse().ok()).unwrap_or(50);
    let bound = bound_ms();
    for seed in 1..=runs {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let fates = (0..200)
            .map(|_| match rng.below(10) {
                0..=5 => Fate::Answers(50 + rng.below(2_000)),
                6 | 7 => Fate::Fails(50 + rng.below(5_000)),
                _ => Fate::Stalls(bound + rng.below(30_000)),
            })
            .collect();
        let mut mac = Mac::new(fates);
        while mac.now < 2 * 3_600_000 {
            let next = mac.now + rng.below(120_000);
            mac.advance(next);
            let valid_at_arrival = mac.held.as_ref().is_some_and(|h| {
                mac.now + u64::try_from(signin::EXPIRY_MARGIN.as_millis()).unwrap_or(0)
                    < h.expires_ms
            });
            let (answer, waited) = mac.call();
            assert!(waited <= bound, "seed {seed}: a caller waited {waited} ms at {}", mac.now);
            if valid_at_arrival {
                assert_eq!(
                    (answer, waited),
                    (Answer::Token, 0),
                    "seed {seed}: a held token did not answer at once"
                );
            }
        }
    }
}

#[test]
fn the_bound_is_what_the_relay_can_report() {
    assert!(MINT_BOUND < Duration::from_secs(25));
}
