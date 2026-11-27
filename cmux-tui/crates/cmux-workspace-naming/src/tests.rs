//! Parity with the Swift suites this crate replaces (CmuxNextWorkspaceNamingTests), through the
//! JSON ops the app calls.

use crate::ops::{OpError, WorkspaceNaming};
use serde_json::{Value, json};

fn call(op: &str, request: Value) -> Value {
    WorkspaceNaming::new().call(&format!("workspace_naming_{op}"), request).unwrap()
}

fn terminal(title: Option<&str>, cwd: Option<&str>) -> Value {
    json!({"terminal": {"_0": {"kind": "terminal", "title": title, "cwd": cwd}}})
}

fn chat(user_name: Option<&str>, title: Option<&str>) -> Value {
    json!({"chat": {"user_name": user_name, "title": title}})
}

fn browser(title: &str) -> Value {
    json!({"browser": {"title": title}})
}

fn label(named: Value, front: Value, anchor: Value) -> Value {
    call("label", json!({"enabled": true, "named": named, "front": front, "anchor": anchor}))["label"].clone()
}

fn ws(name: &str) -> Value {
    json!({"name": name})
}

#[test]
fn the_default_variant_persists() {
    assert_eq!(call("defaults", Value::Null), json!({"variant": "persist"}));
}

#[test]
fn a_browser_front_shows_its_page_title_or_its_anchor() {
    let page = browser("Pull requests · cmux");
    assert_eq!(label(ws("workspace-3"), page.clone(), Value::Null), "Pull requests · cmux");
    let split = browser("browser.md: Widevine and H.264/AAC ship");
    assert_eq!(
        label(ws("workspace-3"), split.clone(), chat(None, Some("Fix image paste"))),
        "Fix image paste"
    );
    assert_eq!(label(ws("workspace-3"), split, terminal(Some("zsh"), Some("/tmp/api"))), "api");
    assert_eq!(label(ws("workspace-3"), page.clone(), chat(None, None)), Value::Null);
    let user = json!({"name": "#20367: CI red", "source": "user"});
    assert_eq!(label(user, page.clone(), Value::Null), Value::Null);
    assert_eq!(
        label(json!({"name": "workspace-3", "title": "Mine"}), page, Value::Null),
        Value::Null
    );
}

#[test]
fn chats_and_terminals_label_unnamed_workspaces() {
    let w = || ws("workspace-3");
    assert_eq!(
        label(w(), chat(None, Some("Fix the sidebar drag")), Value::Null),
        "Fix the sidebar drag"
    );
    assert_eq!(
        label(w(), chat(Some("Release notes"), Some("Draft")), Value::Null),
        "Release notes"
    );
    assert_eq!(label(w(), chat(None, None), Value::Null), Value::Null);
    assert_eq!(label(w(), chat(Some("  "), Some("\n")), Value::Null), Value::Null);
    assert_eq!(
        label(w(), terminal(Some("Fix the login bug"), None), Value::Null),
        "Fix the login bug"
    );
    let user = json!({"name": "Release", "source": "user"});
    assert_eq!(label(user, terminal(Some("Fix the login bug"), None), Value::Null), Value::Null);
    assert_eq!(
        label(w(), terminal(Some("npm run dev"), Some("/Users/me/src/cmux")), Value::Null),
        "npm run dev"
    );
    assert_eq!(label(w(), terminal(Some("zsh"), Some("/Users/me/src/cmux")), Value::Null), "cmux");
    assert_eq!(label(w(), terminal(Some("-bash"), Some("/tmp/api")), Value::Null), "api");
    assert_eq!(label(w(), terminal(Some("~"), Some("/tmp/api")), Value::Null), "api");
    assert_eq!(label(w(), chat(None, Some("one\ntwo")), Value::Null), "one two");
    let long = "a".repeat(200);
    let cut = label(w(), chat(None, Some(&long)), Value::Null);
    assert_eq!(cut.as_str().unwrap().chars().count(), 80);
    assert_eq!(
        label(json!({"name": "workspace-3", "title": ""}), chat(None, Some("Plan")), Value::Null),
        "Plan"
    );
    assert_eq!(label(w(), Value::Null, Value::Null), Value::Null);
    assert_eq!(
        label(w(), json!({"browser": {"title": "Secret", "off_the_record": true}}), Value::Null),
        "Secret"
    );
    let off = call("label", json!({"enabled": false, "named": w(), "front": browser("GitHub")}));
    assert_eq!(off["label"], Value::Null);
}

