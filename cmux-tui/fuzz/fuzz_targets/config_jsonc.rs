//! The settings file reader and editor (`cmux_config::jsonc`): the text of
//! `~/.config/cmux/cmux-next.json` and `keybindings.json`, which a person,
//! a sync tool or another program may leave in any state.
//!
//! Properties, beyond "no crash, leak or hang":
//! - text that parses also strips;
//! - an edit of text that parses (set, remove, array append and replace)
//!   gives text that still parses, so cmux never writes a settings file it
//!   cannot read back;
//! - array element spans lie inside the text, in order.

#![no_main]

use cmux_config::jsonc;
use libfuzzer_sys::fuzz_target;
use serde_json::{Value, json};

fn assert_parses(edited: Result<String, jsonc::JsoncError>, edit: &str) {
    if let Ok(text) = edited {
        assert!(jsonc::parse(&text).is_ok(), "{edit} wrote text that does not parse: {text:?}");
    }
}

fuzz_target!(|data: &[u8]| {
    let Ok(source) = std::str::from_utf8(data) else { return };
    let parsed = jsonc::parse(source);
    let stripped = jsonc::strip(source);
    if parsed.is_ok() {
        assert!(stripped.is_ok(), "text that parses does not strip");
    }

    if let Ok(spans) = jsonc::array_spans(source) {
        let mut previous_end = 0;
        for (start, end) in spans {
            assert!(previous_end <= start && start <= end && end <= source.len(), "bad span");
            previous_end = end;
        }
    }

    let Ok(root) = parsed else { return };
    let value = json!({ "fuzz": [1, "two", null] });
    match root {
        Value::Object(_) => {
            let path = ["terminal".to_owned(), "fuzz".to_owned()];
            assert_parses(jsonc::set(source, &path, &value), "set");
            assert_parses(jsonc::remove(source, &path), "remove");
            let first = ["terminal".to_owned()];
            assert_parses(jsonc::set(source, &first, &value), "set at the root");
            assert_parses(jsonc::remove(source, &first), "remove at the root");
        }
        Value::Array(_) => {
            assert_parses(jsonc::array_append(source, &value), "array append");
            assert_parses(jsonc::array_replace(source, 0, &value), "array replace");
            assert_parses(jsonc::array_remove(source, 0), "array remove");
        }
        _ => {}
    }
});
