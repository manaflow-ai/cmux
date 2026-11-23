//! The grammar, the ask flow with a stand-in agent, and the words a person
//! reads. The journeys on the file model itself are the `cmux-customize`
//! crate's tests; `tests/customize_mcp.rs` runs the built binary.

use std::cell::RefCell;
use std::fs;
use std::path::Path;

use cmux_customize::{Customize, Roots};

use super::ask::{Chat, ChatResult, chat_name};
use super::render::{Answer, ago};
use super::{AskOptions, Request, execute, parse};

fn words(text: &[&str]) -> Vec<String> {
    text.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn a_wish_is_words_and_one_bare_word_is_a_verb() {
    let ask = |wish: &str, options: AskOptions| Ok(Request::Ask { wish: wish.to_owned(), options });
    assert_eq!(parse(&[]), Ok(Request::Status));
    assert_eq!(
        parse(&words(&["make the sidebar compact"])),
        ask("make the sidebar compact", AskOptions::default())
    );
    assert_eq!(
        parse(&words(&["make", "the", "sidebar", "compact"])),
        ask("make the sidebar compact", AskOptions::default())
    );
    // A wish that starts with a verb's word is still a wish when it is quoted.
    assert_eq!(
        parse(&words(&["apply a night theme"])),
        ask("apply a night theme", AskOptions::default())
    );
    assert_eq!(parse(&words(&["ask", "discard"])), ask("discard", AskOptions::default()));
    assert_eq!(
        parse(&words(&["-w", "--harness", "codex", "bigger text", "--timeout", "5m", "--new"])),
        ask(
            "bigger text",
            AskOptions {
                harness: Some("codex".into()),
                model: None,
                wait: true,
                timeout: Some("5m".into()),
                new_chat: true
            }
        )
    );
    assert_eq!(parse(&words(&["apply"])), Ok(Request::Apply { note: None }));
    assert_eq!(
        parse(&words(&["apply", "compact", "sidebar"])),
        Ok(Request::Apply { note: Some("compact sidebar".into()) })
    );
    assert_eq!(parse(&words(&["rollback"])), Ok(Request::Rollback { to: None }));
    assert_eq!(parse(&words(&["rollback", "3"])), Ok(Request::Rollback { to: Some(3) }));
    assert_eq!(parse(&words(&["undo"])), Ok(Request::Rollback { to: None }));
    assert_eq!(parse(&words(&["ls"])), Ok(Request::Generations));
    assert_eq!(parse(&words(&["show", "#4"])), Ok(Request::Show { n: 4 }));
    assert_eq!(
        parse(&words(&["save", "compact-night", "small", "and", "dark"])),
        Ok(Request::Save { name: "compact-night".into(), note: "small and dark".into() })
    );
    assert_eq!(
        parse(&words(&["brief", "--", "--odd wish"])),
        Ok(Request::Brief { wish: "--odd wish".into() })
    );
    assert_eq!(parse(&words(&["status", "--help"])), Ok(Request::Help));
}

#[test]
fn a_mistyped_verb_gets_a_suggestion_and_never_an_agent() {
    let error = parse(&words(&["staus"])).unwrap_err();
    assert!(error.contains("did you mean `status`?"), "{error}");
    let error = parse(&words(&["rolback"])).unwrap_err();
    assert!(error.contains("`rollback`"), "{error}");
    let error = parse(&words(&["zzz-not-a-command"])).unwrap_err();
    assert!(error.contains("say what you want in quotes"), "{error}");
    for bad in [
        &["rollback", "three"][..],
        &["show"],
        &["save"],
        &["use"],
        &["discard", "now"],
        &["--bogus", "x y"],
        &["brief", "-w", "x"],
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad:?}");
    }
}

/// An agent that answers every chat by saving `file` with `text`.
struct FakeAgent<'a> {
    root: &'a Path,
    edits: RefCell<Vec<(&'static str, &'static str)>>,
    calls: RefCell<Vec<Vec<String>>>,
    fail_send: bool,
    /// The code a failing `chat send` prints.
    send_code: &'static str,
    /// Answer as `cmux chat` does with no `--wait`: the receipt of the chat
    /// it made or sent to, which has no `session_id`.
    receipt: bool,
}