#[test]
fn legacy_defaults_still_take_a_front_name() {
    let front = terminal(Some("npm run dev"), None);
    assert_eq!(label(ws("~"), front.clone(), Value::Null), "npm run dev");
    assert_eq!(label(ws(""), front.clone(), Value::Null), "npm run dev");
    assert_eq!(
        label(json!({"name": "~", "title": "My work"}), front.clone(), Value::Null),
        Value::Null
    );
    let renamed = json!({"name": "~", "source": "user", "revision": 1});
    assert_eq!(label(renamed, front.clone(), Value::Null), Value::Null);
    let modern = json!({"name": "~", "source": "user", "allows_legacy_defaults": false});
    assert_eq!(label(modern, front, Value::Null), Value::Null);
}

fn persisted(front: Value, named: Value, persist: Value, enabled: bool, variant: &str) -> Value {
    call(
        "persisted_name",
        json!({"enabled": enabled, "variant": variant, "named": named, "front": front, "persist": persist}),
    )["name"]
        .clone()
}

fn titled_chat() -> Value {
    json!({"chat": {"title": "Fix the sidebar drag", "generated_title": "Fix the sidebar drag"}})
}

#[test]
fn persist_writes_only_a_generated_chat_title() {
    let local = json!({"is_local_machine": true});
    let p = |front: Value, named: Value| persisted(front, named, local.clone(), true, "persist");
    assert_eq!(p(titled_chat(), ws("workspace-3")), "Fix the sidebar drag");
    let renamed = json!({"is_local_machine": true, "already_renamed": true});
    assert_eq!(persisted(titled_chat(), ws("workspace-3"), renamed, true, "persist"), Value::Null);
    assert_eq!(
        p(chat(None, Some("can you look at why the build fails")), ws("workspace-3")),
        Value::Null
    );
    assert_eq!(p(chat(Some("Release notes"), Some("Draft")), ws("workspace-3")), Value::Null);
    assert_eq!(p(Value::Null, ws("workspace-3")), Value::Null);
    assert_eq!(p(terminal(Some("vim notes.md"), None), ws("workspace-3")), Value::Null);
    assert_eq!(p(browser("GitHub"), ws("workspace-3")), Value::Null);
    assert_eq!(p(titled_chat(), ws("Old generated title")), "Fix the sidebar drag");
    assert_eq!(p(titled_chat(), ws("Fix the sidebar drag")), Value::Null);
    assert_eq!(
        p(titled_chat(), json!({"name": "api", "source": "user", "revision": 1})),
        Value::Null
    );
    assert_eq!(p(titled_chat(), json!({"name": "workspace-3", "title": "Mine"})), Value::Null);
    let remote = json!({"supports_name_source": true});
    assert_eq!(
        persisted(titled_chat(), ws("workspace-3"), remote.clone(), true, "persist"),
        "Fix the sidebar drag"
    );
    assert_eq!(
        persisted(titled_chat(), ws("workspace-3"), json!({}), true, "persist"),
        Value::Null
    );
    assert_eq!(
        persisted(titled_chat(), ws("workspace-3"), local.clone(), true, "live"),
        Value::Null
    );
    assert_eq!(persisted(titled_chat(), ws("workspace-3"), local, false, "persist"), Value::Null);
    let created = json!({"name": "workspace-151", "source": "user"});
    assert_eq!(persisted(titled_chat(), created, remote, true, "persist"), "Fix the sidebar drag");
}

fn user_named(named: Value) -> bool {
    call("is_user_named", json!({"named": named}))["user_named"].as_bool().unwrap()
}

