//! acpmux route files: the TOML `routes::load` reads (`RouteFile` then
//! `routes::validate`), the JSON params of the `route add`/`edit` RPC
//! (`routes::file_from_json`) and route kind names (`RouteKind::parse`).
//!
//! Invariant past "no panic": a route file that passes `validate` writes
//! TOML (as `routes::add` writes it) that loads back as the same file.
#![no_main]

use acpmux::routes::{RouteFile, RouteKind, file_from_json, validate};
use libfuzzer_sys::fuzz_target;

fn round_trip(file: &RouteFile) {
    let text = toml::to_string_pretty(file).expect("a route file serializes");
    let again: RouteFile = toml::from_str(&text).expect("a written route file reads back");
    assert_eq!(&again, file, "a route file changes when written: {text}");
    assert!(validate(&again).is_ok(), "a written route file stops validating: {text}");
}

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    let _ = RouteKind::parse(text);
    if let Ok(file) = toml::from_str::<RouteFile>(text)
        && validate(&file).is_ok()
    {
        round_trip(&file);
    }
    if let Ok(params) = serde_json::from_str(text)
        && let Ok(file) = file_from_json(&params)
    {
        round_trip(&file);
    }
});
