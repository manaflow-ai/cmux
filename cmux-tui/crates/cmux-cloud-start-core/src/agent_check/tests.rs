use super::*;

/// 2026-11-11T04:00:00Z, the night red 1 was seen.
const NOW: i64 = 1_794_369_600;
/// 2026-11-14T13:00:00Z, the reset Leo's start was told: "resets Nov 14, 1pm (UTC)".
const NOV_14_1PM: i64 = 1_794_661_200;

fn probe(status: u16, headers: &[(&str, &str)]) -> Probe {
    Probe {
        status,
        headers: headers.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
    }
}

/// The reply a used-up weekly limit gets: a 429 with the unified headers (their names as a real
/// Claude Code response logs them, `optchat-chief/measure/test_team_eval.py`).
fn weekly_spent() -> Probe {
    probe(
        429,
        &[
            ("anthropic-ratelimit-unified-status", "rejected"),
            ("anthropic-ratelimit-unified-representative-claim", "seven_day"),
            ("anthropic-ratelimit-unified-7d-status", "rejected"),
            ("anthropic-ratelimit-unified-7d-utilization", "1.02"),
            ("anthropic-ratelimit-unified-7d-reset", "1794661200"),
            ("anthropic-ratelimit-unified-5h-status", "allowed"),
            ("anthropic-ratelimit-unified-5h-reset", "1794380400"),
            ("anthropic-ratelimit-unified-reset", "1794661200"),
            ("request-id", "req_x"),
        ],
    )
}

fn claude(probe: Probe) -> Request {
    Request { harness: Some("claude".into()), model: None, probe: Some(probe), now: NOW }
}

#[test]
fn a_spent_weekly_limit_refuses_before_the_lease_with_its_reset_and_the_way_on() {
    let answer = check(&claude(weekly_spent()));
    let refusal = answer.refusal.expect("refused");
    assert_eq!(refusal.code, "agent.limit_reached");
    assert_eq!(
        refusal.message,
        "Claude's weekly limit is used up until Nov 14, 1pm UTC. Pick Codex, or start after then."
    );
    assert_eq!(answer.limit, Some(Limit { window: Window::Weekly, resets_at: Some(NOV_14_1PM) }));
    // The answer stands until the reset: no start before then asks Anthropic again.
    assert_eq!(answer.fresh_until, NOV_14_1PM);
}

#[test]
fn the_default_agent_and_claude_profiles_are_claude() {
    for harness in [None, Some(""), Some("claude-sr2"), Some("team/Claude")] {
        let request = Request { harness: harness.map(str::to_owned), ..claude(weekly_spent()) };
        assert!(check(&request).refusal.is_some(), "{harness:?}");
    }
}

#[test]
fn other_agents_never_read_claudes_limit() {
    for harness in ["codex", "opencode", "pi"] {
        let request = Request { harness: Some(harness.into()), ..claude(weekly_spent()) };
        assert_eq!(check(&request).refusal, None, "{harness}");
        assert!(!probes(Some(harness)));
    }
    assert!(probes(None) && probes(Some("claude")));
}

#[test]
fn a_spent_session_window_names_it_and_its_time_today() {
    let answer = check(&claude(probe(
        429,
        &[
            ("anthropic-ratelimit-unified-status", "rejected"),
            ("anthropic-ratelimit-unified-representative-claim", "five_hour"),
            ("anthropic-ratelimit-unified-5h-reset", "1794382200"), // 07:30Z the same day
        ],
    )));
    assert_eq!(
        answer.refusal.unwrap().message,
        "Claude's 5-hour limit is used up until 7:30am UTC. Pick Codex, or start after then."
    );
}

#[test]
fn the_window_falls_back_to_the_rejected_one_and_the_reset_to_the_unified_one() {
    let found = limit(&probe(
        200,
        &[
            ("Anthropic-Ratelimit-Unified-Status", "rejected"),
            ("anthropic-ratelimit-unified-7d-status", "rejected"),
            ("anthropic-ratelimit-unified-reset", "1794661200"),
        ],
    ));
    assert_eq!(found, Some(Limit { window: Window::Weekly, resets_at: Some(NOV_14_1PM) }));
    let unknown = check(&claude(probe(429, &[("anthropic-ratelimit-unified-status", "rejected")])));
    assert_eq!(
        unknown.refusal.unwrap().message,
        "Claude's usage limit is used up. Pick Codex, or start once it resets."
    );
    assert_eq!(unknown.fresh_until, NOW + SPENT_UNKNOWN_RESET_SECONDS);
}

