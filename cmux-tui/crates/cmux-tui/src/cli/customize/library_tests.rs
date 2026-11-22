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