impl Chat for FakeAgent<'_> {
    fn run(&self, words: &[String]) -> Result<ChatResult, String> {
        self.calls.borrow_mut().push(words.to_vec());
        if self.fail_send && words.get(2).map(String::as_str) == Some("send") {
            return Ok(ChatResult {
                ok: false,
                stdout: String::new(),
                stderr: format!(
                    "{{\"ok\":false,\"error\":{{\"code\":\"{}\",\"message\":\"no\",\"details\":{{}}}}}}\n",
                    self.send_code
                ),
            });
        }
        if let Some((file, text)) = self.edits.borrow_mut().pop() {
            let path = self.root.join("config").join(file);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        }
        let stdout = if self.receipt {
            let action =
                if words.get(2).map(String::as_str) == Some("send") { "send" } else { "new" };
            format!(
                "{{\"schema_version\":1,\"action\":\"chat.{action}\",\"result\":{{\"chat\":\"sess-9\",\"name\":\"Customize\",\"prompt\":{{\"state\":\"accepted\",\"prompt_id\":\"p1\"}}}}}}\n"
            )
        } else {
            "{\"session_id\":\"sess-1\",\"reply\":\"The sidebar is compact now. It is a preview.\"}\n".into()
        };
        Ok(ChatResult { ok: true, stdout, stderr: String::new() })
    }
}

#[test]
fn an_ask_previews_through_a_chat_and_the_next_ask_refines_in_it() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("config")).unwrap();
    fs::write(dir.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let agent = FakeAgent {
        root: dir.path(),
        edits: RefCell::new(vec![
            ("themes/night.json", "{ \"name\": \"night\" }\n"),
            ("cmux-next.json", "{ \"sidebar\": { \"density\": \"compact\" } }\n"),
        ]),
        calls: RefCell::new(Vec::new()),
        fail_send: false,
        send_code: "",
        receipt: false,
    };
    let wait = AskOptions { wait: true, ..AskOptions::default() };
    let request = Request::Ask { wish: "make the sidebar compact".into(), options: wait.clone() };
    let answer = execute(&customize, request, "cli", 1_000, &agent).ok().unwrap();
    let json = answer.json();
    assert_eq!(json["session_id"], "sess-1");
    assert_eq!(json["status"]["previewing"], true);
    assert_eq!(json["status"]["can_apply"], true);
    assert_eq!(json["status"]["changes"][0]["path"], "settings.json");
    assert_eq!(json["status"]["changes"][0]["by_hand"], false);
    let text = answer.human(2_000);
    assert!(text.contains("asked an agent: make the sidebar compact (chat sess-1)"), "{text}");
    assert!(text.contains("The sidebar is compact now."), "{text}");
    assert!(text.contains("previewing 1 change, not applied yet"), "{text}");
    assert!(text.contains("cmux customize apply"), "{text}");
    {
        let calls = agent.calls.borrow();
        assert_eq!(
            calls[0][..7],
            words(&[
                "--json",
                "chat",
                "--name",
                "Customize: make the sidebar compact",
                "--on",
                "here",
                "--wait"
            ])[..]
        );
        let brief = calls[0].last().unwrap();
        assert!(brief.starts_with("Customize this cmux for the person."), "{brief}");
        assert!(brief.contains("> make the sidebar compact"));
    }

    // The next ask goes on in the same chat.
    let request = Request::Ask { wish: "and a night theme".into(), options: wait };
    let answer = execute(&customize, request, "cli", 3_000, &agent).ok().unwrap();
    assert!(answer.human(4_000).contains("refining the preview: and a night theme"));
    // Here, whatever `CMUX_ON` or the saved default say: the brief is this machine's files.
    assert_eq!(
        agent.calls.borrow()[1][..6],
        words(&["--json", "chat", "send", "sess-1", "--on", "here"])[..]
    );

    // Apply labels the generation with everything that was asked.
    let Answer::Applied(applied) =
        execute(&customize, Request::Apply { note: None }, "cli", 5_000, &agent).ok().unwrap()
    else {
        panic!("not applied")
    };
    assert_eq!(applied.generation.label, "make the sidebar compact; and a night theme");
    assert_eq!(applied.generation.n, 2);
}

