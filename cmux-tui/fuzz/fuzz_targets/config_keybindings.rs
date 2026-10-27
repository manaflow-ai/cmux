//! keybindings.json: `parse`, stroke `normalize` and the in-place edits
//! (`set`, `remove`, `reset`). An edit only writes over a readable file and
//! gives a file that still reads; a stroke `normalize` accepts is its own
//! normal form.
//!
//! Input: a first line of edit parameters (`key<TAB>command<TAB>when`), then
//! the file text.
#![no_main]

use cmux_config::keybindings::edit::{self, Target};
use cmux_config::keybindings::{MAX_STROKES, Problem, parse, stroke};
use libfuzzer_sys::fuzz_target;

fn unreadable(parsed: &cmux_config::keybindings::Parsed) -> bool {
    parsed.diagnostics.iter().any(|diagnostic| diagnostic.problem == Problem::UnreadableFile)
}

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let (params, source) = text.split_once('\n').unwrap_or((text, ""));
    let mut fields = params.splitn(3, '\t');
    let key = fields.next().unwrap_or_default();
    let command = fields.next().unwrap_or_default();
    let when = fields.next().filter(|when| !when.is_empty()).map(str::to_string);

    for part in key.split_whitespace() {
        if let Some(normal) = stroke::normalize(part) {
            assert_eq!(stroke::normalize(&normal).as_deref(), Some(normal.as_str()));
        }
    }

    let parsed = parse(source);
    for entry in &parsed.entries {
        assert!(entry.keys.len() <= MAX_STROKES, "an entry kept more than {MAX_STROKES} strokes");
        assert!(entry.removal || !entry.keys.is_empty(), "a binding loaded without a stroke");
    }

    let target = Target { command: command.to_string(), key: key.to_string(), when };
    let edits = [
        edit::set(source, &target, None, None),
        edit::set(source, &target, None, Some(&target)),
        edit::remove(source, &target),
        edit::reset(source, command),
    ];
    for next in edits.into_iter().flatten() {
        assert!(!unreadable(&parsed), "an edit wrote over an unreadable keybindings file");
        assert!(!unreadable(&parse(&next)), "an edit produced an unreadable keybindings file");
    }
});