#[test]
fn a_created_default_recorded_as_the_users_is_still_unnamed() {
    let modern = |name: &str, revision: u64| json!({"name": name, "source": "user", "revision": revision, "allows_legacy_defaults": false});
    assert!(!user_named(modern("workspace-151", 0)));
    assert!(user_named(modern("workspace-151", 1)));
    assert!(user_named(modern("~", 0)));
    assert!(user_named(modern("api", 0)));
    assert!(user_named(modern(" workspace-151 ", 0)));
    assert!(!user_named(ws("workspace-3")));
    assert!(!user_named(json!({"name": "workspace-3", "title": ""})));
    assert!(user_named(json!({"name": "workspace-3", "title": "Mine"})));
    assert!(user_named(json!({"name": "api", "source": "user"})));
    assert!(user_named(json!({"name": "~", "source": "user", "revision": 1})));
}

fn for_tab(tab: Value) -> Value {
    call("for_tab", json!({"tab": tab}))["name"].clone()
}

#[test]
fn a_moved_tab_names_its_workspace() {
    for title in
        ["about:blank", "chrome://newtab", "chrome://newtab/", "ABOUT:BLANK", "  about:blank  "]
    {
        assert_eq!(for_tab(json!({"title": title})), Value::Null, "{title}");
    }
    assert_eq!(for_tab(json!({"title": "about:blank", "cwd": "/Users/me/src/cmux"})), "cmux");
    assert_eq!(for_tab(json!({"title": "about:blank", "user_name": "Planning"})), "Planning");
    assert_eq!(for_tab(json!({"title": "zsh", "cwd": "/"})), Value::Null);
    assert_eq!(for_tab(json!({"title": "zsh", "cwd": "/tmp/api/"})), "api");
    let page = |title: Option<&str>, user: Option<&str>| json!({"kind": "page", "title": title, "user_name": user, "cwd": "/Users/me/src/cmux"});
    assert_eq!(for_tab(page(Some("Chief"), None)), "Chief");
    assert_eq!(for_tab(page(Some("What’s New"), None)), "What’s New");
    assert_eq!(for_tab(page(Some("README.md"), Some("Docs"))), "Docs");
    for title in [None, Some(""), Some("about:blank"), Some("chrome://newtab/")] {
        assert_eq!(for_tab(page(title, None)), Value::Null);
    }
}

#[test]
fn a_browser_tab_is_named_by_its_title_else_its_site() {
    let tab = |page_title: Option<&str>, title: Option<&str>, url: &str| json!({"kind": "browser", "page_title": page_title, "title": title, "url": url});
    assert_eq!(for_tab(tab(Some("Docs"), Some("x"), "https://a.com")), "Docs");
    assert_eq!(for_tab(tab(Some("https://a.com/x"), Some("Title"), "https://a.com/x")), "Title");
    assert_eq!(
        for_tab(tab(None, Some("https://www.github.com/x"), "https://www.github.com/x")),
        "github.com"
    );
    assert_eq!(for_tab(tab(None, None, "https://user:pw@[::1]:8080/")), "::1");
    assert_eq!(for_tab(tab(None, None, "http://ex%41mple.com:80/a")), "exAmple.com");
    assert_eq!(for_tab(tab(None, None, "about:blank")), Value::Null);
    assert_eq!(for_tab(tab(None, None, "not a url")), Value::Null);
}

fn last_tab(request: Value) -> Value {
    call("for_last_tab", request)["name"].clone()
}

#[test]
fn the_last_tab_out_names_the_workspace_it_leaves() {
    let blank = json!({"title": "about:blank"});
    assert_eq!(last_tab(json!({"name": "workspace-4", "tab": blank})), Value::Null);
    assert_eq!(last_tab(json!({"name": "Research", "tab": blank})), "Research");
    let whats_new = json!({"kind": "page", "title": "What’s New"});
    assert_eq!(last_tab(json!({"name": "workspace-42", "tab": whats_new})), "What’s New");
    assert_eq!(last_tab(json!({"name": "Sidebar", "tab_name": "Fix"})), "Sidebar");
    assert_eq!(last_tab(json!({"name": "workspace-40", "tab_name": "Fix"})), "Fix");
    assert_eq!(
        last_tab(json!({"name": "workspace-40", "title": " Launch ", "tab_name": "Fix"})),
        "Launch"
    );
    let modern = |name: &str| json!({"name": name, "tab_name": "api", "source": "user", "revision": 0, "allows_legacy_defaults": false});
    assert_eq!(last_tab(modern("workspace-151")), "api");
    assert_eq!(last_tab(modern(" workspace-151 ")), "workspace-151");
    assert_eq!(last_tab(modern("~")), "~");
}

