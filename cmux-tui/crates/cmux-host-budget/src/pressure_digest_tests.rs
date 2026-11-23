use super::*;
use crate::{ShadowInputs, inputs_digest, shadow_verdict};
use serde_json::Value;

/// The same file is in leo-workspace (`tools/testdata/pressure-digest-v1.json`),
/// where lane-place's Python `pressure_digest` must give the same digests.
const VECTORS: &str = include_str!("../testdata/pressure-digest-v1.json");

/// Pinned in both repositories' tests: `calm-32-core-host`'s digest.
const CALM_HOST_DIGEST: &str = "fnv1a64:f3cec53d0a7499b0";

fn vectors() -> Vec<Value> {
    let file: Value = serde_json::from_str(VECTORS).expect("the vector file is JSON");
    assert_eq!(file["version"], "pressure-digest/1");
    file["vectors"].as_array().expect("vectors is an array").clone()
}

fn parse(v: &Value) -> ShadowInputs {
    serde_json::from_value(v["input"].clone()).expect("vector input parses as ShadowInputs")
}

#[test]
fn every_vector_gives_its_pressure_digest() {
    let all = vectors();
    assert!(all.len() >= 9, "the file lost vectors");
    for v in &all {
        let name = v["name"].as_str().unwrap_or("?");
        let inputs = parse(v);
        assert_eq!(canonical_pressure(&inputs), v["canonical"].as_str().unwrap(), "{name}: text");
        assert_eq!(pressure_digest(&inputs), v["pressure_digest"].as_str().unwrap(), "{name}");
        // The Python port's inputs_digest agrees with the crate's on these inputs too.
        assert_eq!(inputs_digest(&inputs), v["inputs_digest"].as_str().unwrap(), "{name}");
        let verdict = shadow_verdict(&inputs);
        assert_eq!(verdict.pressure_digest, pressure_digest(&inputs), "{name}: verdict");
        assert_eq!(verdict.host_short, host_short(&inputs.host), "{name}: host_short");
    }
}

#[test]
fn the_pinned_digest_is_the_calm_hosts() {
    let calm = vectors().into_iter().find(|v| v["name"] == "calm-32-core-host").expect("vector");
    assert_eq!(pressure_digest(&parse(&calm)), CALM_HOST_DIGEST);
}

#[test]
fn clock_state_and_full_name_do_not_move_it_but_a_reading_does() {
    let by_name = |n: &str| {
        let v = vectors().into_iter().find(|v| v["name"] == n).expect("vector");
        parse(&v)
    };
    let calm = by_name("calm-32-core-host");
    let later = by_name("same-readings-other-clock-and-state");
    assert_eq!(pressure_digest(&calm), pressure_digest(&later));
    assert_ne!(inputs_digest(&calm), inputs_digest(&later));
    assert_eq!(pressure_digest(&calm), pressure_digest(&by_name("same-swap-fraction-other-bytes")));
    assert_ne!(pressure_digest(&calm), pressure_digest(&by_name("busier-load")));
}

#[test]
fn host_short_keeps_the_name_up_to_its_first_dot() {
    assert_eq!(host_short("GCP-Lane.example.ts.net"), "gcp-lane");
    assert_eq!(host_short(" lane "), "lane");
    assert_eq!(host_short(""), "");
    assert_eq!(host_short(".hidden"), "");
}
