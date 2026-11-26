use super::*;

fn names() -> Vec<Vec<String>> {
    [
        ("Workspaces", "workspaces"),
        ("Tabs", "navigation"),
        ("History", "search.history"),
        ("Settings", "settings"),
        ("Commands", "search.commands"),
        ("Chats & agents", "search.chats"),
    ]
    .iter()
    .map(|(title, id)| vec![title.to_string(), id.to_string()])
    .collect()
}

#[test]
fn in_keeps_the_named_section_and_removes_the_token() {
    let filter = parse("in:tabs deploy", &names());
    assert_eq!(filter.rest, "deploy");
    assert_eq!(filter.include, vec![1]);
    assert!(filter.exclude.is_empty());
    assert!(filter.applied && filter.restricts());
}

#[test]
fn a_singular_a_prefix_and_any_case_name_the_same_section() {
    for query in ["in:tab x", "in:TA x", "IN:Tabs x", "kind:tab x", "is:tabs x"] {
        assert_eq!(parse(query, &names()).include, vec![1], "{query}");
    }
}

#[test]
fn negation_excludes_and_commas_list_several() {
    let filter = parse("-in:history,settings foo", &names());
    assert_eq!(filter.exclude, vec![2, 3]);
    assert!(filter.include.is_empty());
    assert!(!filter.allows(2) && filter.allows(1));
    let filter = parse("foo in:tabs in:chats bar", &names());
    assert_eq!(filter.include, vec![1, 5]);
    assert_eq!(filter.rest, "foo bar");
}

#[test]
fn a_word_of_a_title_or_id_names_the_section() {
    // "agents" is the second word of "Chats & agents".
    assert_eq!(parse("in:agents", &names()).include, vec![5]);
    assert_eq!(parse("in:history", &names()).include, vec![2]);
}

#[test]
fn a_name_of_no_section_is_text_and_a_bare_operator_filters_nothing() {
    let filter = parse("in:nowhere foo", &names());
    assert_eq!(filter.rest, "in:nowhere foo");
    assert!(!filter.applied);
    let filter = parse("foo in:", &names());
    assert_eq!(filter.rest, "foo");
    assert!(filter.applied && !filter.restricts());
    let filter = parse("http://example.com", &names());
    assert_eq!(filter.rest, "http://example.com");
    assert!(!filter.applied);
}
