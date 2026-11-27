use super::*;

fn inv(agent: &str) -> Invocation {
    Invocation { agent: Some(agent.to_owned()), ..Invocation::default() }
}

#[test]
fn agent_is_a_harness_id() {
    assert_eq!(request(&inv(" claude\t")).unwrap().agent, "claude");
    assert_eq!(request(&inv("codex-1.2_x")).unwrap().agent, "codex-1.2_x");
    for bad in ["", " ", "-claude", ".x", "Claude", "a b", "claude\n"] {
        assert_eq!(request(&inv(bad)), Err(Invalid::AgentInvalid), "{bad:?}");
    }
    assert_eq!(request(&inv(&"a".repeat(64))).unwrap().agent.len(), 64);
    assert_eq!(request(&inv(&"a".repeat(65))), Err(Invalid::AgentInvalid));
    assert_eq!(request(&Invocation::default()), Err(Invalid::AgentInvalid));
}

#[test]
fn cwd_is_absolute_and_plain() {
    let with = |cwd: &str| request(&Invocation { cwd: Some(cwd.to_owned()), ..inv("claude") });
    assert_eq!(with("  ").unwrap().cwd, None);
    assert_eq!(with(" /repo ").unwrap().cwd.as_deref(), Some("/repo"));
    assert_eq!(with("repo"), Err(Invalid::CwdInvalid));
    assert_eq!(with("/a\u{7}b"), Err(Invalid::CwdInvalid));
    assert_eq!(with(&format!("/{}", "a".repeat(4096))), Err(Invalid::CwdInvalid));
    assert!(with(&format!("/{}", "a".repeat(4095))).is_ok());
}

#[test]
fn name_and_model_trim_to_none() {
    let run = request(&Invocation {
        name: Some("  ".into()),
        model: Some(" opus ".into()),
        machine_id: Some("m1".into()),
        from_folder: Some("/f".into()),
        ..inv("claude")
    })
    .unwrap();
    assert_eq!(run.name, None);
    assert_eq!(run.model.as_deref(), Some("opus"));
    assert_eq!(run.machine_id.as_deref(), Some("m1"));
    assert_eq!(run.from_folder.as_deref(), Some("/f"));
}

#[test]
fn connection_is_an_id_and_reads_back() {
    let with = |id: &str| request(&Invocation { connection: Some(id.to_owned()), ..inv("codex") });
    assert_eq!(with("  ").unwrap().connection, None);
    assert_eq!(with(" conn_1:a@b.c-d ").unwrap().connection.as_deref(), Some("conn_1:a@b.c-d"));
    for bad in ["a b", "x/y", "é", &"a".repeat(129)] {
        assert_eq!(with(bad), Err(Invalid::ConnectionInvalid), "{bad:?}");
    }
    let run = with("c1").unwrap();
    assert_eq!(
        command(&run),
        format!(
            "cmux cloud start-session --name {} --agent codex --connection {}",
            shell_quoted(""),
            shell_quoted("c1")
        )
    );
}

#[test]
fn command_reads_back() {
    let mut run =
        Request { name: Some("dev box".into()), agent: "claude".into(), ..Request::default() };
    assert_eq!(command(&run), "cmux cloud start-session --name 'dev box' --agent claude");
    run.model = Some("opus".into());
    run.cwd = Some("/repo".into());
    run.from_folder = Some("/it's".into());
    assert_eq!(
        command(&run),
        format!(
            "cmux cloud start-session --name 'dev box' --agent claude --model {} --cwd {} --from-folder {}",
            shell_quoted("opus"),
            shell_quoted("/repo"),
            shell_quoted("/it's")
        )
    );
    run.machine_id = Some("m-1".into());
    assert!(command(&run).starts_with(&format!(
        "cmux cloud start-session --target machine:{} ",
        shell_quoted("m-1")
    )));
    let bare = Request { agent: "codex".into(), ..Request::default() };
    assert_eq!(
        command(&bare),
        format!("cmux cloud start-session --name {} --agent codex", shell_quoted(""))
    );
}

#[test]
fn start_failures() {
    let named = vec!["agent_session.busy".to_owned()];
    let f = |code: Option<&str>, msg: &str| start_failure(code, msg, "app.folder_needed", &named);
    assert_eq!(f(Some("app.folder_needed"), "x"), StartFailure::NeedsFolder);
    assert_eq!(f(Some("agent_session.home_unconfirmed"), "x"), StartFailure::NeedsFolder);
    assert_eq!(f(Some("agent_session.above_home"), "x"), StartFailure::NeedsFolder);
    assert_eq!(
        f(Some("agent_session.busy"), "x"),
        StartFailure::Named { code: "agent_session.busy".into() }
    );
    assert_eq!(
        f(Some("other"), " It broke.. "),
        StartFailure::AgentFailed { reason: "It broke".into() }
    );
    assert_eq!(f(None, "gone"), StartFailure::AgentFailed { reason: "gone".into() });
}