#[test]
fn a_group_is_named_by_its_name_else_its_first_tab() {
    let group =
        |name: Value| call("for_group", json!({"name": name, "first_tab": {"title": "npm test"}}));
    assert_eq!(group(json!("Build"))["name"], "Build");
    assert_eq!(group(json!(" \n "))["name"], "npm test");
    assert_eq!(group(Value::Null)["name"], "npm test");
}

#[test]
fn a_page_title_is_its_name_then_a_title_that_is_not_its_address_then_its_site() {
    let title = |page: Value| call("page_title", json!({"page": page}))["title"].clone();
    assert_eq!(title(json!({"name": " Mine ", "live_title": "Live"})), "Mine");
    assert_eq!(title(json!({"live_title": "Live", "title_text": "Rec"})), "Live");
    let url = "https://www.example.com/a";
    assert_eq!(title(json!({"live_title": url, "title_text": "Rec", "live_url": url})), "Rec");
    assert_eq!(title(json!({"live_title": url, "title_text": url, "url": url})), "example.com");
    assert_eq!(title(json!({})), Value::Null);
}

fn activity(tabs: Value) -> Value {
    call("activity", json!({"tabs": tabs}))
}

#[test]
fn activity_asks_haiku_and_falls_back_to_the_default_small_model() {
    let reply = activity(json!([{"browser": {"title": "Docs"}}]));
    assert_eq!(reply["params"]["model"], "claude-haiku-5-5");
    assert_eq!(reply["params"]["harness"], "claude");
    assert_eq!(reply["params"]["maxTokens"], 24);
    assert_eq!(reply["params"]["timeoutMs"], 20000);
    assert_eq!(reply["fallback_params"].get("model"), None);
    assert_eq!(reply["fallback_params"].get("harness"), None);
    assert_eq!(reply["fallback_params"]["prompt"], reply["prompt"]);
}

#[test]
fn activity_lists_chats_terminals_and_pages() {
    let reply = activity(json!([
        {"chat": {"title": "Fix login", "prompts": ["Second ask", "Third ask", "Fourth ask"]}},
        {"terminal": {"folder": "/Users/me/web", "title": "npm test"}},
        {"browser": {"title": "Login · Docs"}},
    ]));
    let prompt = reply["prompt"].as_str().unwrap();
    assert!(prompt.starts_with("Name this workspace in 2 to 5 words from what its tabs show.\n"));
    assert!(prompt.ends_with(
        "Tabs:\n- Agent chat: Fix login\n  - asked: Second ask\n  - asked: Third ask\n  - asked: Fourth ask\n- Terminal in /Users/me/web: npm test\n- Web page: Login · Docs"
    ));
    let empty = activity(json!([{"browser": {}}, {"chat": {}}, {"terminal": {"title": " \n"}}]));
    assert_eq!(empty["empty"], true);
    assert_eq!(empty["tabs"], json!([]));
}

#[test]
fn activity_reads_one_tab_as_snippets() {
    let tab = call("activity_tab", json!({"tab": {"terminal": {"folder": " ", "title": "a\n b"}}}));
    assert_eq!(tab["tab"], json!({"terminal": {"folder": null, "title": "a b"}}));
    let none = call("activity_tab", json!({"tab": {"chat": {"title": "\t", "prompts": [" "]}}}));
    assert_eq!(none["tab"], Value::Null);
}

#[test]
fn the_prompt_stays_under_the_completion_limit() {
    let prompt = "界".repeat(120);
    let tab = json!({"chat": {"title": "Chat", "prompts": [prompt, prompt, prompt]}});
    let reply = activity(Value::Array(vec![tab; 14]));
    let text = reply["prompt"].as_str().unwrap();
    assert!(text.len() <= 4000);
    assert!(text.contains("- Agent chat: Chat"));
    assert_eq!(reply["tabs"].as_array().unwrap().len(), 12);
}

