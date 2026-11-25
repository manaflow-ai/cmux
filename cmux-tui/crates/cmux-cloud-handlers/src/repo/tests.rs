use super::*;

fn ok(spec: &str) -> MachineRepo {
    parse(spec).unwrap_or_else(|said| panic!("{spec}: {}", said.key))
}

fn refused(spec: &str) -> &'static str {
    match parse(spec) {
        Ok(repo) => panic!("{spec} parsed as {repo:?}"),
        Err(said) => said.key,
    }
}

#[test]
fn github_forms_parse_to_one_normal_spec() {
    for spec in [
        "manaflow-ai/cmux",
        " manaflow-ai/cmux\n",
        "https://github.com/manaflow-ai/cmux",
        "https://github.com/manaflow-ai/cmux.git",
        "https://www.github.com/manaflow-ai/cmux/",
        "http://github.com/manaflow-ai/cmux",
        "git@github.com:manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux.git",
    ] {
        let repo = ok(spec);
        assert_eq!(repo.spec, "manaflow-ai/cmux", "{spec}");
        assert_eq!(repo.url, "https://github.com/manaflow-ai/cmux.git");
        assert_eq!(repo.directory, "work/cmux");
        assert_eq!(repo.reference, None);
    }
}

#[test]
fn a_ref_comes_from_at_or_a_tree_path_and_at_wins() {
    assert_eq!(ok("o/n@feat/x").reference.as_deref(), Some("feat/x"));
    assert_eq!(ok("o/n@feat/x").spec, "o/n@feat/x");
    assert_eq!(ok("https://github.com/o/n/tree/feat/x").reference.as_deref(), Some("feat/x"));
    assert_eq!(ok("https://github.com/o/n/tree/feat@v1").reference.as_deref(), Some("v1"));
    assert_eq!(ok("git@github.com:o/n.git@v2").reference.as_deref(), Some("v2"));
}

#[test]
fn another_host_takes_an_https_url_with_groups() {
    let repo = ok("https://GitLab.com/group/sub/proj.git/-/tree/main");
    assert_eq!(repo.host, "gitlab.com");
    assert_eq!(repo.owner, "group/sub");
    assert_eq!(repo.name, "proj");
    assert_eq!(repo.reference.as_deref(), Some("main"));
    assert_eq!(repo.spec, "https://gitlab.com/group/sub/proj@main");
    assert_eq!(repo.url, "https://gitlab.com/group/sub/proj.git");
}

#[test]
fn a_login_or_token_in_the_url_is_refused() {
    for spec in [
        "https://ghp_secret@github.com/o/n",
        "https://user:pass@github.com/o/n",
        "ssh://git:pass@github.com/o/n",
        "https://git@github.com/o/n",
        "me@github.com:o/n",
        "https://token@gitlab.com/g/n",
    ] {
        assert_eq!(refused(spec), "repoCredentialsInURL", "{spec}");
    }
}

#[test]
fn bad_refs_are_refused() {
    for spec in ["o/n@HEAD", "o/n@-x", "o/n@a..b", "o/n@a b", "o/n@x.lock", "o/n@$(rm)", "o/n@"] {
        assert_eq!(refused(spec), "repoInvalidRef", "{spec}");
    }
}

#[test]
fn other_shapes_are_unrecognized() {
    for spec in [
        "cmux",
        "a/b/c",
        "/n",
        "o/.n",
        "o/-n",
        "o/n;rm",
        "ftp://github.com/o/n",
        "https://github.com:8443/o/n",
        "https://github.com/o/n?x=1",
        "https://github.com/o/n#x",
        "https://github.com/o/n/blob/main",
        "http://gitlab.com/g/n",
        "ssh://git@gitlab.com/g/n",
        "https://10.0.0.1/g/n",
        "https://gitlab.com/n",
        "https://gitlab.com/g/n/-/blob/main",
        "gitlab.com:g/n",
        "evilgithub.com:o/n",
    ] {
        assert_eq!(refused(spec), "repoUnrecognized", "{spec}");
    }
}

#[test]
fn a_percent_encoded_url_is_read_as_the_app_reads_it() {
    let repo = ok("https://github.com/o/n%2Egit");
    assert_eq!(repo.spec, "o/n");
    assert_eq!(repo.url, "https://github.com/o/n.git");
    assert_eq!(ok("https://github.com/o/n%2Dx").name, "n-x");
}
