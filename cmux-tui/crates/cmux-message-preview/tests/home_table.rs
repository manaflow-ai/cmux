//! The Home transcript's tables: the cases of MessagesLabHome's HomeTableCardTests (the
//! splitter, the plan card, owner ids, column widths, attachment pictures), and the places
//! where reading text as Swift does matters (graphemes, UTF-16 bold ranges, whitespace).

use cmux_message_preview::home_table::{
    Alignment, Image, MIN_COLUMN, Segment, Table, WrittenState, attachment_hashes, cell, cells,
    column_widths, note, owner_id, plan_card, pull_request_key, pull_request_url, segments,
    written_state,
};

/// Chief chat message 137, 2026-10-20, as the Chief wrote it.
const REPLY: &str = r#"I've handed out all six first PRs from the [nightly-train design](https://github.com/teamleaderleo/leo-workspace/pull/624). Nothing has landed yet.

| Design PR | What it builds | Who |
|---|---|---|
| 1 + 2 | Lasting canary results, a planner for each night's build, and a workflow that reverts the newest change or bisects to find the bad one, plus the guard for promoting a build to main | **a12** (new; workspace "a12 · Nightly train and canary", group cmux-next app) |
| 3 | A map from changed files to the tests that cover them, and fast checks for each change in the batch | a7, added to its ship-guard work |
| 4 | A banner that offers the roll-back from [#22590](https://github.com/manaflow-ai/cmux/pull/22590) when a build was pulled | a4, once #22590 lands |
| 5 | Canary checks that only report for the first week, then block bad builds, and a fix-forward run on every pull | **a13** (new; workspace "a13 · Train canary verification", group cmux-next app) |
| 6 | An in-app engine that runs agent workflows, saves their steps and can resume them, plus a sidebar group for running workflows | **a14** (new; workspace "a14 · Native workflows runtime", group Agents & routing) |

The design asked for a separate session for PR 6. I gave it to a14 instead, so it stays with the rest of the work."#;

fn table(text: &str) -> Option<Table> {
    segments(text).into_iter().find_map(|s| match s {
        Segment::Table { table, .. } => Some(table),
        Segment::Text(_) => None,
    })
}

#[test]
fn the_replys_table_is_cut_out_with_the_text_around_it() {
    let segments = segments(REPLY);
    assert_eq!(segments.len(), 3);
    let [Segment::Text(before), Segment::Table { table, raw }, Segment::Text(after)] =
        &segments[..]
    else {
        panic!("expected text, table, text: {segments:?}");
    };
    assert!(before.contains("Nothing has landed yet."));
    assert!(after.contains("I gave it to a14 instead"));
    assert_eq!(table.header, ["Design PR", "What it builds", "Who"]);
    assert_eq!(table.rows.len(), 5);
    assert!(raw.starts_with("| Design PR |"));
    assert!(raw.ends_with("group Agents & routing) |"));
}

#[test]
fn a_table_in_a_code_fence_stays_code() {
    let text = "```\n| a | b |\n|---|---|\n| 1 | 2 |\n```";
    assert_eq!(segments(text), [Segment::Text(text.into())]);
    let tilde = "~~~ md\n| a | b |\n|---|---|\n| 1 | 2 |\n~~~\n| c | d |\n|---|---|\n| 3 | 4 |";
    let out = segments(tilde);
    assert_eq!(out.len(), 2, "{out:?}");
    assert!(matches!(&out[1], Segment::Table { table, .. } if table.header == ["c", "d"]));
}

#[test]
fn pipes_in_code_spans_and_escapes_stay_in_their_cell() {
    let table = table("| cmd | note |\n|:--|--:|\n| `a | b` | x \\| y |").unwrap();
    assert_eq!(table.rows, [["`a | b`", "x | y"]]);
    assert_eq!(table.alignments, [Alignment::Leading, Alignment::Trailing]);
}

#[test]
fn a_line_with_pipes_but_no_delimiter_row_is_text() {
    assert_eq!(table("a | b\nc | d"), None);
}

#[test]
fn rows_are_padded_or_cut_to_the_header_and_limits_hold() {
    let table = table("a | b | c\n:-:|---|---\n1 | 2\n1 | 2 | 3 | 4\n\nafter").unwrap();
    assert_eq!(table.alignments, [Alignment::Center, Alignment::Leading, Alignment::Leading]);
    assert_eq!(table.rows, [vec!["1", "2", ""], vec!["1", "2", "3"]]);
    let wide = format!("{}\n{}\n{}", "|x".repeat(13), "|-".repeat(13), "|1".repeat(13));
    assert_eq!(segments(&wide), [Segment::Text(wide.clone())]);
    let long = format!("| a | b |\n|---|---|\n{}", "| 1 | 2 |\n".repeat(201));
    assert!(segments(&long).iter().all(|s| matches!(s, Segment::Text(_))));
}

#[test]
fn a_cell_keeps_its_escapes_and_trailing_escaped_pipe() {
    assert_eq!(cells("a | b \\* c"), Some(vec!["a".into(), "b \\* c".into()]));
    assert_eq!(cells("| a | b \\|"), Some(vec!["a".into(), "b |".into()]));
    assert_eq!(cells("a | b\\"), Some(vec!["a".into(), "b\\".into()]));
    assert_eq!(cells("| a |"), None);
    assert_eq!(cells("\u{3000}a\u{a0}|\tb\u{2003}"), Some(vec!["a".into(), "b".into()]));
}

#[test]
fn the_replys_table_is_a_plan_card() {
    let rows = plan_card(&table(REPLY).unwrap()).unwrap();
    let owners: Vec<_> = rows.iter().map(|r| r.owner.as_deref()).collect();
    assert_eq!(owners, [Some("a12"), Some("a7"), Some("a4"), Some("a13"), Some("a14")]);
    let keys: Vec<_> = rows.iter().map(|r| r.key.as_deref()).collect();
    assert_eq!(keys, [Some("1 + 2"), Some("3"), Some("4"), Some("5"), Some("6")]);
    assert!(rows[0].title.starts_with("Lasting canary results"));
    assert_eq!(
        rows[0].owner_note.as_deref(),
        Some("new; workspace \"a12 · Nightly train and canary\", group cmux-next app")
    );
    assert_eq!(rows[1].owner_note.as_deref(), Some("added to its ship-guard work"));
    assert_eq!(rows[2].pull_requests, ["https://github.com/manaflow-ai/cmux/pull/22590"]);
    assert_eq!(
        rows[2].title,
        "A banner that offers the roll-back from #22590 when a build was pulled"
    );
    assert!(rows.iter().all(|r| r.written.is_none()));
}

#[test]
fn a_status_column_gives_the_written_state() {
    let t = table("| Task | Owner | Status |\n|---|---|---|\n| Inspector | a10 | waiting on CI |\n| Pet dock | a11 | landed |\n| Docs | a5 | in progress |").unwrap();
    let rows = plan_card(&t).unwrap();
    let written: Vec<_> = rows.iter().map(|r| r.written).collect();
    assert_eq!(written, [Some(WrittenState::WaitingOnCi), Some(WrittenState::Landed), None]);
    let titles: Vec<_> = rows.iter().map(|r| r.title.as_str()).collect();
    assert_eq!(titles, ["Inspector", "Pet dock", "Docs"]);
}

#[test]
fn a_table_without_owners_or_with_paper_sizes_is_not_a_plan() {
    assert_eq!(
        plan_card(
            &table("| Check | Time |\n|---|---|\n| guards | 4m |\n| swift test | 12m |").unwrap()
        ),
        None
    );
    assert_eq!(
        plan_card(
            &table("| Size | mm |\n|---|---|\n| A4 | 210 × 297 |\n| A3 | 297 × 420 |").unwrap()
        ),
        None
    );
    // Fewer than half the rows owned.
    assert_eq!(
        plan_card(
            &table("| Task | Who |\n|---|---|\n| x | a1 |\n| y | me |\n| z | you |").unwrap()
        ),
        None
    );
}

#[test]
fn the_title_is_the_first_column_with_the_most_words() {
    // Two columns of equal words: Swift's max(by:) keeps the first.
    let rows =
        plan_card(&table("| A | B | Who |\n|---|---|---|\n| one two | three four | a1 |").unwrap())
            .unwrap();
    assert_eq!(rows[0].title, "one two");
    assert_eq!(rows[0].key.as_deref(), Some("three four"));
}

#[test]
fn owner_ids_are_subagent_ids_only() {
    assert_eq!(owner_id("a12").as_deref(), Some("a12"));
    assert_eq!(owner_id("A7, added").as_deref(), Some("a7"));
    assert_eq!(owner_id("a4b"), None);
    assert_eq!(owner_id("agent"), None);
    assert_eq!(owner_id("a"), None);
    assert_eq!(owner_id("a12345"), None);
    assert_eq!(owner_id(" a1234 "), Some("a1234".into()));
    assert_eq!(owner_id("a1é"), None);
    assert_eq!(owner_id("a1·x").as_deref(), Some("a1"));
}

#[test]
fn notes_drop_separators_and_parentheses() {
    assert_eq!(note("a12 (new; ws)", "a12").as_deref(), Some("new; ws"));
    assert_eq!(note("a3 — later", "a3").as_deref(), Some("later"));
    assert_eq!(note("a3 ()", "a3"), None);
    assert_eq!(note("a3", "a3"), None);
}

#[test]
fn written_states_take_the_first_rule_that_matches() {
    assert_eq!(written_state("Merged, CI red"), Some(WrittenState::Landed));
    assert_eq!(written_state("checks failing"), Some(WrittenState::CiFailed));
    assert_eq!(written_state("on CI"), Some(WrittenState::WaitingOnCi));
    assert_eq!(written_state("ready-for-review"), Some(WrittenState::InReview));
    assert_eq!(written_state("needs Leo"), Some(WrittenState::NeedsInput));
    assert_eq!(written_state("DONE"), Some(WrittenState::Done));
    assert_eq!(written_state("started"), Some(WrittenState::Working));
    assert_eq!(written_state("cinema"), None);
}

#[test]
fn a_cell_drops_marks_and_keeps_links_and_pictures() {
    let c = cell(
        "**bold** `code` [site](https://example.com/a b) ![shot]( <cmux-attachment:h9> ) see https://x.dev/p.",
    );
    assert_eq!(c.text, "bold code site  see https://x.dev/p.");
    assert_eq!(c.bold, [(0, 4)]);
    assert_eq!(c.links, ["https://example.com/a%20b", "https://x.dev/p"]);
    assert_eq!(c.images, [Image { alt: "shot".into(), source: "cmux-attachment:h9".into() }]);
    // A target without a scheme stays literal.
    assert_eq!(cell("[x](notes/a.md)").text, "[x](notes/a.md)");
    assert!(cell("[x](notes/a.md)").links.is_empty());
}

#[test]
fn bold_ranges_count_utf16_units() {
    let c = cell("👍🏽 __é__");
    assert_eq!(c.text, "👍🏽 é");
    assert_eq!(c.bold, [(5, 1)]);
}

#[test]
fn graphemes_hold_their_marks() {
    // "|" with a combining mark is one character in Swift, not a pipe.
    assert_eq!(cells("a |\u{301} b"), None);
}

#[test]
fn pull_request_links_read_as_chief_plan_does() {
    assert_eq!(
        pull_request_key("https://GitHub.com/Manaflow-AI/cmux/pull/7/files").as_deref(),
        Some("manaflow-ai/cmux#7")
    );
    assert_eq!(
        pull_request_url("https://github.com/o/r/pull/+12?x#y").as_deref(),
        Some("https://github.com/o/r/pull/12")
    );
    assert_eq!(
        pull_request_key("https://github.com:443/%C3%89quipe/dépôt/pull/%37/files").as_deref(),
        Some("équipe/dépôt#7")
    );
    assert_eq!(pull_request_key("https://github.com/o/r/pull"), None);
    assert_eq!(pull_request_key("https://github.com/o/r/pull/%é"), None);
    assert_eq!(pull_request_key("http://github.com/o/r/pull/1"), None);
    assert_eq!(pull_request_key("https://github.com/o/r/issues/1"), None);
    assert_eq!(pull_request_key("https://github.com/o/r/pull/0"), None);
    assert_eq!(pull_request_key("https://gist.github.com/o/r/pull/1"), None);
}

#[test]
fn table_pictures_name_their_attachments() {
    let text = "The fix:\n\n| | Before | After |\n|---|---|---|\n| Light | ![before, light](cmux-attachment:h1) | ![after, light](cmux-attachment:h2) |\n| Dark | ![before, dark](cmux-attachment:h3) | done |";
    assert_eq!(attachment_hashes(text), ["h1", "h2", "h3"]);
    assert!(attachment_hashes("![x](cmux-attachment:h1)").is_empty());
}

#[test]
fn columns_keep_their_natural_widths_when_they_fit() {
    assert_eq!(column_widths(&[60.0, 200.0, 90.0], 600.0), [60.0, 200.0, 90.0]);
    assert!(column_widths(&[], 10.0).is_empty());
}

#[test]
fn wide_columns_share_the_room_narrow_ones_keep_theirs() {
    let widths = column_widths(&[70.0, 900.0, 500.0], 700.0);
    assert_eq!(widths[0], 70.0);
    assert!(widths.iter().sum::<f64>() <= 700.0);
    assert!(widths[1] > widths[2]);
    assert!(widths[2] >= MIN_COLUMN);
    assert_eq!(widths, [70.0, 405.0, 225.0]);
    assert_eq!(column_widths(&[60.0, 120.0, 1000.0, 400.0], 450.0), [60.0, 120.0, 192.0, 77.0]);
}
