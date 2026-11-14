use super::*;

fn slug(url: &str) -> Option<String> {
    parse(url).map(|repo| repo.slug())
}

#[test]
fn github_forms_normalize_to_https() {
    for url in [
        "https://github.com/acme/widget",
        "https://github.com/acme/widget.git",
        "https://github.com/acme/widget/",
        "https://GitHub.com/acme/widget.git",
        "https://x-access-token:secret@github.com/acme/widget.git",
        "git@github.com:acme/widget.git",
        "git@github.com:acme/widget",
        "ssh://git@github.com/acme/widget.git",
        "ssh://git@github.com/acme/widget",
    ] {
        let repo = parse(url).unwrap_or_else(|| panic!("{url} is GitHub"));
        assert_eq!(repo.url(), "https://github.com/acme/widget.git", "{url}");
        assert_eq!(repo.slug(), "acme/widget");
    }
    assert_eq!(slug("https://github.com/a-b/c.d_e.git").as_deref(), Some("a-b/c.d_e"));
}

#[test]
fn other_urls_are_not_github() {
    for url in [
        "https://gitlab.com/acme/widget.git",
        "https://github.com.evil.example/acme/widget.git",
        "https://evil.example/github.com/acme/widget.git",
        "http://github.com/acme/widget.git",
        "git@gitlab.com:acme/widget.git",
        "ssh://git@github.com:22/acme/widget.git",
        "file:///srv/acme/widget.git",
        "/srv/acme/widget.git",
        "https://github.com/acme",
        "https://github.com/acme/widget/tree/main",
        "https://github.com/-acme/widget",
        "https://github.com/acme/..",
        "",
    ] {
        assert_eq!(parse(url), None, "{url}");
    }
}

#[test]
fn redact_drops_logins() {
    assert_eq!(
        redact("https://user:token@gitlab.com/acme/widget.git"),
        "https://gitlab.com/acme/widget.git"
    );
    assert_eq!(redact("git@gitlab.com:acme/widget.git"), "git@gitlab.com:acme/widget.git");
}