#[test]
fn snippets_are_one_short_line() {
    let long = "word ".repeat(60);
    let snippet = call("snippet", json!({"text": format!("a\n\n  b \t{long}")}))["snippet"].clone();
    let snippet = snippet.as_str().unwrap();
    assert!(snippet.starts_with("a b word"));
    assert_eq!(snippet.chars().count(), 120);
    assert!(snippet.ends_with('…'));
    assert_eq!(call("snippet", json!({"text": "  \n "}))["snippet"], Value::Null);
}

#[test]
fn the_reply_keeps_its_first_line_without_quotes_labels_or_extra_words() {
    let name = |reply: &str| call("activity_name", json!({"reply": reply}))["name"].clone();
    assert_eq!(name("\"Login Bug Fix\"\n\nThis workspace is about…"), "Login Bug Fix");
    assert_eq!(name("Name: Release notes draft."), "Release notes draft");
    assert_eq!(name("**Sidebar drag polish**"), "Sidebar drag polish");
    assert_eq!(name("one two three four five six seven"), "one two three four five");
    assert_eq!(name(" \n\"\" "), Value::Null);
    assert_eq!(name("“Curly quotes”."), "Curly quotes”");
    assert_eq!(name("“Curly quotes”"), "Curly quotes");
}

#[test]
fn refusals_come_in_the_actions_order() {
    let refusal = |gate: Value| call("activity_refusal", gate)["refusal"].clone();
    assert_eq!(refusal(json!({})), "no_workspace");
    assert_eq!(refusal(json!({"has_workspace": true})), "old_daemon");
    assert_eq!(
        refusal(json!({"has_workspace": true, "guards_revision": true})),
        "nothing_to_name_from"
    );
    let all_but_agents =
        json!({"has_workspace": true, "guards_revision": true, "has_activity": true});
    assert_eq!(refusal(all_but_agents), "no_agents");
    let all = json!({"has_workspace": true, "guards_revision": true, "has_activity": true, "has_agents": true});
    assert_eq!(refusal(all), Value::Null);
}

#[test]
fn a_hold_keeps_each_namers_last_name_until_forgotten() {
    let mut naming = WorkspaceNaming::new();
    let mut op =
        |op: &str, request: Value| naming.call(&format!("workspace_naming_{op}"), request).unwrap();
    let settle = json!({"hold": 1, "workspace": "w", "namer": "t1@s1|", "label": "Hide agents"});
    assert_eq!(op("hold_settle", settle)["name"], "Hide agents");
    assert_eq!(
        op("hold_settle", json!({"hold": 1, "workspace": "w", "namer": "t1@s1|"}))["name"],
        "Hide agents"
    );
    assert_eq!(
        op("hold_settle", json!({"hold": 1, "workspace": "w", "namer": "t2@|"}))["name"],
        Value::Null
    );
    assert_eq!(
        op("hold_settle", json!({"hold": 2, "workspace": "w", "namer": "t1@s1|"}))["name"],
        Value::Null
    );
    op("hold_forget", json!({"hold": 1, "workspace": "w"}));
    assert_eq!(
        op("hold_settle", json!({"hold": 1, "workspace": "w", "namer": "t1@s1|"}))["name"],
        Value::Null
    );
    let launcher = |matches: bool, name: &str| json!({"hold": 1, "workspace": "w", "name": name, "session": "s1", "matches": matches});
    assert_eq!(op("hold_launcher_named", launcher(false, "Mango"))["launcher_named"], false);
    assert_eq!(op("hold_launcher_named", launcher(true, "Mango"))["launcher_named"], true);
    assert_eq!(op("hold_launcher_named", launcher(false, "Mango"))["launcher_named"], true);
    assert_eq!(op("hold_launcher_named", launcher(false, "Kiwi"))["launcher_named"], false);
    op("hold_drop", json!({"hold": 1}));
    assert_eq!(op("hold_launcher_named", launcher(false, "Mango"))["launcher_named"], false);
}

