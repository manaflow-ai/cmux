use super::*;

#[test]
fn a_scope_lists_its_offered_verbs_one_line_each_with_the_title() {
    let text = section("tab").expect("tab has app verbs");
    let row = text.lines().find(|line| line.trim_start().starts_with("new-mac-screen "));
    let row = row.expect("new-mac-screen is listed");
    assert!(row.ends_with("Screen Sharing"), "{row}");
    assert!(text.lines().any(|line| line.trim_start().starts_with("new-browser ")));
    assert!(text.lines().any(|line| line.trim_start().starts_with("stop-mac-screen-viewing ")));
    assert_eq!(section("cloud"), None, "cloud keeps its own help");
    assert_eq!(section("no-such-scope"), None);
}

#[test]
fn titles_start_in_one_column_per_scope() {
    for scope in scopes().filter(|scope| has_section(scope)) {
        let text = section(scope).expect("section");
        let rows = text.lines().skip(3).collect::<Vec<_>>();
        assert_eq!(rows.len(), verbs(scope).count(), "{scope}: one line per verb");
        // Rows follow the sorted verbs; a verb may be several words (`chat channel create`).
        let columns = rows
            .iter()
            .zip(offered()[scope].iter())
            .filter_map(|(line, (verb, title))| {
                let rest = line.strip_prefix("  ")?.strip_prefix(verb.as_str())?;
                (verb.len() <= VERB_COLUMN && !title.is_empty())
                    .then(|| 2 + verb.len() + rest.len() - rest.trim_start().len())
            })
            .collect::<std::collections::BTreeSet<_>>();
        assert!(columns.len() <= 1, "{scope}: titles start at columns {columns:?}");
    }
}
