//! The person's config files (cmux.json, keybindings.json; JSONC text a
//! person or another program wrote): parse, the edits cmux makes in place,
//! and the small text parsers for values inside them.
#![no_main]

use cmux_config::{jsonc, keybindings, keypath, text::ThemeSpec};
use libfuzzer_sys::fuzz_target;
use serde_json::json;

fuzz_target!(|data: &[u8]| {
    let Some((&selector, rest)) = data.split_first() else { return };
    let source = String::from_utf8_lossy(rest);
    let _ = jsonc::parse(&source);
    let _ = keybindings::parse(&source);
    let _ = ThemeSpec::parse(&source);
    let _ = keypath::key_path(&source);
    let path: Vec<String> = match selector % 4 {
        0 => vec!["terminal".into(), "fontSize".into()],
        1 => vec!["a".into()],
        2 => vec!["x".into(), "y".into(), "z".into()],
        _ => Vec::new(),
    };
    let value = json!({"k": [1, "two", null]});
    let index = usize::from(selector >> 2);
    let _ = jsonc::set(&source, &path, &value);
    let _ = jsonc::remove(&source, &path);
    let _ = jsonc::array_spans(&source);
    let _ = jsonc::array_append(&source, &value);
    let _ = jsonc::array_remove(&source, index);
    let _ = jsonc::array_replace(&source, index, &value);
});
