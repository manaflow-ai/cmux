use super::*;

#[test]
fn host_is_mounted_on_cmux_only() {
    let args = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert!(applies(&args(&["host", "run"]), Surface::Cmux));
    assert!(!applies(&args(&["host", "run"]), Surface::CmuxTui));
    assert!(!applies(&args(&["workspace", "list"]), Surface::Cmux));
    assert!(!applies(&[], Surface::Cmux));
    assert_eq!(run(&args(&["--help"])), 0);
    // The store link named `cmux` keeps the surface; the resolved
    // executable (`cmux-tui`) would lose the `host` verb.
    let exe = Some(std::path::PathBuf::from("/opt/cmux/store/abc/bin/cmux-tui"));
    let link = std::ffi::OsStr::new("/opt/cmux/current/bin/cmux");
    assert_eq!(
        self_argv_for(Some(link), exe.clone()),
        args(&["/opt/cmux/current/bin/cmux", "host"])
    );
    assert_eq!(
        self_argv_for(Some(std::ffi::OsStr::new("cmux")), exe),
        args(&["/opt/cmux/store/abc/bin/cmux-tui", "host"])
    );
    assert_eq!(self_argv_for(None, None), Vec::<String>::new());
    assert_eq!(run(&args(&["bogus"])), 2);
    // The team VM verbs, and no other `team` path, are mounted early.
    assert!(team_vm_verb(&args(&["team", "restricted-shell"]), Surface::Cmux));
    assert!(team_vm_verb(&args(&["team", "whoami"]), Surface::Cmux));
    assert!(!team_vm_verb(&args(&["team", "ssh", "ca"]), Surface::Cmux));
    assert!(!team_vm_verb(&args(&["team", "whoami"]), Surface::CmuxTui));
    assert!(github_requested(&args(&["github", "credential", "get"]), Surface::Cmux));
    assert!(!github_requested(&args(&["github", "gh"]), Surface::CmuxTui));
    assert!(!github_requested(&args(&["git", "status"]), Surface::Cmux));
    assert!(repo_requested(&args(&["repo", "hold", "/w", "--", "true"])));
    assert!(!repo_requested(&args(&["cloud", "repo", "add"])));
    assert!(gitlab_requested(&args(&["gitlab", "credential", "get"]), Surface::Cmux));
    assert!(!gitlab_requested(&args(&["gitlab", "credential"]), Surface::CmuxTui));
}
