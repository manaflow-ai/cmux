use super::*;

#[test]
fn child_exit_observer_leaves_child_owned_for_wait() {
    let mut child =
        std::process::Command::new("/bin/sh").args(["-c", "exit 23"]).spawn().expect("spawn child");
    wait_for_child_exit_without_reaping(child.id() as libc::pid_t).expect("observe child");
    assert_eq!(child.wait().expect("reap child").code(), Some(23));
}

/// Runs the relay's `ensure_daemon` against a stand-in cmux-tui (`script`, a `/bin/sh` script
/// that serves no socket) and returns the arguments the owner was started with.
async fn owner_arguments(script_text: &str) -> (String, Vec<String>) {
    let root = Path::new("/tmp").join(format!("crr-{}", crate::pty::random_hex(6)));
    std::fs::create_dir_all(&root).expect("test root");
    let script = root.join("fake-cmux-tui.sh");
    std::fs::write(&script, script_text).expect("fake cmux-tui");
    let cmux_tui =
        CmuxTui { file: "/bin/sh".to_owned(), prefix: vec![script.to_string_lossy().into_owned()] };
    let deps = RealPtyDeps::new(HashMap::from([(
        "XDG_RUNTIME_DIR".to_owned(),
        root.join("run").to_string_lossy().into_owned(),
    )]));
    let cwd = ResolvedCwd {
        path: root.clone(),
        directory: Arc::new(File::open(&root).expect("open test root")),
    };
    let session = format!("w5o-{}", crate::pty::random_hex(4));
    let started =
        deps.ensure_daemon(&cmux_tui, &session, &deps.socket_dir(), &cwd, &HashMap::new()).await;
    assert!(started.is_err(), "the stand-in serves no socket");
    let recorded = std::fs::read_to_string(root.join("fake-cmux-tui.sh.args")).expect("argv");
    let _ = std::fs::remove_dir_all(&root);
    (session, recorded.lines().map(str::to_owned).collect())
}

/// The owner the relay starts reaps tabless terminals (`--terminal-reap-grace-seconds 30`), as
/// every owner `ensure` starts. Its socket is the session's default one, so a later `cmux` or
/// `cmux-tui` client reuses this owner, and a tab closed in the relay's `cmux-tui attach` viewer
/// only detaches its terminal: without the option that shell runs until the owner stops.
#[tokio::test]
async fn w5o_the_owner_the_relay_starts_reaps_tabless_terminals() {
    // A current cmux-tui: `help start` lists the option; the owner records its arguments.
    let (session, args) = owner_arguments(
            "if [ \"$1\" = help ]; then printf '%s\\n' '--terminal-reap-grace-seconds <n>'; exit 0; fi\n\
             [ \"$1\" = --help ] && exit 0\n\
             printf '%s\\n' \"$@\" > \"$0.args\"\n",
        )
        .await;
    assert!(args.starts_with(&["--headless".to_owned(), "--session".to_owned(), session]));
    assert!(
        args.windows(2).any(|pair| pair == ["--terminal-reap-grace-seconds", "30"]),
        "the relay's owner does not reap tabless terminals: {args:?}"
    );
}

/// A cmux-tui older than the reap option still starts an owner (one that never reaps): its
/// help does not list the option, so the relay does not pass it.
#[tokio::test]
async fn w5o_an_older_cmux_tui_starts_without_the_reap_option() {
    let (session, args) = owner_arguments(
        "case \"$1\" in --help|help) exit 0 ;; esac\n\
             printf '%s\\n' \"$@\" > \"$0.args\"\n",
    )
    .await;
    assert!(args.starts_with(&["--headless".to_owned(), "--session".to_owned(), session]));
    assert!(!args.iter().any(|arg| arg == REAP_GRACE_OPTION), "{args:?}");
}