#[test]
fn an_ask_whose_chat_is_gone_starts_a_new_one_and_a_chat_that_fails_keeps_the_draft() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    customize.begin("first", "cli", 1).unwrap();
    customize.set_session("gone").unwrap();
    let agent = FakeAgent {
        root: dir.path(),
        edits: RefCell::new(Vec::new()),
        calls: RefCell::new(Vec::new()),
        fail_send: true,
        send_code: "selector.not_found",
        receipt: false,
    };
    let request = Request::Ask { wish: "second wish".into(), options: AskOptions::default() };
    execute(&customize, request, "cli", 2, &agent).ok().unwrap();
    let calls = agent.calls.borrow();
    assert_eq!((calls[0][2].as_str(), calls[1][1].as_str()), ("send", "chat"));
    assert_eq!(calls[1].iter().filter(|word| *word == "--wait").count(), 0);

    let failure = execute(
        &customize,
        Request::Ask {
            wish: "third wish".into(),
            options: AskOptions { new_chat: true, ..AskOptions::default() },
        },
        "cli",
        3,
        &super::ask::NoChat,
    )
    .err()
    .unwrap();
    assert_eq!(failure.code, "customize.chat_failed");
    assert!(failure.message.contains("the draft is open"));
    assert_eq!(customize.status().unwrap().draft.unwrap().asks.len(), 3);
}

#[test]
fn a_refinement_that_was_delivered_is_never_sent_to_a_second_chat() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    customize.begin("first", "cli", 1).unwrap();
    customize.set_session("sess-1").unwrap();
    for (code, ours, exit, delivered) in [
        ("chat.wait_timeout", "customize.chat_unfinished", 3, true),
        ("chat.turn_failed", "customize.chat_failed", 1, false),
        ("session.busy", "customize.chat_failed", 1, false),
    ] {
        let agent = FakeAgent {
            root: dir.path(),
            edits: RefCell::new(Vec::new()),
            calls: RefCell::new(Vec::new()),
            fail_send: true,
            send_code: code,
            receipt: false,
        };
        let options = AskOptions { wait: true, ..AskOptions::default() };
        let request = Request::Ask { wish: "smaller text".into(), options };
        let failure = execute(&customize, request, "cli", 2, &agent).err().unwrap();
        assert_eq!((failure.code.as_str(), failure.exit), (ours, exit), "{code}");
        assert_eq!(failure.details["session_id"], "sess-1");
        assert_eq!(failure.details["delivered"], delivered, "{code}");
        assert!(failure.message.contains("it was not sent again"), "{}", failure.message);
        let calls = agent.calls.borrow();
        assert_eq!(calls.len(), 1, "{code}: one chat got the ask, {calls:?}");
        assert_eq!(calls[0][2], "send");
        // The draft still names the chat that has the ask.
        assert_eq!(customize.status().unwrap().draft.unwrap().session.as_deref(), Some("sess-1"));
    }
}

#[test]
fn every_answer_a_person_reads_says_what_to_run_next() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("config/themes")).unwrap();
    fs::write(dir.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let run =
        |request: Request, now: u64| execute(&customize, request, "cli", now, &super::ask::NoChat);
    let clean = run(Request::Status, 1_000).ok().unwrap().human(61_000);
    assert_eq!(
        clean,
        "generation 1 is applied: the setup before the first customization (1m ago)\nnothing is previewing\n  cmux customize 'what you want' ask for a change\n"
    );
    fs::write(dir.path().join("config/themes/night.json"), "{ \"name\": }\n").unwrap();
    let broken = run(Request::Status, 2_000).ok().unwrap().human(2_000);
    assert!(broken.contains("  + themes/night.json  themes  edited by hand\n"), "{broken}");
    assert!(
        broken.contains("1 problem to fix before this applies:\n  themes/night.json:1:"),
        "{broken}"
    );
    let refused = run(Request::Apply { note: None }, 3_000).err().unwrap();
    assert_eq!((refused.code.as_str(), refused.exit), ("customize.invalid", 1));
    assert_eq!(refused.details["problems"][0]["path"], "themes/night.json");

    fs::write(dir.path().join("config/themes/night.json"), "{ \"name\": \"night\" }\n").unwrap();
    let applied =
        run(Request::Apply { note: Some("night".into()) }, 4_000).ok().unwrap().human(4_000);
    assert!(applied.starts_with("applied as generation 2: night (1 file)\n"), "{applied}");
    assert!(applied.contains("cmux customize rollback"), "{applied}");
    let back = run(Request::Rollback { to: None }, 5_000).ok().unwrap().human(5_000);
    assert!(back.starts_with("rolled back: generation 1 is live"), "{back}");
    let history = run(Request::Generations, 6_000).ok().unwrap().human(6_000);
    assert!(history.contains("*    1  just now  baseline "), "{history}");
    assert!(history.contains("     2  just now  applied    cli       1  night\n"), "{history}");
    let shown = run(Request::Show { n: 2 }, 7_000).ok().unwrap().human(7_000);
    assert!(
        shown.starts_with("+ themes/night.json\n@@ -0,0 +1,1 @@\n+{ \"name\": \"night\" }\n"),
        "{shown}"
    );
    let none = run(Request::Rollback { to: None }, 8_000).err().unwrap();
    assert_eq!(none.code, "customize.nothing_earlier");
    assert_eq!(ago(10_000_000, 1_000), "2h ago");
    assert_eq!(chat_name("  make   it  pop "), "Customize: make it pop");
    assert!(chat_name(&"x".repeat(80)).ends_with('…'));
}

