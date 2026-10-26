//! A person's answers to an agent question (`question_answer::parse_answers`,
//! with `find_item` and `parse_choice` under it): `acpmux answer --answer
//! KEY=VALUE` and the TUI answer flow, against a question the agent wrote.
//!
//! Input: the first line is the permission request (or the bare question)
//! as JSON; each later line is one `--answer` argument.
//!
//! Invariant past "no panic": accepted answers are one JSON object.
#![no_main]

use acpmux::question_answer::{parse_answers, question, usage};
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

/// The most `--answer` arguments one input passes.
const MAX_ARGS: usize = 32;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    let mut lines = text.lines();
    let Some(Ok(request)) = lines.next().map(serde_json::from_str::<Value>) else { return };
    let asked = question(&request).unwrap_or(&request);
    let args: Vec<String> = lines.take(MAX_ARGS).map(str::to_owned).collect();
    let _ = usage(asked, "fuzz");
    if let Ok(answers) = parse_answers(asked, &args) {
        assert!(answers.is_object(), "answers are not an object: {answers}");
    }
});
