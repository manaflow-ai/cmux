//! RFD 0003 step 4's rules: which page gets Publish, the popover, the run's outcome, the Apps
//! section.

use super::*;
use serde_json::json;

fn previews() -> Vec<KnownPreview> {
    vec![KnownPreview {
        machine: "vm_1".into(),
        machine_name: "invoice-box".into(),
        port: 3000,
        origin: "https://p-3000--vm1.preview.cmux.dev".into(),
    }]
}

fn page(url: &str, title: Option<&str>) -> Page {
    Page { url: url.into(), title: title.map(str::to_owned), previews: previews() }
}

#[test]
fn only_a_known_cloud_preview_gets_publish() {
    let t =
        target(&page("https://P-3000--vm1.preview.cmux.dev:443/inbox?x=1", Some("Invoice triage")))
            .expect("the preview's own origin is publishable");
    assert_eq!(
        (t.machine.as_str(), t.port, t.suggested_name.as_str()),
        ("vm_1", 3000, "Invoice triage")
    );
    // Another host, another port on the same host, a non-web scheme: no button.
    assert_eq!(target(&page("https://example.com/", None)), None);
    assert_eq!(target(&page("https://p-3000--vm1.preview.cmux.dev:8443/", None)), None);
    assert_eq!(target(&page("file:///tmp/x.html", None)), None);
    assert_eq!(
        target(&Page { url: "https://p-3000--vm1.preview.cmux.dev/".into(), ..Page::default() }),
        None
    );
}

#[test]
fn a_url_like_or_empty_title_falls_back_to_the_port() {
    for title in [None, Some(""), Some("localhost:3000"), Some("https://x.dev"), Some("—")] {
        let t = target(&page("https://p-3000--vm1.preview.cmux.dev/", title)).unwrap();
        assert_eq!(t.suggested_name, "App on port 3000", "{title:?}");
    }
}

#[test]
fn origins_drop_default_ports_and_userinfo() {
    assert_eq!(origin_of("HTTPS://a.dev:443/x").as_deref(), Some("https://a.dev"));
    assert_eq!(origin_of("http://u:p@a.dev:80").as_deref(), Some("http://a.dev"));
    assert_eq!(origin_of("http://a.dev:8080/").as_deref(), Some("http://a.dev:8080"));
    assert_eq!(origin_of("https://"), None);
    assert_eq!(origin_of("about:blank"), None);
}

fn the_target() -> Target {
    target(&page("https://p-3000--vm1.preview.cmux.dev/", Some("Invoice triage"))).unwrap()
}

#[test]
fn the_popover_is_private_by_default_and_runs_publish_on_the_port() {
    let p = popover(&the_target(), &Draft::default());
    assert_eq!(p.audience, Audience::Private);
    assert_eq!(p.slug.as_deref(), Some("invoice-triage"));
    assert_eq!(p.host_label.as_deref(), Some("a-invoice-triage--…"));
    assert_eq!(p.start_from, "Inferred from port 3000 on invoice-box");
    assert_eq!(p.command, "cmux app publish invoice-triage --port 3000 --json");
    assert!(p.can_publish);
}

#[test]
fn team_adds_the_team_grant_and_a_typed_name_replaces_the_title() {
    let draft = Draft { name: Some("Q3 board!".into()), audience: Audience::Team };
    let p = popover(&the_target(), &draft);
    assert_eq!(
        p.argv,
        ["cmux", "app", "publish", "q3-board", "--port", "3000", "--share", "team", "--json"]
    );
}

#[test]
fn a_name_with_no_letter_or_digit_cannot_publish() {
    let p =
        popover(&the_target(), &Draft { name: Some(" — ".into()), audience: Audience::Private });
    assert!(!p.can_publish);
    assert_eq!(p.problem, Some(Problem::NameEmpty));
    assert!(p.argv.is_empty());
}