/// The chat child gets one output flag, its own: `cmux --json customize …`
/// does not hand it a second.
#[test]
fn the_chat_child_never_gets_the_callers_output_flag() {
    use crate::cli::{GlobalArgs, OutputMode};
    for output in [OutputMode::Json, OutputMode::JsonLines, OutputMode::Quiet, OutputMode::Human] {
        let global =
            GlobalArgs { output, session: Some("work".to_owned()), ..GlobalArgs::default() };
        assert_eq!(super::child_globals(&global), ["--session", "work"], "{output:?}");
    }
}

/// With no `--wait`, `cmux chat` answers the receipt of the chat it made,
/// which names it as `result.chat`. The next ask goes on in that chat
/// instead of starting another.
#[test]
fn two_asks_that_do_not_wait_share_one_chat() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("config")).unwrap();
    fs::write(dir.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let agent = FakeAgent {
        root: dir.path(),
        edits: RefCell::new(Vec::new()),
        calls: RefCell::new(Vec::new()),
        fail_send: false,
        send_code: "",
        receipt: true,
    };
    for (at, wish) in [(1_000, "make the sidebar compact"), (2_000, "and a night theme")] {
        let request = Request::Ask { wish: wish.into(), options: AskOptions::default() };
        let answer = execute(&customize, request, "cli", at, &agent).ok().unwrap();
        assert_eq!(answer.json()["session_id"], "sess-9", "{wish}");
    }
    let calls = agent.calls.borrow();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0][..3], words(&["--json", "chat", "--name"])[..]);
    assert_eq!(calls[1][..6], words(&["--json", "chat", "send", "sess-9", "--on", "here"])[..]);
}

/// Records the words it was run with and answers as `cmux open` does.
struct Opener {
    calls: RefCell<Vec<Vec<String>>>,
}

impl Chat for Opener {
    fn run(&self, words: &[String]) -> Result<ChatResult, String> {
        self.calls.borrow_mut().push(words.to_vec());
        Ok(ChatResult { ok: true, stdout: String::new(), stderr: String::new() })
    }
}

/// `recipes` writes each recipe as a profile `use` previews, and `--open`
/// shows the guide in cmux; trying one is `use`, a draft like any other.
#[test]
fn recipes_are_profiles_to_use_and_open_shows_their_guide() {
    assert_eq!(parse(&words(&["recipes"])), Ok(Request::Recipes { open: false }));
    assert_eq!(parse(&words(&["recipes", "--open"])), Ok(Request::Recipes { open: true }));
    assert!(parse(&words(&["recipes", "glass"])).is_err());

    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("config")).unwrap();
    fs::write(dir.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let opener = Opener { calls: RefCell::new(Vec::new()) };
    let answer =
        execute(&customize, Request::Recipes { open: true }, "cli", 1_000, &opener).ok().unwrap();
    let json = answer.json();
    let recipes = json["recipes"].as_array().unwrap();
    assert_eq!(recipes.len(), cmux_customize_recipes::RECIPES.len());
    let guide = json["guide"].as_str().unwrap().to_owned();
    assert_eq!(json["opened"], true);
    assert_eq!(*opener.calls.borrow(), vec![vec!["open".to_owned(), guide.clone()]]);
    assert!(fs::read_to_string(&guide).unwrap().contains("cmux customize use "));
    let human = answer.human(1_000);
    assert!(human.contains("compact-sidebar"), "{human}");
    assert!(human.contains("the guide is open in cmux"), "{human}");

    let compact = recipes.iter().find(|recipe| recipe["name"] == "compact-sidebar").unwrap();
    let path = compact["path"].as_str().unwrap().to_owned();
    assert_eq!(compact["try"], format!("cmux customize use '{path}'"));
    let used = execute(
        &customize,
        Request::Use { source: path, watch: false },
        "cli",
        2_000,
        &super::ask::NoChat,
    )
    .ok()
    .unwrap();
    assert_eq!(used.json()["profile"], "compact-sidebar");
    let settings = fs::read_to_string(dir.path().join("config/cmux-next.json")).unwrap();
    assert!(settings.contains("sidebarRowHeight"), "{settings}");
    execute(&customize, Request::Discard, "cli", 3_000, &super::ask::NoChat).ok().unwrap();
    let back = fs::read_to_string(dir.path().join("config/cmux-next.json")).unwrap();
    assert_eq!(back, "{}\n");
}