#[test]
fn release_needs_all_three() {
    assert!(releases(true, true, true));
    assert!(!releases(false, true, true));
    assert!(!releases(true, false, true));
    assert!(!releases(true, true, false));
}

#[test]
fn from_folder_checks() {
    assert_eq!(from_folder(None, false), FromFolder::None);
    assert_eq!(from_folder(Some(" \n"), true), FromFolder::None);
    assert_eq!(from_folder(Some("/a"), true), FromFolder::WithCwd);
    assert_eq!(from_folder(Some("/a\u{1}"), false), FromFolder::Invalid);
    assert_eq!(from_folder(Some(&"a".repeat(4097)), false), FromFolder::Invalid);
    assert_eq!(
        from_folder(Some("/a/"), false),
        FromFolder::Check { path: "/a/".into(), folder: "/a".into() }
    );
    assert_eq!(
        from_folder(Some("/"), false),
        FromFolder::Check { path: "/".into(), folder: "/".into() }
    );
}

#[test]
fn run_key() {
    assert_eq!(run_key_machine(Some("m"), Some("n")), "id:m");
    assert_eq!(run_key_machine(None, Some("n")), "name:n");
    assert_eq!(run_key_machine(None, None), "name:");
}

#[test]
fn replies() {
    let r = |plan, code: Option<&str>, move_failure, retry, send_again| {
        reply(&ReplyInput { plan, code: code.map(str::to_owned), move_failure, retry, send_again })
    };
    assert_eq!(r(true, Some("x"), true, false, false).code, PLAN_REQUIRED_REPLY);
    assert_eq!(
        r(false, Some("x"), true, false, false),
        Reply { code: "x".into(), retryable: false }
    );
    assert_eq!(
        r(false, None, true, true, false),
        Reply { code: START_FAILED_REPLY.into(), retryable: true }
    );
    assert!(r(false, None, true, false, true).retryable);
    assert_eq!(
        r(false, Some("x"), false, true, true),
        Reply { code: START_FAILED_REPLY.into(), retryable: false }
    );
}

#[test]
fn ids() {
    assert_eq!(card_id("t1"), "cloud-start-session-t1");
    assert_eq!(dialog_id("ABC-D"), "cloud-start-abc-d");
}

#[test]
fn ask_round_trip() {
    let mut asks = Asks::default();
    let dialog = asks.begin("t", "TOK").unwrap();
    assert_eq!(asks.begin("t", "TOK2"), None);
    assert_eq!(asks.tab_of(&dialog).as_deref(), Some("t"));
    assert_eq!(asks.waiting(), vec![("t".to_owned(), dialog.clone())]);
    assert!(!asks.deliver("t", "other"));
    assert!(asks.deliver("t", &dialog));
    assert!(!asks.deliver("t", &dialog));
    assert!(asks.waiting().is_empty());
    assert_eq!(asks.settle("t", "TOK", Answer::Start, true), Answer::Start);
    assert!(!asks.finish("t", "OTHER"));
    assert!(asks.started("t", "TOK"));
    assert!(asks.linked.contains("t"));
    assert!(asks.done_card_answered("t"));
    assert!(asks.linked.is_empty());
}

#[test]
fn start_after_account_change() {
    let mut asks = Asks::default();
    asks.begin("t", "TOK");
    assert_eq!(asks.settle("t", "TOK", Answer::Start, false), Answer::AccountChanged);
    let mut asks = Asks::default();
    asks.begin("t", "NEW");
    assert_eq!(asks.settle("t", "OLD", Answer::Start, true), Answer::AccountChanged);
    assert_eq!(asks.settle("t", "NEW", Answer::NotNow, true), Answer::NotNow);
}

#[test]
fn end_all_splits() {
    let mut asks = Asks::default();
    asks.linked.insert("done".into());
    asks.begin("wait", "A");
    asks.begin("busy", "B");
    asks.settle("busy", "B", Answer::Start, true);
    asks.linked.insert("busy".into());
    let end = asks.end_all();
    assert_eq!(end.clear, vec!["done".to_owned()]);
    assert_eq!(end.account_changed, vec!["wait".to_owned()]);
    assert_eq!(end.fail, vec!["busy".to_owned()]);
    assert!(asks.open["wait"].ended);
    assert!(!asks.open.contains_key("busy"));
    assert_eq!(asks.settle("wait", "A", Answer::Start, true), Answer::AccountChanged);
    assert!(!asks.done_card_answered("wait"));
}