#[test]
fn shell_line_quotes_only_what_needs_it() {
    let argv = ["cmux", "it's", "a b", ""].map(str::to_owned);
    assert_eq!(shell_line(&argv), r#"cmux 'it'\''s' 'a b' ''"#);
}

#[test]
fn a_live_publish_answers_its_url_and_version() {
    let out = r#"{"app":{"name":"Invoice triage","slug":"invoice-triage","url":"https://a-invoice-triage--abcdefgh.preview.cmux.dev","live":3,"versions":3},"version":{"n":3,"state":"live"},"url":"https://a-invoice-triage--abcdefgh.preview.cmux.dev","inferred":null,"warnings":["dirty tree included"]}"#;
    assert_eq!(
        outcome(&format!("staging\n{out}\n"), "", 0),
        Outcome::Published {
            slug: "invoice-triage".into(),
            version: Some(3),
            url: Some("https://a-invoice-triage--abcdefgh.preview.cmux.dev".into()),
            warnings: vec!["dirty tree included".into()],
        }
    );
}

#[test]
fn a_failed_probe_keeps_live_and_says_why() {
    let out = r#"{"error":{"code":"cloud.app.probe_failed","message":"GET / did not answer in 60 s"},"version":4}"#;
    assert_eq!(
        outcome(out, "", 1),
        Outcome::Failed {
            code: "cloud.app.probe_failed".into(),
            message: "GET / did not answer in 60 s".into(),
            version: Some(4)
        }
    );
}

#[test]
fn a_run_with_no_json_fails_with_its_output_tail() {
    let o = outcome("", "a\nb\nc\nd\ncmux: command not found\n", 127);
    assert_eq!(
        o,
        Outcome::Failed {
            code: "exit_127".into(),
            message: "b\nc\nd\ncmux: command not found".into(),
            version: None
        }
    );
    assert_eq!(
        outcome("", "", 2),
        Outcome::Failed {
            code: "exit_2".into(),
            message: "cmux app publish exited 2".into(),
            version: None
        }
    );
}

#[test]
fn the_section_lists_pinned_first_with_status_dots_then_publish() {
    let relayed = json!({"ok": true, "value": {"items": [
        {"slug": "zeta", "name": "Zeta", "live": 2, "url": "https://a-zeta--t.preview.cmux.dev", "pinned": false},
        {"slug": "draft", "name": "", "live": null, "url": "https://a-draft--t.preview.cmux.dev", "pinned": false},
        {"slug": "board", "name": "Board", "live": 7, "url": "https://a-board--t.preview.cmux.dev", "pinned": true},
        {"name": "no slug"}
    ]}});
    let s = section(&relayed);
    let order: Vec<_> =
        s.rows.iter().map(|r| (r.slug.as_str(), r.detail.as_str(), r.dot)).collect();
    assert_eq!(
        order,
        [("board", "v7", Dot::Live), ("draft", "not live", Dot::Off), ("zeta", "v2", Dot::Live)]
    );
    assert_eq!(s.rows[1].title, "draft");
    assert_eq!(s.rows[1].url, None, "a row with no live version opens nothing");
    assert!(s.publish_row);
    assert_eq!(s.error, None);
}

#[test]
fn a_refused_list_is_an_error_never_an_empty_section() {
    let s = section(
        &json!({"ok": false, "error": {"code": "signed_out", "message": "Sign in to cmux Cloud"}}),
    );
    assert_eq!(s.error.as_deref(), Some("Sign in to cmux Cloud"));
    assert!(s.rows.is_empty() && s.publish_row);
    // `cmux app ls --json`'s own shape reads the same.
    assert_eq!(section(&json!({"items": [{"slug": "a", "live": 1}]})).rows.len(), 1);
}

#[test]
fn the_ops_answer_json() {
    let t = respond(
        "apps_tier_target",
        &json!({"url": "https://p-3000--vm1.preview.cmux.dev/", "previews": previews()}),
    )
    .unwrap();
    assert_eq!(t["port"], 3000);
    let p =
        respond("apps_tier_popover", &json!({"target": t, "draft": {"audience": "team"}})).unwrap();
    assert_eq!(p["audience"], "team");
    assert_eq!(p["canPublish"], true);
    assert_eq!(respond("apps_tier_target", &json!({"url": "https://x.dev"})), Some(Value::Null));
    let o = respond("apps_tier_outcome", &json!({"stdout": "", "stderr": "", "exit": 1})).unwrap();
    assert_eq!(o["kind"], "failed");
    assert_eq!(respond("apps_tier_section", &json!({"items": []})).unwrap()["publishRow"], true);
    assert_eq!(respond("apps_tier_nope", &json!({})), None);
}