fn submission(revision: u64, name: &str) -> Value {
    json!({"daemon_generation": 7, "name_revision": revision, "front_tab_id": "t1",
           "front_agent_session": {"session": "s1"}, "name": name})
}

#[test]
fn a_namer_keeps_one_submission_per_workspace() {
    let mut naming = WorkspaceNaming::new();
    let mut op =
        |op: &str, request: Value| naming.call(&format!("workspace_naming_{op}"), request).unwrap();
    let slot = json!({"machine_id": "local", "workspace_id": "w1"});
    let target = |revision: u64| json!({"daemon_generation": 7, "name_revision": revision});
    let plan = |candidate: Value, revision: u64| json!({"namer": 1, "slot": slot, "target": target(revision), "candidate": candidate});
    assert_eq!(op("namer_plan", plan(submission(0, "Plan"), 0))["rename"], true);
    let begin = json!({"namer": 1, "slot": slot, "submission": submission(0, "Plan")});
    let attempt = op("namer_begin", begin.clone())["attempt"].clone();
    assert_eq!(attempt, 0);
    // The same submission is planned and queued once.
    assert_eq!(op("namer_plan", plan(submission(0, "Plan"), 0))["rename"], false);
    assert_eq!(op("namer_begin", begin.clone())["attempt"], Value::Null);
    // The send goes when its target is current.
    let may = |attempt: &Value, current: bool| json!({"namer": 1, "slot": slot, "attempt": attempt, "current": current});
    assert_eq!(op("namer_may_send", may(&attempt, true)), json!({"send": true, "retry": false}));
    // A failed accepted send releases that exact attempt, and only that one.
    op("namer_release", json!({"namer": 1, "slot": slot, "attempt": 9}));
    assert_eq!(op("namer_begin", begin.clone())["attempt"], Value::Null);
    op("namer_release", json!({"namer": 1, "slot": slot, "attempt": attempt}));
    let second = op("namer_begin", begin.clone())["attempt"].clone();
    assert_eq!(second, 1);
    // A stale target at send time releases and asks for a retry; a stale attempt does nothing.
    assert_eq!(op("namer_may_send", may(&second, false)), json!({"send": false, "retry": true}));
    assert_eq!(op("namer_may_send", may(&second, true)), json!({"send": false, "retry": false}));
    // A newer title replaces the live one; a moved revision drops it.
    let third = op("namer_begin", begin)["attempt"].clone();
    assert_eq!(op("namer_plan", plan(submission(0, "Newer"), 0))["rename"], true);
    assert_eq!(op("namer_may_send", may(&third, true))["send"], false);
    let fourth =
        op("namer_begin", json!({"namer": 1, "slot": slot, "submission": submission(0, "Newer")}))
            ["attempt"]
            .clone();
    assert_eq!(op("namer_plan", plan(Value::Null, 1))["rename"], false);
    assert_eq!(op("namer_may_send", may(&fourth, true))["send"], false);
    // A workspace no longer listed keeps nothing.
    let fifth =
        op("namer_begin", json!({"namer": 1, "slot": slot, "submission": submission(1, "Newer")}))
            ["attempt"]
            .clone();
    op("namer_list", json!({"namer": 1, "slots": []}));
    assert_eq!(op("namer_may_send", may(&fifth, true))["send"], false);
    op("namer_drop", json!({"namer": 1}));
}

#[test]
fn unknown_and_malformed_ops_are_refused() {
    let mut naming = WorkspaceNaming::new();
    assert!(matches!(
        naming.call("workspace_naming_nope", Value::Null),
        Err(OpError::UnknownOp(_))
    ));
    assert!(matches!(
        naming.call("workspace_naming_for_tab", json!({"tab": 3})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        naming.call("workspace_naming_hold_settle", json!({})),
        Err(OpError::Invalid(_))
    ));
    assert!(WorkspaceNaming::serves("workspace_naming_clean"));
    assert!(!WorkspaceNaming::serves("tab_discard_plan"));
}
