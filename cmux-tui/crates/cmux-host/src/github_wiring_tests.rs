use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt as _;

use super::*;

const STORE: [&str; 2] = [STORE_CMUX, STORE_GH];

fn plan_on(files: &[(&str, &str)], present: &[&str]) -> Vec<Write> {
    let files: HashMap<String, String> =
        files.iter().map(|(p, t)| ((*p).to_owned(), (*t).to_owned())).collect();
    plan(
        |p| files.get(p).cloned(),
        |p| files.contains_key(p) || present.contains(&p) || STORE.contains(&p),
    )
}

fn paths(w: &[Write]) -> Vec<&'static str> {
    w.iter().map(|w| w.path).collect()
}

#[test]
fn an_image_without_the_wiring_gets_every_file_and_the_include() {
    let w = plan_on(&[], &[]);
    assert_eq!(paths(&w), [GH_SHIM, GITHUB_GITCONFIG, STORE_PROFILE, SYSTEM_GITCONFIG]);
    assert_eq!((w[0].text.as_str(), w[0].mode), (GH_SHIM_TEXT, 0o755));
    assert_eq!((w[1].text.as_str(), w[1].mode), (GITCONFIG_TEXT, 0o644));
    assert_eq!(w[3].text, "[include]\n\tpath = /etc/cmux/gitconfig\n");
}

#[test]
fn a_wired_machine_gets_nothing_and_an_existing_gitconfig_keeps_its_text() {
    let system = "[user]\n\tname = me\n[include]\n    path=/etc/cmux/gitconfig\n";
    let current = [
        (GH_SHIM, GH_SHIM_TEXT),
        (GITHUB_GITCONFIG, GITCONFIG_TEXT),
        (STORE_PROFILE, STORE_PROFILE_TEXT),
        (SYSTEM_GITCONFIG, system),
    ];
    assert_eq!(plan_on(&current, &[]), []);
    // A gitconfig of the person's own, without our include: it is appended, nothing else changes.
    let own = [
        (GH_SHIM, GH_SHIM_TEXT),
        (GITHUB_GITCONFIG, GITCONFIG_TEXT),
        (STORE_PROFILE, STORE_PROFILE_TEXT),
        (SYSTEM_GITCONFIG, "[user]\n\tname = me"),
    ];
    let w = plan_on(&own, &[]);
    assert_eq!(paths(&w), [SYSTEM_GITCONFIG]);
    assert_eq!(w[0].text, "[user]\n\tname = me\n[include]\n\tpath = /etc/cmux/gitconfig\n");
}

#[test]
fn an_older_managed_copy_is_replaced_and_a_file_of_someones_own_is_left() {
    let old_profile = "# cmux store: user-space programs (images/cmux-vm). Managed, do not edit.\n\
                       case \":$PATH:\" in *:/opt/cmux/current/bin:*) ;; *) PATH=/opt/cmux/current/bin:$PATH ;; esac\n\
                       export PATH\n";
    let old_gitconfig = "# cmux (images/cmux-vm, managed, do not edit): an older text\n\
                         [credential \"https://github.com\"]\n\thelper = !/old/cmux github credential\n";
    let files = [
        (GH_SHIM, "#!/bin/sh\nexec /usr/bin/gh \"$@\"\n"),
        (GITHUB_GITCONFIG, old_gitconfig),
        (STORE_PROFILE, old_profile),
        (SYSTEM_GITCONFIG, "[include]\n\tpath = /etc/cmux/gitconfig\n"),
    ];
    let w = plan_on(&files, &[]);
    assert_eq!(paths(&w), [GITHUB_GITCONFIG, STORE_PROFILE]);
    assert_eq!(w[1].text, STORE_PROFILE_TEXT);
}

#[test]
fn nothing_is_written_without_the_stores_cmux_and_gh_or_over_a_file_it_cannot_read() {
    let files: HashMap<&str, &str> = HashMap::new();
    assert_eq!(plan(|p| files.get(p).map(|t| (*t).to_owned()), |_| false), []);
    assert_eq!(plan(|_| None, |p| p == STORE_CMUX), []);
    // There but unreadable: left alone.
    let w = plan_on(&[], &[GH_SHIM, GITHUB_GITCONFIG, STORE_PROFILE, SYSTEM_GITCONFIG]);
    assert_eq!(w, []);
}

#[test]
fn ensure_writes_the_files_under_the_root_with_their_modes_and_a_second_start_writes_none() {
    let root = tempfile::tempdir().unwrap();
    let paths = Paths::new(root.path());
    for store in STORE {
        let file = paths.at(store);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, "").unwrap();
    }
    std::fs::create_dir_all(paths.at("/etc")).unwrap();
    std::fs::write(paths.at(SYSTEM_GITCONFIG), "[core]\n\teditor = vi\n").unwrap();
    // A planted part file beside the shim is replaced, never written through.
    std::fs::create_dir_all(paths.at("/opt/cmux/github/bin")).unwrap();
    let elsewhere = root.path().join("elsewhere");
    std::fs::write(&elsewhere, "keep").unwrap();
    std::os::unix::fs::symlink(&elsewhere, paths.at("/opt/cmux/github/bin/.gh.cmux-part")).unwrap();

    ensure(&paths);
    let text = |p: &str| std::fs::read_to_string(paths.at(p)).unwrap();
    let mode = |p: &str| std::fs::metadata(paths.at(p)).unwrap().permissions().mode() & 0o777;
    assert_eq!(text(GH_SHIM), GH_SHIM_TEXT);
    assert_eq!(mode(GH_SHIM), 0o755);
    assert_eq!(text(GITHUB_GITCONFIG), GITCONFIG_TEXT);
    assert_eq!(mode(GITHUB_GITCONFIG), 0o644);
    assert_eq!(text(STORE_PROFILE), STORE_PROFILE_TEXT);
    assert_eq!(
        text(SYSTEM_GITCONFIG),
        "[core]\n\teditor = vi\n[include]\n\tpath = /etc/cmux/gitconfig\n"
    );
    assert_eq!(std::fs::read_to_string(&elsewhere).unwrap(), "keep");
    assert!(!paths.at("/opt/cmux/github/bin/.gh.cmux-part").exists());

    let read = |p: &str| std::fs::read_to_string(paths.at(p)).ok();
    assert_eq!(plan(read, |p| paths.at(p).exists()), []);
}