#[test]
fn use_takes_a_recipe_by_name_and_a_saved_profile_of_that_name_wins() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("config")).unwrap();
    fs::write(dir.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let run =
        |request, at| execute(&customize, request, "cli", at, &super::ask::NoChat).ok().unwrap();

    // No `recipes` first: the name alone finds the recipe, theme file included.
    let used = run(Request::Use { source: "ukiyo-e".to_owned(), watch: false }, 1_000);
    assert_eq!(used.json()["profile"], "ukiyo-e");
    let settings = fs::read_to_string(dir.path().join("config/cmux-next.json")).unwrap();
    assert!(settings.contains("\"ukiyo-e\""), "{settings}");
    run(Request::Discard, 2_000);

    // A saved profile called the same wins over the recipe.
    run(Request::Save { name: "ukiyo-e".to_owned(), note: "mine".to_owned() }, 3_000);
    let used = run(Request::Use { source: "ukiyo-e".to_owned(), watch: false }, 4_000);
    assert_eq!(used.json()["profile"], "ukiyo-e");
    let settings = fs::read_to_string(dir.path().join("config/cmux-next.json")).unwrap();
    assert!(!settings.contains("themeFile"), "{settings}");
    run(Request::Discard, 5_000);

    // Neither a profile nor a recipe: the profile error stands.
    assert!(
        execute(
            &customize,
            Request::Use { source: "no-such-look".to_owned(), watch: false },
            "cli",
            6_000,
            &super::ask::NoChat
        )
        .is_err()
    );
}

#[test]
fn try_parses_a_profile_and_minutes_and_keep_and_revert_take_nothing() {
    let tried = |source: Option<&str>, ms: u64| {
        Ok(Request::Try { source: source.map(str::to_owned), duration_ms: ms })
    };
    assert_eq!(parse(&words(&["try"])), tried(None, 600_000));
    assert_eq!(parse(&words(&["try", "night.json"])), tried(Some("night.json"), 600_000));
    assert_eq!(parse(&words(&["try", "night", "--minutes", "2"])), tried(Some("night"), 120_000));
    assert_eq!(parse(&words(&["try", "-m", "0.5"])), tried(None, 30_000));
    assert_eq!(parse(&words(&["keep"])), Ok(Request::Keep));
    assert_eq!(parse(&words(&["revert"])), Ok(Request::Revert));
    assert_eq!(parse(&words(&["settle", "--wait"])), Ok(Request::Settle { wait: true }));
    // Code to try on: the same words `use` takes, timed.
    assert_eq!(parse(&words(&["try", "pr:43496", "-m", "5"])), tried(Some("pr:43496"), 300_000));
    assert_eq!(parse(&words(&["try", "dir:~/src/cmux"])), tried(Some("dir:~/src/cmux"), 600_000));
    assert_eq!(parse(&words(&["settle", "--wait", "--code"])), Ok(Request::SettleCode));
    for bad in [
        &["try", "--minutes"][..],
        &["try", "--minutes", "0"],
        &["try", "--minutes", "soon"],
        &["try", "a", "b"],
        &["try", "--bogus"],
        &["keep", "it"],
        &["revert", "now"],
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad:?}");
    }
}

