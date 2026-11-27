use super::*;

#[test]
fn the_embedded_guide_has_the_architecture_page_and_its_links() {
    assert!(pages().len() >= 20, "pages.json did not parse");
    let architecture = pages().iter().find(|page| page.slug == "architecture").unwrap();
    assert!(architecture.markdown.starts_with("# How cmux NEXT fits together\n"));
    assert!(architecture.markdown.contains("](acpmux.md)"));
    assert!(FULL.contains("# Secrets and the vault"));
}

#[test]
fn guide_parses_list_page_and_full() {
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    assert_eq!(parse(&[]).unwrap(), Request::List);
    assert_eq!(parse(&words(&["--full"])).unwrap(), Request::Full);
    assert_eq!(parse(&words(&["vault"])).unwrap(), Request::Page("vault".to_owned()));
    assert!(parse(&words(&["--bogus"])).is_err());
    assert!(parse(&words(&["vault", "machines"])).is_err());
}

/// An agent that asks in its own words finds the page that answers it.
#[test]
fn a_question_finds_its_page() {
    let slugs = |query| matching(query).iter().map(|page| page.slug.as_str()).collect::<Vec<_>>();
    assert!(slugs("vault placeholder host").contains(&"vault"));
    assert_eq!(slugs("fits together").first(), Some(&"architecture"));
    assert!(slugs("a b").is_empty());
}
