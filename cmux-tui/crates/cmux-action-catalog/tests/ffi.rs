//! The C ABI the macOS app reads the catalog through.

use cmux_action_catalog::ffi::{
    ERR_NULL, OK, cmux_action_catalog_abi_version, cmux_action_catalog_json,
};
use std::time::Instant;

fn catalog(locale: &str) -> serde_json::Value {
    let mut ptr = std::ptr::null();
    let mut len = 0usize;
    // SAFETY: `locale` is a live slice and both out pointers are locals.
    let status =
        unsafe { cmux_action_catalog_json(locale.as_ptr(), locale.len(), &mut ptr, &mut len) };
    assert_eq!(status, OK);
    // SAFETY: on OK the library hands out `len` bytes it keeps for the life of the process.
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    serde_json::from_slice(bytes).expect("catalog JSON")
}

fn title(catalog: &serde_json::Value, id: &str) -> String {
    let actions = catalog["actions"].as_array().expect("actions");
    let action = actions.iter().find(|a| a["id"] == id).expect("the action");
    action["title"].as_str().expect("a title").to_owned()
}

#[test]
fn c_abi_catalog_in_each_language() {
    assert_eq!(cmux_action_catalog_abi_version(), 1);
    let started = Instant::now();
    let english = catalog("");
    let first = started.elapsed();
    let started = Instant::now();
    let again = catalog("en-US");
    let cached = started.elapsed();
    eprintln!("catalog JSON: first build and parse {first:?}, cached {cached:?}");
    let started = Instant::now();
    let text = cmux_action_catalog::json::catalog(1);
    eprintln!("catalog JSON (ja, {} bytes): build {:?}", text.len(), started.elapsed());
    let started = Instant::now();
    let text = cmux_action_catalog::json::catalog(0);
    eprintln!("catalog JSON (en, {} bytes): build {:?}", text.len(), started.elapsed());
    assert_eq!(english, again);
    assert_eq!(english["locale"], "en");
    assert_eq!(title(&english, "newSurface"), "New Terminal Tab");
    let japanese = catalog("ja-JP");
    assert_eq!(japanese["locale"], "ja");
    assert_ne!(title(&japanese, "newSurface"), "New Terminal Tab");
    assert_eq!(catalog("xx")["locale"], "en");
    assert_eq!(catalog("pt_BR")["locale"], "pt-BR");
}

#[test]
fn c_abi_null_out_pointers_are_refused() {
    let mut len = 0usize;
    // SAFETY: a null `json` out pointer is the case under test; nothing is written.
    let status =
        unsafe { cmux_action_catalog_json(std::ptr::null(), 0, std::ptr::null_mut(), &mut len) };
    assert_eq!(status, ERR_NULL);
}
