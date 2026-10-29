//! Unit tests of the hub helpers that p10-stability-133 made panic-free (hub files a-l): each
//! keeps its answer, and input that reaches it from a peer or a file is refused, not a panic.

use super::*;
use std::collections::BTreeMap;

#[test]
fn a_peer_brief_that_is_not_an_object_is_not_recorded() {
    let briefs = super::dispatch::Briefs::default();
    // A peer's `brief` reply was indexed as an object before (`row["briefId"] = ...` panics).
    assert_eq!(briefs.put(json!("not a brief")), json!("not a brief"));
    assert_eq!(briefs.put(json!([1, 2])), json!([1, 2]));
    assert!(briefs.matching(|_| true).is_empty());
    let kept = briefs.put(json!({"briefId": "b-1", "status": "running"}));
    assert_eq!(kept["briefId"], "b-1");
    assert_eq!(briefs.matching(|_| true).len(), 1);
    let fresh = briefs.put(json!({"status": "starting"}));
    assert!(fresh["briefId"].as_str().is_some_and(|id| id.starts_with("brief-")));
}

#[test]
fn the_newest_bytes_start_on_a_character() {
    use super::btw::newest;
    assert_eq!(newest("short", 10), (false, "short"));
    assert_eq!(newest("abcdef", 3), (true, "def"));
    // "é" is two bytes: a cut inside it drops the whole character.
    assert_eq!(newest("aéb", 2), (true, "b"));
    assert_eq!(newest("aéb", 3), (true, "éb"));
    assert_eq!(newest("ééé", 0), (true, ""));
}

#[test]
fn the_capsule_tail_starts_on_a_character() {
    use super::handoff::capsule::tail;
    assert_eq!(tail("short", 10), "short");
    assert_eq!(tail("abcdef", 3), "def");
    assert_eq!(tail("aéb", 2), "b");
    assert_eq!(tail("日本語", 4), "語");
}

#[test]
fn a_closing_context_tag_is_made_inert_in_any_spelling() {
    use super::btw::neutralize_close;
    assert_eq!(neutralize_close("a </cmux-btw-context> b"), "a <\\/cmux-btw-context> b");
    assert_eq!(neutralize_close("< / CMUX-btw-context >"), "< \\/ CMUX-btw-context >");
    assert_eq!(neutralize_close("<b>é</b> <"), "<b>é</b> <");
    assert_eq!(neutralize_close("é<\u{3000}/cmux-btw-context"), "é<\u{3000}\\/cmux-btw-context");
}

#[test]
fn only_the_rules_tag_is_escaped() {
    use super::forum::neutral_tags;
    assert_eq!(neutral_tags("<cmux-rules-context>"), "&lt;cmux-rules-context>");
    assert_eq!(neutral_tags("</CMUX-RULES-CONTEXT>"), "&lt;/CMUX-RULES-CONTEXT>");
    assert_eq!(neutral_tags("é<b> <"), "é<b> <");
}

#[test]
fn a_spawn_root_reads_its_variables() {
    use super::launch_roots::expand_spawn_root;
    let home = Path::new("/home/me");
    let env = BTreeMap::from([("CODEX_HOME".to_owned(), "/srv/codex".to_owned())]);
    assert_eq!(
        expand_spawn_root("${CODEX_HOME}/sessions", &env, home),
        Some(PathBuf::from("/srv/codex/sessions"))
    );
    assert_eq!(
        expand_spawn_root("~/${UNSET:-x}/${CODEX_HOME}", &env, home),
        Some(PathBuf::from("/home/me/x//srv/codex"))
    );
    // No spawn variable, an unset one without a default, and an unclosed one: none.
    assert_eq!(expand_spawn_root("~/plain", &env, home), None);
    assert_eq!(expand_spawn_root("${UNSET}/a", &env, home), None);
    assert_eq!(expand_spawn_root("${CODEX_HOME", &env, home), None);
}

#[test]
fn hex_reads_pairs_of_lowercase_digits() {
    use super::approvers::unhex;
    assert_eq!(unhex("00ff10"), Some(vec![0, 255, 16]));
    assert_eq!(unhex(""), Some(vec![]));
    assert_eq!(unhex("abc"), None);
    assert_eq!(unhex("AB"), None);
    assert_eq!(unhex("zz"), None);
    assert_eq!(super::approvers::fingerprint(b"").len(), 16);
}

#[test]
fn a_permission_answer_lifts_its_meta() {
    use super::hosts::permission_answer;
    assert_eq!(
        permission_answer(json!({"outcome": "selected", "_meta": {"k": 1}})),
        json!({"outcome": {"outcome": "selected"}, "_meta": {"k": 1}})
    );
    assert_eq!(
        permission_answer(json!({"outcome": "cancelled"})),
        json!({"outcome": {"outcome": "cancelled"}})
    );
    assert_eq!(permission_answer(json!("cancelled")), json!({"outcome": "cancelled"}));
}

#[test]
fn a_message_body_is_the_text_between_its_rules() {
    use super::agent_pairs::message_body;
    let text = "[cmux agent message] from a\n---\nhi\n--- end of message m ---";
    assert_eq!(message_body(text), "hi");
    // The end marker before the body's start is not an end.
    let early = "[cmux agent message]\n--- end of message\n---\nbody";
    assert_eq!(message_body(early), "body");
    assert_eq!(message_body("[cmux agent message] no rule"), "[cmux agent message] no rule");
}
