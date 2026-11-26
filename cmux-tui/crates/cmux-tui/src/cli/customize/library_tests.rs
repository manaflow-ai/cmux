use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn library_words_parse() {
    assert_eq!(parse(&[]).unwrap(), Request::List);
    assert_eq!(parse(&words("ls")).unwrap(), Request::List);
    assert_eq!(parse(&words("on roomy")).unwrap(), Request::On { name: "roomy".into() });
    assert_eq!(
        parse(&words("off roomy")).unwrap(),
        Request::Off { name: "roomy".into(), reason: None }
    );
    assert_eq!(
        parse(&words("order roomy 2")).unwrap(),
        Request::Order { name: "roomy".into(), position: Position::At(2) }
    );
    assert_eq!(
        parse(&words("order roomy top")).unwrap(),
        Request::Order { name: "roomy".into(), position: Position::Top }
    );
    assert_eq!(
        parse(&words("export set.json --link --on --name mine")).unwrap(),
        Request::Export {
            file: Some("set.json".into()),
            link: true,
            only_on: true,
            name: Some("mine".into())
        }
    );
    assert_eq!(
        parse(&words("import - --on")).unwrap(),
        Request::Import { source: "-".into(), on: true }
    );
    for bad in ["on", "on -x", "order roomy 0", "order roomy", "import", "frob", "export a b"] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

/// The recovery words, exactly as the app calls them when a layer's
/// pages fail to load: `off --code --reason "<one line>"`.
#[test]
fn recovery_words_parse() {
    let reason = |text: &str| Some(text.to_owned());
    let app_call: Vec<String> =
        ["off", "--code", "--reason", "pages did not load: timeout after 10 s"]
            .iter()
            .map(|word| (*word).to_owned())
            .collect();
    assert_eq!(
        parse(&app_call).unwrap(),
        Request::OffCode { reason: reason("pages did not load: timeout after 10 s") }
    );
    assert_eq!(parse(&words("off --code")).unwrap(), Request::OffCode { reason: None });
    assert_eq!(
        parse(&words("off --reason=gone --code")).unwrap(),
        Request::OffCode { reason: reason("gone") }
    );
    assert_eq!(
        parse(&words("off pr-43496 --reason broke")).unwrap(),
        Request::Off { name: "pr-43496".into(), reason: reason("broke") }
    );
    assert_eq!(parse(&words("off --all")).unwrap(), Request::OffAll);
    assert_eq!(parse(&words("reset")).unwrap(), Request::OffAll);
    assert_eq!(parse(&words("status")).unwrap(), Request::Status);
    assert_eq!(parse(&words("expire")).unwrap(), Request::Expire);
    assert_eq!(parse(&words("standup")).unwrap(), Request::Standup);
    for bad in [
        "off",
        "off --all --code",
        "off --all --reason x",
        "off a b",
        "off a --all",
        "off --code --reason",
        "off --frob",
        "reset now",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

/// `standup` on an empty library answers no lines and says how to start.
#[test]
fn standup_of_an_empty_library_says_how_to_start() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(cmux_customize::Roots::under(dir.path()));
    let standup = execute(&customize, Request::Standup, "cli", 4).unwrap();
    assert_eq!(standup.json()["standup"]["lines"], serde_json::json!([]));
    assert!(standup.human(4).contains("cmux customize use pr:N"), "{}", standup.human(4));
}

/// `off --code` and `reset` work with no app and a library that does not
/// read, and say through the exit code that the base was lost.
#[test]
fn recovery_runs_with_a_broken_library_and_exits_1_when_not_complete() {
    use cmux_customize::Roots;
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let answer = execute(&customize, Request::OffCode { reason: None }, "cli", 1).unwrap();
    assert_eq!(answer.exit(), 0, "nothing on is a clean recovery");
    assert!(answer.json()["complete"].as_bool().unwrap());

    std::fs::create_dir_all(dir.path().join("state")).unwrap();
    std::fs::write(dir.path().join("state/library.json"), "{ cut short").unwrap();
    let answer = execute(&customize, Request::OffAll, "cli", 2).unwrap();
    assert_eq!(answer.exit(), 1);
    let human = answer.human(2);
    assert!(human.contains("library.json.unreadable-2"), "{human}");
    assert!(human.contains("cmux serves its own pages"), "{human}");
    let status = execute(&customize, Request::Status, "cli", 3).unwrap();
    assert_eq!(status.json()["layers"]["line"], "customize: 0 on");
}

/// A shared collection whose views ask for more than the person's own
/// views did says which new scopes wait for their approval, and where
/// they give it (cmux grants only the reads by itself).
#[test]
fn an_import_whose_views_ask_for_more_names_the_scopes_that_wait() {
    use cmux_customize::Roots;
    let manifest = |scopes: &str| {
        format!(
            r#"{{
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "engines": {{ "cmux": "^2.0" }},
  "runtime": {{ "main": "main.js" }},
  "implements": {{ "cmux.section/1": {{ "export": "renderSection", "title": "PRs", "symbol": "sparkles" }} }},
  "scopes": {{ {scopes} }},
  "description": "My own views"
}}
"#
        )
    };
    let write = |root: &std::path::Path, path: &str, text: &str| {
        let file = root.join("config").join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, text).unwrap();
    };
    let views = |root: &std::path::Path, scopes: &str, at: u64| {
        let customize = Customize::open(Roots::under(root));
        write(root, "cmux-next.json", "{}\n");
        customize.ensure_baseline(at).unwrap();
        customize.begin("my views", "cli", at + 1).unwrap();
        write(root, "customize/main.js", "export function renderSection() {}\n");
        write(root, "customize/cmux-app.json", &manifest(scopes));
        customize.apply(None, "cli", at + 2).unwrap();
        customize
    };

    let theirs = tempfile::tempdir().unwrap();
    let shared = views(
        theirs.path(),
        r#""workspace:read": "r", "terminal:write": "w", "actions:run": "run""#,
        10,
    );
    let collection = shared.library_export("their views", "", false).unwrap();
    let file = theirs.path().join("collection.json");
    std::fs::write(&file, serde_json::to_string(&collection).unwrap()).unwrap();

    let mine = tempfile::tempdir().unwrap();
    let customize = views(mine.path(), r#""agent_chat:read": "r""#, 20);
    let source = file.to_str().unwrap().to_owned();
    let answer =
        execute(&customize, Request::Import { source: source.clone(), on: true }, "cli", 30)
            .unwrap();
    assert_eq!(answer.json()["waiting_scopes"], json!(["actions:run", "terminal:write"]));
    let human = answer.human(30);
    assert!(
        human.contains("your views now ask for actions:run, terminal:write")
            && human.contains("App Store, Installed, local/customize"),
        "{human}"
    );

    // Off, nothing live changes, so nothing waits.
    let other = tempfile::tempdir().unwrap();
    let customize = views(other.path(), r#""agent_chat:read": "r""#, 40);
    let answer = execute(&customize, Request::Import { source, on: false }, "cli", 50).unwrap();
    assert!(answer.json().get("waiting_scopes").is_none(), "{}", answer.json());
}

#[test]
fn a_link_carries_the_collection_and_a_damaged_one_is_refused() {
    let text = "{\"cmuxCollection\":1,\"entries\":[]}\n";
    let link = to_link(text).unwrap();
    assert!(link.starts_with(LINK_PREFIX));
    assert_eq!(from_link(link.strip_prefix(LINK_PREFIX).unwrap()).unwrap(), text);
    assert!(from_link("not base64 at all!").is_err());
    assert!(from_link("AAAA").is_err());
}

#[test]
fn refresh_if_app_changed_parses() {
    assert_eq!(parse(&words("refresh")).unwrap(), Request::Refresh { if_app_changed: false });
    assert_eq!(
        parse(&words("refresh --if-app-changed")).unwrap(),
        Request::Refresh { if_app_changed: true }
    );
    for bad in ["refresh --frob", "refresh --if-app-changed x"] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

/// What the app runs at start (`refresh --if-app-changed`): refresh runs once
/// per app commit, never on a DEV build or an empty library, and says
/// nothing when it does not run.
#[test]
fn refresh_runs_at_start_only_when_the_app_commit_changed() {
    use cmux_customize::Roots;
    use cmux_customize::library::CodeLayer;
    use std::cell::Cell;
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let runs = Cell::new(0);
    let run = || {
        runs.set(runs.get() + 1);
        Ok(Answer::Library { json: json!({ "refreshed": [] }), human: "pr-7: up to date\n".into() })
    };
    let human = |answer: Answer| match answer {
        Answer::Library { human, .. } => human,
        _ => panic!("not a library answer"),
    };
    // No code entry: nothing to refresh, nothing written.
    assert_eq!(human(refresh_when(&customize, Some("8815f4c"), true, run).unwrap()), "");
    assert_eq!(runs.get(), 0);
    assert_eq!(customize.library_refreshed_on().unwrap(), None);

    let layer = CodeLayer {
        kind: Default::default(),
        source: String::new(),
        repo: "manaflow-ai/cmux".into(),
        pr: 7,
        title: "pr 7".into(),
        head: "a".repeat(40),
        base: String::new(),
        web: String::new(),
        abi: Some(1),
        needs_build: Vec::new(),
        note: String::new(),
    };
    customize.library_use_code(layer, vec![], "cli", 1).unwrap();
    // A DEV build has no commit: never at start.
    assert_eq!(human(refresh_when(&customize, None, true, run).unwrap()), "");
    assert_eq!(runs.get(), 0);
    // The first start with a commit runs it and records the commit.
    assert_eq!(
        human(refresh_when(&customize, Some("8815f4c"), true, run).unwrap()),
        "pr-7: up to date\n"
    );
    assert_eq!(runs.get(), 1);
    assert_eq!(customize.library_refreshed_on().unwrap().as_deref(), Some("8815f4c"));
    // The same commit again (every later start): quiet, not run.
    assert_eq!(human(refresh_when(&customize, Some("8815f4c"), true, run).unwrap()), "");
    assert_eq!(runs.get(), 1);
    // An update: runs again.
    refresh_when(&customize, Some("9a0b1c2"), true, run).unwrap();
    assert_eq!(runs.get(), 2);
    assert_eq!(customize.library_refreshed_on().unwrap().as_deref(), Some("9a0b1c2"));
    // A refresh by hand records the commit too, so the next start is quiet.
    refresh_when(&customize, Some("d3e4f50"), false, run).unwrap();
    assert_eq!(runs.get(), 3);
    refresh_when(&customize, Some("d3e4f50"), true, run).unwrap();
    assert_eq!(runs.get(), 3);
    // A refresh that failed records nothing: the next start tries again.
    let failed = || Err(super::super::pr::failure("offline".into()));
    assert!(refresh_when(&customize, Some("e5f6071"), true, failed).is_err());
    assert_eq!(customize.library_refreshed_on().unwrap().as_deref(), Some("d3e4f50"));
}

#[test]
fn keys_that_no_longer_apply_add_one_quiet_line_and_nothing_when_all_apply() {
    use cmux_customize::library::Stale;
    let answer =
        || Answer::Library { json: json!({ "layers": {} }), human: "customize: 1 on\n".into() };
    let Answer::Library { json, human } = no_longer_applies_into(answer(), &[]) else { panic!() };
    assert_eq!((json, human.as_str()), (json!({ "layers": {} }), "customize: 1 on\n"));
    let stale = [NoLongerApplies {
        name: "x".into(),
        keys: vec![Stale { key: "foo.bar".into(), why: "gone".into(), in_file: false }],
    }];
    let Answer::Library { json, human } = no_longer_applies_into(answer(), &stale) else {
        panic!()
    };
    assert_eq!(
        human,
        "customize: 1 on\nsettings layer \"x\": 1 key no longer applies: foo.bar (gone)\n"
    );
    assert_eq!(json["no_longer_apply"][0]["keys"][0], json!({ "key": "foo.bar", "why": "gone" }));
}
