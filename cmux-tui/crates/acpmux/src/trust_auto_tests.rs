use super::*;
use serde_json::json;

fn repo(dir: &Path, remotes: &[(&str, &str)]) {
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    let mut text = String::from("[core]\n\trepositoryformatversion = 0\n");
    for (name, url) in remotes {
        text.push_str(&format!("[remote \"{name}\"]\n\turl = {url}\n"));
    }
    std::fs::write(dir.join(".git/config"), text).unwrap();
}

fn scratch(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("tauto-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn rules(doc: Value) -> AutoTrust {
    AutoTrust::from_doc(&doc, Some(Path::new("/nonexistent-home")))
}

/// Rules for a person whose home folder is `home`.
fn rules_at(home: &Path, doc: Value) -> AutoTrust {
    AutoTrust::from_doc(&doc, Some(home))
}

#[test]
fn github_urls_name_their_owner() {
    for url in [
        "git@github.com:ManaFlow-AI/cmux.git",
        "https://github.com/manaflow-ai/cmux",
        "https://user@github.com/manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux.git",
    ] {
        assert_eq!(github_owner(url).as_deref(), Some("manaflow-ai"), "{url}");
    }
    for url in [
        "git@gitlab.com:manaflow-ai/cmux.git",
        "/srv/git/cmux",
        "https://github.com.evil.example/manaflow-ai/x",
    ] {
        assert_eq!(github_owner(url), None, "{url}");
    }
}

/// The person's rules: on, no roots, these owners.
fn owners(orgs: &[&str]) -> Value {
    json!({"agents": {"trust": {"autoTrust": true, "projectRoots": [], "ownOrgs": orgs}}})
}

#[test]
fn by_default_nothing_is_trusted_by_a_rule() {
    let auto = rules(Value::Null);
    assert!(!auto.enabled);
    assert!(auto.orgs.is_empty());
    assert!(auto.roots.is_empty());
    // Turned on without naming anything, still nothing.
    let d = scratch("defaults");
    repo(&d.join("r"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
    let on = rules_at(&d, json!({"agents": {"trust": {"autoTrust": true}}}));
    assert_eq!(on.reason(d.join("r").to_str().unwrap()), None);
}

#[test]
fn a_home_at_the_root_trusts_nothing_by_organization() {
    let d = scratch("roothome");
    repo(&d.join("r"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
    let auto = rules_at(Path::new("/"), owners(&["manaflow-ai"]));
    assert_eq!(auto.home, None);
    assert_eq!(auto.reason(d.join("r").to_str().unwrap()), None);
}

#[test]
fn a_dotfiles_repository_at_home_trusts_nothing_in_home() {
    let d = scratch("dotfiles");
    repo(&d, &[("origin", "git@github.com:teamleaderleo/dotfiles.git")]);
    std::fs::create_dir_all(d.join("Downloads/tarball")).unwrap();
    let auto = rules_at(&d, owners(&["teamleaderleo"]));
    assert_eq!(auto.reason(d.join("Downloads/tarball").to_str().unwrap()), None);
    assert_eq!(auto.reason(d.to_str().unwrap()), None);
    // A repository of its own inside home still counts.
    repo(&d.join("code/app"), &[("origin", "git@github.com:teamleaderleo/app.git")]);
    assert_eq!(
        auto.reason(d.join("code/app").to_str().unwrap()),
        Some(Reason::Org("teamleaderleo".into()))
    );
}

#[test]
fn a_folder_under_a_root_is_trusted_but_outside_is_not() {
    let d = scratch("root");
    let root = d.join("projects");
    std::fs::create_dir_all(root.join("app/src")).unwrap();
    std::fs::create_dir_all(d.join("elsewhere")).unwrap();
    let auto = rules(
        json!({"agents": {"trust": {"autoTrust": true, "projectRoots": [root.to_string_lossy()]}}}),
    );
    assert_eq!(
        auto.reason(root.join("app/src").to_str().unwrap()),
        Some(Reason::Root(root.clone()))
    );
    assert_eq!(auto.reason(d.join("elsewhere").to_str().unwrap()), None);
}

#[cfg(unix)]
#[test]
fn a_symlink_from_a_trusted_root_to_outside_is_not_trusted() {
    let d = scratch("symlink-root");
    let root = d.join("projects");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(d.join("elsewhere")).unwrap();
    std::os::unix::fs::symlink(d.join("elsewhere"), root.join("link")).unwrap();
    let auto = rules(
        json!({"agents": {"trust": {"autoTrust": true, "projectRoots": [root.to_string_lossy()]}}}),
    );
    assert_eq!(auto.reason(root.join("link").to_str().unwrap()), None);
}

#[test]
fn a_repo_is_trusted_only_when_every_remote_is_an_own_org() {
    let d = scratch("org");
    let own = d.join("own");
    let mixed = d.join("mixed");
    let none = d.join("none");
    repo(&own, &[("origin", "git@github.com:teamleaderleo/x.git")]);
    repo(
        &mixed,
        &[("origin", "git@github.com:manaflow-ai/x.git"), ("up", "https://github.com/someone/x")],
    );
    repo(&none, &[]);
    let auto = rules_at(&d, owners(&["teamleaderleo", "manaflow-ai"]));
    assert_eq!(auto.reason(own.to_str().unwrap()), Some(Reason::Org("teamleaderleo".into())));
    assert_eq!(auto.reason(mixed.to_str().unwrap()), None);
    assert_eq!(auto.reason(none.to_str().unwrap()), None);
    // A repository outside the home folder (an agent's `git init` in /tmp) is not trusted.
    let elsewhere = scratch("org-elsewhere");
    repo(&elsewhere.join("forged"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
    assert_eq!(auto.reason(elsewhere.join("forged").to_str().unwrap()), None);
}

#[test]
fn a_linked_worktree_reads_the_main_repositorys_remotes() {
    let d = scratch("wt");
    let main = d.join("main");
    repo(&main, &[("origin", "git@github.com:manaflow-ai/x.git")]);
    let gitdir = main.join(".git/worktrees/w");
    std::fs::create_dir_all(&gitdir).unwrap();
    std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();
    let tree = d.join("w");
    std::fs::create_dir_all(&tree).unwrap();
    std::fs::write(tree.join(".git"), format!("gitdir: {}\n", gitdir.display())).unwrap();
    let auto = rules_at(&d, owners(&["manaflow-ai"]));
    // The repository does not name this folder back: a `.git` file written by hand.
    assert_eq!(auto.reason(tree.to_str().unwrap()), None);
    std::fs::write(gitdir.join("gitdir"), format!("{}\n", tree.join(".git").display())).unwrap();
    assert_eq!(auto.reason(tree.to_str().unwrap()), Some(Reason::Org("manaflow-ai".into())));
}

#[test]
fn the_switch_turns_both_rules_off_and_a_broken_file_never_widens() {
    let d = scratch("off");
    repo(&d.join("r"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
    let off = rules_at(
        &d,
        json!({"agents": {"trust": {"autoTrust": false, "ownOrgs": ["manaflow-ai"]}}}),
    );
    assert_eq!(off.reason(d.join("r").to_str().unwrap()), None);
    // A value of the wrong type turns the rules off rather than falling back to the default.
    let typo = rules_at(
        &d,
        json!({"agents": {"trust": {"autoTrust": "false", "ownOrgs": ["manaflow-ai"]}}}),
    );
    assert_eq!(typo.reason(d.join("r").to_str().unwrap()), None);
    let on = rules_at(&d, owners(&["manaflow-ai"]));
    assert_eq!(on.reason(d.join("r").to_str().unwrap()), Some(Reason::Org("manaflow-ai".into())));
    let bad_orgs =
        rules_at(&d, json!({"agents": {"trust": {"autoTrust": true, "ownOrgs": "manaflow-ai"}}}));
    assert_eq!(bad_orgs.reason(d.join("r").to_str().unwrap()), None);
    assert_eq!(AutoTrust::default().reason(d.join("r").to_str().unwrap()), None);
}

#[test]
fn the_home_folder_is_no_project_root() {
    let d = scratch("home");
    std::fs::create_dir_all(d.join("work")).unwrap();
    let doc = json!({"agents": {"trust": {
        "autoTrust": true, "projectRoots": [d.to_string_lossy(), "~/work"]
    }}});
    let auto = AutoTrust::from_doc(&doc, Some(&d));
    assert_eq!(auto.roots, [d.join("work")]);
    assert_eq!(auto.reason(d.join("work").to_str().unwrap()), Some(Reason::Root(d.join("work"))));
    assert_eq!(auto.reason(d.to_str().unwrap()), None);
}

#[test]
fn a_root_that_is_the_filesystem_root_trusts_nothing_extra() {
    let d = scratch("slash");
    let auto = rules(json!({"agents": {"trust": {"autoTrust": true, "projectRoots": ["/"]}}}));
    assert_eq!(auto.reason(d.to_str().unwrap()), None);
}
