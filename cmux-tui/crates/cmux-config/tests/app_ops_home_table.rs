//! The `home_table.*` ops the Mac app's Home transcript calls through `cmux_settings_call`.

use cmux_config::app_ops::{OpError, call};
use serde_json::json;

#[test]
fn segments_answer_text_and_tables() {
    let out =
        call("home_table.segments", &json!({ "text": "hi\n| a | b |\n|:-:|--:|\n| 1 | 2 |\nbye" }))
            .unwrap();
    assert_eq!(
        out,
        json!({ "segments": [
            { "text": "hi" },
            { "table": { "header": ["a", "b"], "alignments": ["center", "trailing"], "rows": [["1", "2"]] },
              "raw": "| a | b |\n|:-:|--:|\n| 1 | 2 |" },
            { "text": "bye" },
        ] })
    );
}

#[test]
fn a_cell_answers_its_text_bold_links_and_images() {
    let out = call("home_table.cell", &json!({ "markdown": "**PR** [#7](https://github.com/o/r/pull/7) ![s](cmux-attachment:h)" })).unwrap();
    assert_eq!(
        out,
        json!({ "text": "PR #7", "bold": [[0, 2]], "links": ["https://github.com/o/r/pull/7"], "images": [{ "alt": "s", "source": "cmux-attachment:h" }] })
    );
}

#[test]
fn a_plan_card_answers_rows_or_nothing() {
    let table = json!({ "header": ["Task", "Owner", "Status"], "rows": [
        ["Inspector [#3](https://github.com/o/r/pull/3)", "a10 (new)", "waiting on CI"],
        ["Docs", "a5"],
    ] });
    let out = call("home_table.plan_card", &json!({ "table": table })).unwrap();
    assert_eq!(
        out,
        json!({ "rows": [
            { "title": "Inspector #3", "owner": "a10", "owner_note": "new", "pull_requests": ["https://github.com/o/r/pull/3"], "written": "waitingOnCI" },
            { "title": "Docs", "owner": "a5", "pull_requests": [] },
        ] })
    );
    let plain = json!({ "header": ["Check", "Time"], "rows": [["guards", "4m"]] });
    assert_eq!(call("home_table.plan_card", &json!({ "table": plain })).unwrap(), json!({}));
}

#[test]
fn columns_hashes_and_pull_requests() {
    assert_eq!(
        call("home_table.columns", &json!({ "natural": [70, 900, 500], "available": 700 }))
            .unwrap(),
        json!({ "widths": [70.0, 405.0, 225.0] })
    );
    let text = "| a | b |\n|---|---|\n| ![x](cmux-attachment:h2) | ![y](cmux-attachment:h1) |";
    assert_eq!(
        call("home_table.attachment_hashes", &json!({ "text": text })).unwrap(),
        json!({ "hashes": ["h1", "h2"] })
    );
    assert_eq!(
        call("home_table.pull_request", &json!({ "link": "https://github.com/O/R/pull/9/files" }))
            .unwrap(),
        json!({ "key": "o/r#9", "url": "https://github.com/o/r/pull/9" })
    );
    assert_eq!(
        call("home_table.pull_request", &json!({ "link": "https://example.com" })).unwrap(),
        json!({})
    );
}

#[test]
fn bad_requests_are_invalid() {
    assert!(matches!(call("home_table.cell", &json!({})), Err(OpError::Invalid(_))));
    assert!(matches!(
        call("home_table.columns", &json!({ "natural": ["x"], "available": 1 })),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        call("home_table.plan_card", &json!({ "table": { "header": ["a"] } })),
        Err(OpError::Invalid(_))
    ));
}
