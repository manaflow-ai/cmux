//! Lawrence, 2026-11-20: a Home row's preview of the Chief's before/after
//! table was its raw Markdown ("| | Before | After ||---|…"), here at the
//! source and so on every view that reads the daemon's rows (the iPhone's Mac
//! Home list, the CLI). An agent's preview says its words; a person's text
//! stays as typed.

use super::*;
use serde_json::json;

const ME: &str = "user_local";
const CHIEF: &str = "agent_chief";

fn message(author: &str, text: &str) -> Message {
    serde_json::from_value(json!({
        "id": "m1", "conversation": "c1", "seq": 1, "client_msg_id": "k1", "author": author,
        "parts": [{"type": "text", "text": text}], "created_at": "2026-11-20T00:00:00.000Z"
    }))
    .unwrap_or_else(|e| panic!("message: {e}"))
}

fn summary(last: &Message) -> Summary {
    serde_json::from_value(json!({
        "id": "c1", "owner": "local", "title": "", "last_seq": 1, "rev": 1,
        "created_at": "2026-11-20T00:00:00.000Z", "updated_at": "2026-11-20T00:00:00.000Z",
        "participants": [
            {"id": ME, "kind": "human", "display_name": "Me"},
            {"id": CHIEF, "kind": "agent", "display_name": "Chief", "agent_class": "mux"}
        ],
        "last_message": last, "read_cursors": {}
    }))
    .unwrap_or_else(|e| panic!("summary: {e}"))
}

fn row_preview(author: &str, text: &str, words: Words) -> Option<String> {
    let last = message(author, text);
    let input = HomeInboxInput {
        me: ME,
        states: HashMap::new(),
        chief_names: BTreeMap::new(),
        typing: HashMap::new(),
        running: HashMap::new(),
        deleted_chiefs: BTreeSet::new(),
        preview_words: words,
    };
    home_inbox(&[summary(&last)], &input).into_iter().next().and_then(|row| row.preview)
}

const TABLE: &str = "| | Before | After |\n|---|---|---|\n| Light | ![before, light](/tmp/bl.png) | ![after, light](/tmp/al.png) |";

#[test]
fn the_chiefs_table_previews_as_its_columns() {
    assert_eq!(
        row_preview(CHIEF, TABLE, Words::english()).as_deref(),
        Some("Table: Before / After")
    );
    assert_eq!(
        row_preview(CHIEF, &format!("Shots below.\n\n{TABLE}"), Words::english()).as_deref(),
        Some("Shots below. Table: Before / After")
    );
}

#[test]
fn the_chiefs_links_pictures_and_emphasis_preview_as_words() {
    let text =
        "**Done.** See [PR 12](https://github.com/manaflow-ai/cmux/pull/12) ![shot](/tmp/a.png)";
    assert_eq!(row_preview(CHIEF, text, Words::english()).as_deref(), Some("Done. See PR 12"));
    assert_eq!(
        row_preview(CHIEF, "![a](/a.png) ![b](/b.png)", Words::english()).as_deref(),
        Some("2 images")
    );
}

#[test]
fn the_words_follow_the_persons_language() {
    assert_eq!(
        row_preview(CHIEF, TABLE, Words::for_locale("ja-JP")).as_deref(),
        Some("表: Before / After")
    );
}

#[test]
fn a_persons_text_stays_as_typed() {
    assert_eq!(row_preview(ME, "a | b **c**", Words::english()).as_deref(), Some("a | b **c**"));
}