/// A try-on from the CLI shows the time left and the two ways out, and the
/// first verb after its time reverts it, whatever that verb is.
#[test]
fn a_try_on_says_its_time_and_reverts_at_the_first_look_after_it() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("config")).unwrap();
    fs::write(dir.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let recipe = dir.path().join("night.json");
    fs::write(
        &recipe,
        r#"{"cmuxProfile":1,"name":"night","title":"Night","category":"look",
            "files":{"themes/night.json":"{ \"name\": \"night\" }\n"}}"#,
    )
    .unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let run =
        |request: Request, now: u64| execute(&customize, request, "cli", now, &super::ask::NoChat);
    let source = Some(recipe.display().to_string());
    let tried = run(Request::Try { source, duration_ms: 120_000 }, 1_000).ok().unwrap();
    let json = tried.json();
    assert_eq!(json["try_on"]["expires_ms"], 121_000);
    assert_eq!(json["try_on"]["revert_to"], 1);
    let text = tried.human(1_000);
    assert!(
        text.starts_with("trying on: profile night (generation 2), 2 minutes left\n"),
        "{text}"
    );
    assert!(text.contains("cmux customize keep") && text.contains("cmux customize revert"));
    let status = run(Request::Status, 31_000).ok().unwrap();
    assert!(status.human(31_000).contains("trying on: profile night, 2 minutes left"));
    assert_eq!(status.json()["try_on"]["generation"], 2);
    assert!(dir.path().join("config/themes/night.json").exists());

    // Nothing ran at 121 s; the next verb, at 200 s, is the look that reverts.
    let after = run(Request::Generations, 200_000).ok().unwrap();
    assert_eq!(after.json()["current"], 1);
    assert!(!dir.path().join("config/themes/night.json").exists());
    let nothing = run(Request::Keep, 201_000).ok().unwrap().human(201_000);
    assert_eq!(nothing, "nothing is being tried on\n");
    let none = run(Request::Try { source: None, duration_ms: 60_000 }, 202_000).err().unwrap();
    assert_eq!(none.code, "customize.nothing_to_try");
}

#[test]
fn schema_lists_what_can_change_and_needs_no_store() {
    use super::SchemaFormat;
    use cmux_customize::schema::Section;
    assert_eq!(
        parse(&words(&["schema"])),
        Ok(Request::Schema { section: None, format: SchemaFormat::Schema })
    );
    assert_eq!(
        parse(&words(&["schema", "views"])),
        Ok(Request::Schema { section: Some(Section::Views), format: SchemaFormat::Schema })
    );
    assert_eq!(
        parse(&words(&["schema", "--typescript"])),
        Ok(Request::Schema { section: None, format: SchemaFormat::TypeScript })
    );
    assert!(parse(&words(&["schema", "colours"])).unwrap_err().contains("settings, theme"));
    assert!(parse(&words(&["schema", "views", "--rust"])).is_err());
    assert!(parse(&words(&["schema", "--yaml"])).is_err());

    // The MCP path answers from this build's tables before it opens the store.
    let views =
        super::run_json(&crate::cli::GlobalArgs::default(), &words(&["schema", "views"]), "mcp")
            .expect("views");
    let slots = views["views"].as_array().expect("a list of view slots");
    assert!(slots.iter().any(|slot| slot["interface"] == "cmux.section/1"));
    assert!(views.get("settings").is_none());
    let all = super::run_json(&crate::cli::GlobalArgs::default(), &words(&["schema"]), "mcp")
        .expect("the whole schema");
    let accent = all["settings"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["key"] == "appearance.accent"))
        .expect("appearance.accent is listed");
    assert!(accent.get("default").is_some() && accent.get("schema").is_some());
    let ts = super::run_json(
        &crate::cli::GlobalArgs::default(),
        &words(&["schema", "--typescript"]),
        "mcp",
    )
    .expect("typescript");
    assert!(ts["source"].as_str().is_some_and(|s| s.contains("export interface CmuxSettings")));

    let human = Answer::Schema(
        cmux_customize::schema::Schema::current(),
        Some(Section::Views),
        SchemaFormat::Schema,
    )
    .human(0);
    assert!(human.starts_with("View slots"), "{human}");
    assert!(human.contains("cmux.section/1") && human.contains("defaultRegion: top|middle|bottom"));
    assert!(human.contains("\nNext:\n"));
}
