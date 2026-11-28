//! The marker line, its parse and the launch verdict, rule by rule.

use cmux_update_prewarm_core::ops::{OpError, call};
use cmux_update_prewarm_core::{
    MAX_REASON, Marker, MarkerState, Verdict, encode_marker, launch_verdict, parse_marker,
};
use serde_json::json;

const BUILD: &str = "4382263402601";

fn verdict(pre_warmed: bool, reason: &str, consume: bool) -> Verdict {
    Verdict { pre_warmed, reason: reason.to_owned(), consume }
}

fn skipped(reason: &str) -> MarkerState {
    MarkerState::Skipped(reason.to_owned())
}

#[test]
fn each_state_encodes_as_one_line() {
    assert_eq!(
        encode_marker(BUILD, &MarkerState::Started).as_deref(),
        Some("4382263402601 started\n")
    );
    assert_eq!(encode_marker(BUILD, &MarkerState::Main).as_deref(), Some("4382263402601 main\n"));
    assert_eq!(encode_marker(BUILD, &MarkerState::Full).as_deref(), Some("4382263402601 full\n"));
    assert_eq!(
        encode_marker(BUILD, &skipped("staged build is not newer")).as_deref(),
        Some("4382263402601 skipped staged build is not newer\n")
    );
    assert_eq!(encode_marker(BUILD, &skipped("  ")).as_deref(), Some("4382263402601 skipped\n"));
}

#[test]
fn a_build_that_would_not_read_back_is_refused() {
    assert_eq!(encode_marker("", &MarkerState::Main), None);
    assert_eq!(encode_marker("43 82", &MarkerState::Main), None);
    assert_eq!(encode_marker("4382\n", &MarkerState::Main), None);
    assert_eq!(encode_marker("\t4382", &MarkerState::Main), None);
}

#[test]
fn a_skip_reason_stays_one_trimmed_line_of_at_most_200_chars() {
    assert_eq!(
        encode_marker(BUILD, &skipped(" no\nhelper\r\nfound \n")).as_deref(),
        Some("4382263402601 skipped no helper  found\n")
    );
    let long = "é".repeat(MAX_REASON + 50);
    let line = encode_marker(BUILD, &skipped(&long)).unwrap_or_default();
    assert_eq!(line, format!("{BUILD} skipped {}\n", "é".repeat(MAX_REASON)));
    // A cut that ends on a space does not leave it.
    let spaced = format!("{} tail", "a".repeat(MAX_REASON - 1));
    assert_eq!(
        encode_marker(BUILD, &skipped(&spaced)).unwrap_or_default(),
        format!("{BUILD} skipped {}\n", "a".repeat(MAX_REASON - 1))
    );
}

#[test]
fn every_encoded_line_parses_back() {
    for state in [MarkerState::Started, MarkerState::Main, MarkerState::Full, skipped("disk full")]
    {
        let line = encode_marker(BUILD, &state).unwrap_or_default();
        assert_eq!(
            parse_marker(&line),
            Some(Marker { build: BUILD.to_owned(), state, legacy: false }),
            "{line:?}"
        );
    }
}

#[test]
fn the_legacy_form_is_a_full_run() {
    let legacy = Some(Marker { build: BUILD.to_owned(), state: MarkerState::Full, legacy: true });
    assert_eq!(parse_marker("4382263402601\n"), legacy);
    assert_eq!(parse_marker("4382263402601"), legacy);
    assert_eq!(parse_marker("4382263402601\r\n"), legacy);
}

#[test]
fn an_empty_or_unknown_marker_is_no_record() {
    assert_eq!(parse_marker(""), None);
    assert_eq!(parse_marker("\n"), None);
    assert_eq!(parse_marker("4382263402601 warm\n"), None);
    assert_eq!(parse_marker("4382263402601 main extra\n"), None);
    assert_eq!(parse_marker("4382263402601 MAIN\n"), None);
}

#[test]
fn no_build_or_no_record_leaves_the_marker() {
    assert_eq!(launch_verdict("", Some("4382263402601 main\n")), verdict(false, "no_build", false));
    assert_eq!(launch_verdict(BUILD, None), verdict(false, "no_record", false));
    assert_eq!(launch_verdict(BUILD, Some("")), verdict(false, "no_record", false));
    assert_eq!(
        launch_verdict(BUILD, Some("4382263402601 warm\n")),
        verdict(false, "no_record", false)
    );
}

#[test]
fn another_builds_marker_stays_for_its_install() {
    assert_eq!(
        launch_verdict(BUILD, Some("4382263409999 main\n")),
        verdict(false, "other_build:4382263409999", false)
    );
    assert_eq!(
        launch_verdict(BUILD, Some("4382263409999\n")),
        verdict(false, "other_build:4382263409999", false)
    );
}

#[test]
fn this_builds_marker_says_how_far_it_got_and_is_spent() {
    let cases = [
        ("4382263402601 started\n", verdict(false, "started_not_finished", true)),
        ("4382263402601 main\n", verdict(true, "main", true)),
        ("4382263402601 full\n", verdict(true, "full", true)),
        ("4382263402601\n", verdict(true, "full_legacy", true)),
        (
            "4382263402601 skipped staged build is not newer\n",
            verdict(false, "skipped:staged build is not newer", true),
        ),
    ];
    for (text, expect) in cases {
        assert_eq!(launch_verdict(BUILD, Some(text)), expect, "{text:?}");
    }
}

#[test]
fn the_ops_encode_and_read() {
    assert_eq!(
        call("marker.encode", &json!({"build": BUILD, "state": "main"})),
        Ok(json!({"line": "4382263402601 main\n"}))
    );
    assert_eq!(
        call("marker.encode", &json!({"build": BUILD, "state": "skipped", "reason": "no\nspace"})),
        Ok(json!({"line": "4382263402601 skipped no space\n"}))
    );
    assert_eq!(
        call("marker.encode", &json!({"build": BUILD, "state": "full", "reason": "ignored"})),
        Ok(json!({"line": "4382263402601 full\n"}))
    );
    assert_eq!(
        call("marker.verdict", &json!({"build": BUILD, "marker": "4382263402601 main\n"})),
        Ok(json!({"pre_warmed": true, "reason": "main", "consume": true}))
    );
    assert_eq!(
        call("marker.verdict", &json!({"build": BUILD, "marker": null})),
        Ok(json!({"pre_warmed": false, "reason": "no_record", "consume": false}))
    );
    assert_eq!(
        call("marker.verdict", &json!({"build": BUILD})),
        Ok(json!({"pre_warmed": false, "reason": "no_record", "consume": false}))
    );
}

#[test]
fn the_ops_refuse_what_they_do_not_take() {
    assert_eq!(call("marker.nope", &json!({})), Err(OpError::Unknown));
    assert_eq!(
        call("marker.encode", &json!({"build": BUILD, "state": "warm"})),
        Err(OpError::Invalid)
    );
    assert_eq!(
        call("marker.encode", &json!({"build": "", "state": "main"})),
        Err(OpError::Invalid)
    );
    assert_eq!(call("marker.encode", &json!({"state": "main"})), Err(OpError::Invalid));
    assert_eq!(call("marker.verdict", &json!({"marker": "x"})), Err(OpError::Invalid));
    assert_eq!(
        call("marker.verdict", &json!({"build": BUILD, "marker": 3})),
        Err(OpError::Invalid)
    );
}