/// A model's own weekly window stops only a start of that model, and resets at the unified reset.
#[test]
fn a_models_own_weekly_window_stops_only_that_model() {
    let opus_spent = probe(
        429,
        &[
            ("anthropic-ratelimit-unified-status", "rejected"),
            ("anthropic-ratelimit-unified-representative-claim", "seven_day_opus"),
            ("anthropic-ratelimit-unified-7d-reset", "1794900000"),
            ("anthropic-ratelimit-unified-reset", "1794661200"),
        ],
    );
    let found = limit(&opus_spent);
    assert_eq!(found, Some(Limit { window: Window::WeeklyOpus, resets_at: Some(NOV_14_1PM) }));
    let with = |model: Option<&str>| {
        check(&Request { model: model.map(str::to_owned), ..claude(opus_spent.clone()) })
    };
    assert_eq!(
        with(Some("claude-opus-5-5")).refusal.unwrap().message,
        "Claude's weekly Opus limit is used up until Nov 14, 1pm UTC. Pick Codex, or start after then."
    );
    assert!(with(Some("opus")).refusal.is_some());
    // Another model, or the harness default (unknown here): the start goes on.
    for model in [Some("claude-sonnet-5-5"), Some("haiku"), None] {
        let answer = with(model);
        assert_eq!(
            (answer.refusal, answer.fresh_until),
            (None, NOW + ALLOWED_FRESH_SECONDS),
            "{model:?}"
        );
    }
    // The 5-hour and the whole weekly windows stop every model.
    assert!(
        check(&Request { model: Some("claude-sonnet-5-5".into()), ..claude(weekly_spent()) })
            .refusal
            .is_some()
    );
}

#[test]
fn only_a_known_used_up_limit_refuses() {
    // An allowed answer, a warning, a rejected login, a reply with no limit headers, a reset already past.
    let allowed = probe(
        200,
        &[
            ("anthropic-ratelimit-unified-status", "allowed"),
            ("anthropic-ratelimit-unified-7d-utilization", "0.53"),
        ],
    );
    let warning = probe(200, &[("anthropic-ratelimit-unified-status", "allowed_warning")]);
    let unauthorized = probe(401, &[]);
    let bare_429 = probe(429, &[("retry-after", "30")]);
    let past = probe(
        429,
        &[
            ("anthropic-ratelimit-unified-status", "rejected"),
            ("anthropic-ratelimit-unified-reset", "1794369000"),
        ],
    );
    for reply in [allowed, warning, unauthorized, bare_429, past] {
        let answer = check(&claude(reply.clone()));
        assert_eq!(answer.refusal, None, "{reply:?}");
        assert_eq!(answer.fresh_until, NOW + ALLOWED_FRESH_SECONDS, "{reply:?}");
    }
    // No probe (no login to carry, or it never answered): go on, and ask again next time.
    let none = check(&Request { probe: None, ..claude(weekly_spent()) });
    assert_eq!((none.refusal, none.fresh_until), (None, NOW));
}

#[test]
fn resets_read_as_claude_code_says_them() {
    assert_eq!(utc_words(NOV_14_1PM, NOW), "Nov 14, 1pm UTC");
    assert_eq!(utc_words(NOV_14_1PM + 30 * 60, NOW), "Nov 14, 1:30pm UTC");
    assert_eq!(utc_words(1_794_355_200, 0), "Nov 11, 12am UTC"); // midnight
    assert_eq!(utc_words(1_794_398_400, NOW), "12pm UTC"); // noon the same day
    assert_eq!(utc_words(1_798_761_600, NOW), "Jan 1, 12am UTC"); // 2027-01-01
    assert_eq!(utc_words(1_803_859_200, NOW), "Mar 1, 12am UTC"); // 2027-03-01, after February
}

#[test]
fn the_answer_crosses_the_ffi_in_camel_case() {
    let request: Request = serde_json::from_value(serde_json::json!({
        "harness": "claude",
        "now": NOW,
        "probe": {"status": 429, "headers": {"anthropic-ratelimit-unified-status": "rejected",
                                            "anthropic-ratelimit-unified-representative-claim": "seven_day",
                                            "anthropic-ratelimit-unified-7d-reset": "1794661200"}},
    }))
    .unwrap();
    let answer = serde_json::to_value(check(&request)).unwrap();
    assert_eq!(answer["refusal"]["code"], "agent.limit_reached");
    assert_eq!(answer["limit"]["window"], "weekly");
    assert_eq!(answer["limit"]["resetsAt"], NOV_14_1PM);
    assert_eq!(answer["freshUntil"], NOV_14_1PM);
}
