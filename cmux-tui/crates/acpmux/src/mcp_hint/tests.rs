use super::*;
use serde_json::json;

const TOOLS: [&str; 6] = ["send", "team_send", "team_inbox", "ls", "last", "info"];

#[test]
fn a_typo_names_the_nearest_tool() {
    assert_eq!(
        unknown_tool("team_sned", TOOLS),
        "unknown tool: team_sned; did you mean team_send?"
    );
    assert_eq!(unknown_tool("snd", TOOLS), "unknown tool: snd; did you mean send?");
    assert_eq!(unknown_tool("lats", TOOLS), "unknown tool: lats; did you mean last?");
    assert_eq!(
        unknown_tool("team_inbx", TOOLS),
        "unknown tool: team_inbx; did you mean team_inbox?"
    );
}

#[test]
fn an_oversized_name_is_answered_at_once_without_a_hint() {
    // Megabytes of name: no matrix is built for it (it used to allocate about name x tool cells).
    let huge = "team_send".repeat(800_000);
    let started = std::time::Instant::now();
    assert_eq!(nearest(&huge, TOOLS), None);
    assert_eq!(nearest(&"x".repeat(MAX_NAME + 1), TOOLS), None);
    assert!(started.elapsed() < std::time::Duration::from_secs(1), "{:?}", started.elapsed());
    // Names far apart in length are not compared; a typo still is.
    assert_eq!(nearest("team_send_with_a_long_tail", TOOLS), None);
    assert_eq!(nearest("team_sendd", TOOLS), Some("team_send"));
}

#[test]
fn a_name_in_another_case_or_a_prefix_names_the_tool() {
    assert_eq!(nearest("Team_Send", TOOLS), Some("team_send"));
    assert_eq!(nearest("INFO", TOOLS), Some("info"));
    assert_eq!(nearest("team_in", TOOLS), Some("team_inbox"));
}

#[test]
fn nothing_close_keeps_the_bare_answer() {
    assert_eq!(unknown_tool("nope", TOOLS), "unknown tool: nope");
    assert_eq!(unknown_tool("", TOOLS), "unknown tool: ");
    assert_eq!(unknown_tool("xy", TOOLS), "unknown tool: xy");
    assert_eq!(unknown_tool("start_session", TOOLS), "unknown tool: start_session");
    assert_eq!(unknown_tool("anything", []), "unknown tool: anything");
    // A known name is never its own hint.
    assert_eq!(nearest("send", ["send"]), None);
}

#[test]
fn a_tie_goes_to_the_first_in_list_order() {
    assert_eq!(nearest("bg_lst", ["bg_list", "bg_last"]), Some("bg_list"));
    assert_eq!(nearest("bg_lst", ["bg_last", "bg_list"]), Some("bg_last"));
    // The closest wins over an earlier, farther one.
    assert_eq!(nearest("bg_sto", ["bg_star", "bg_stop"]), Some("bg_stop"));
    assert_eq!(nearest("team", ["team_send", "team_inbox"]), Some("team_send"));
}

#[test]
fn names_reads_a_tools_list() {
    let tools = json!([{"name": "announce"}, {"description": "no name"}, {"name": "ack"}]);
    assert_eq!(names(&tools).collect::<Vec<_>>(), ["announce", "ack"]);
    assert_eq!(names(&json!({})).count(), 0);
    assert_eq!(
        unknown_tool("anounce", names(&tools)),
        "unknown tool: anounce; did you mean announce?"
    );
}

#[test]
fn distance_counts_a_swap_as_one_edit() {
    let d =
        |a: &str, b: &str| distance(&a.chars().collect::<Vec<_>>(), &b.chars().collect::<Vec<_>>());
    assert_eq!(d("kitten", "sitting"), 3);
    assert_eq!(d("ab", "ba"), 1);
    assert_eq!(d("", "abc"), 3);
    assert_eq!(d("same", "same"), 0);
    assert_eq!(d("abc", ""), 3);
    assert_eq!(d("abcd", "acbd"), 1);
    assert_eq!(d("team_sned", "team_send"), 1);
    // Optimal string alignment edits no substring twice: "ca" to "abc" is 3, not 2.
    assert_eq!(d("ca", "abc"), 3);
}
