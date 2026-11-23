use super::*;
use serde::Deserialize;

/// One case of the file CmuxHomeCore's Swift `MessagePreviewTests` read too.
#[derive(Deserialize)]
struct Case {
    markdown: String,
    text: String,
    #[serde(default)]
    images: Vec<String>,
}

#[derive(Deserialize)]
struct File {
    cases: Vec<Case>,
}

fn cases() -> Vec<Case> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../Packages/Shared/CmuxHomeCore/Tests/CmuxHomeCoreTests/MessagePreviewCases.json"
    );
    let json = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    serde_json::from_str::<File>(&json).unwrap_or_else(|e| panic!("parse {path}: {e}")).cases
}

/// Lawrence, 2026-11-20: the daemon's Home row and the Chief's push showed a
/// reply's raw Markdown ("| | Before | After ||---|…"). The Rust preview says
/// what the Swift one says, case for case.
#[test]
fn every_shared_case_reads_as_the_swift_preview_does() {
    let cases = cases();
    assert!(cases.len() >= 20, "the case file has {} cases", cases.len());
    let words = Words::english();
    let mut wrong = Vec::new();
    for case in &cases {
        let preview = MessagePreview::new(&case.markdown);
        let text = preview.text(&words);
        let images: Vec<String> = preview.images.iter().map(|image| image.source.clone()).collect();
        if text != case.text || images != case.images {
            wrong.push(format!(
                "{:?}\n  want {:?} {:?}\n  got  {text:?} {images:?}",
                case.markdown, case.text, case.images
            ));
        }
    }
    assert!(
        wrong.is_empty(),
        "{} of {} cases differ:\n{}",
        wrong.len(),
        cases.len(),
        wrong.join("\n")
    );
}

#[test]
fn a_table_is_named_by_its_titled_columns_and_counts_its_rows() {
    let preview = MessagePreview::new(
        "| | Before | After |\n|---|---|---|\n| Light | ![b](/b.png) | ![a](/a.png) |\n| Dark | x | y |",
    );
    assert_eq!(
        preview.tables().collect::<Vec<_>>(),
        [&Table { columns: vec!["Before".into(), "After".into()], rows: 2 }]
    );
    assert_eq!(preview.images.first().map(|i| i.alt.as_str()), Some("b"));
}

#[test]
fn japanese_words_name_a_table_and_count_pictures() {
    let words = Words::for_locale("ja_JP.UTF-8");
    assert_eq!(MessagePreview::new("| A | B |\n|---|---|\n| 1 | 2 |").text(&words), "表: A / B");
    assert_eq!(MessagePreview::new("![a](/a.png) ![b](/b.png)").text(&words), "画像 2 枚");
    assert_eq!(Words::for_locale("en_US.UTF-8"), Words::english());
    assert_eq!(Words::for_locale(""), Words::english());
}

/// a1317, 2026-11-21: an agent's finished-turn push showed its last lines raw
/// ("| | Before | After |", "**All** 31 pass."). Each line says its words; a
/// table is one line; a code block keeps its text.
#[test]
fn lines_say_each_lines_words_and_a_table_once() {
    let md = "Done. See [PR 12](https://github.com/manaflow-ai/cmux/pull/12).\n\n| | Before | After |\n|---|---|---|\n| Light | ![b](/b.png) | ![a](/a.png) |\n\n**All** 31 pass.\n![shot](/s.png)\n```sh\n| not | a table |\n```";
    assert_eq!(
        lines(md, &Words::english()),
        ["Done. See PR 12.", "Table: Before / After", "All 31 pass.", "Image", "| not | a table |"]
    );
    assert_eq!(lines("| A | B |\n|---|---|\n| 1 | 2 |", &Words::japanese()), ["表: A / B"]);
    for text in ["", "\n\n", "```", "|", "|\n|-|", "![", "``"] {
        let _ = lines(text, &Words::english());
    }
}

#[test]
fn hostile_input_never_panics_and_reads_in_one_pass() {
    for text in [
        "[", "![", "![a](", "`", "``a`", "<", "<>", "\\", "|\n|", "|-|\n", "# ", "*", "~~",
        "[a](b", "[[[[", "))((",
    ] {
        let _ = MessagePreview::new(text).text(&Words::english());
    }
    let long = "word **bold** [link](https://x) ".repeat(5_000);
    assert!(
        MessagePreview::new(&long)
            .text(&Words::english())
            .starts_with("word bold link word bold link")
    );
}
