//! Ported from the Swift suites ClassicLinkRoutingTests, SignInPageRoutingTests,
//! GitHubPullRequestPageSettingTests, TerminalLinkOpenerTests,
//! LinkPlacementSettingTests and BrowserCmdClickLinkPlacementSettingTests.
//! `SignInPage` stays in Swift, so a sign-in page is a link with `sign_in_page`.

use serde_json::{Value, json};

use super::*;

fn routing(root: Value) -> Routing {
    let (setting, problems) = Routing::read(&root);
    assert!(problems.is_empty(), "{problems:?}");
    setting
}

/// `url` split as Foundation splits it: scheme, then the host up to a port or path.
fn link(url: &str) -> Link<'_> {
    sign_in(url, false)
}

fn sign_in(url: &str, sign_in_page: bool) -> Link<'_> {
    let (scheme, rest) = url.split_once("://").unwrap_or(("", url));
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit_once(':').map_or(authority, |(host, _)| host);
    Link { url, scheme, host, sign_in_page }
}

fn paths(problems: &[Problem]) -> Vec<&str> {
    problems.iter().map(|problem| problem.path.as_str()).collect()
}

#[test]
fn classic_cmux_json_routes_terminal_links() {
    let setting = routing(json!({ "browser": {
        "hostsToOpenInEmbeddedBrowser": ["*.example.com", "localhost"],
        "urlsToAlwaysOpenExternally": ["billing", "re:^https://docs\\.example\\.com/private/"],
    } }));
    let opens = |url: &str| setting.opens_in_cmux(link(url), false);
    assert!(opens("https://app.example.com/home"));
    assert!(opens("https://example.com/"));
    assert!(opens("http://localhost:3000/"));
    assert!(!opens("https://github.com/manaflow-ai"));
    assert!(!opens("https://app.example.com/billing/usage"));
    assert!(!opens("https://docs.example.com/private/keys"));
    assert!(opens("https://docs.example.com/public/"));
}

#[test]
fn classic_line_text_and_comments_read_as_lines() {
    let lines_of = |value| lines(&value).unwrap();
    assert_eq!(
        lines_of(json!("*.corp.example\n\n  intranet.local  ")),
        ["*.corp.example", "intranet.local"]
    );
    assert_eq!(lines_of(json!(["*zoom.us*", "# a comment"])), ["*zoom.us*"]);
    assert_eq!(lines(&json!(["a", 1])), None);
    assert_eq!(lines(&json!(true)), None);

    let setting = Routing {
        embedded_hosts: vec!["*.corp.example".into(), "intranet.local".into()],
        external_rules: vec!["*zoom.us*".into()],
        ..Routing::default()
    };
    let opens = |url: &str| setting.opens_in_cmux(link(url), false);
    assert!(opens("https://wiki.corp.example/page"));
    assert!(opens("http://intranet.local/"));
    assert!(!opens("https://example.org/"));
    assert!(!opens("https://wiki.corp.example/?join=https://zoom.us/j/1"));
}

#[test]
fn explicit_profile_clicks_skip_the_toggle_not_the_rules() {
    let setting = Routing {
        opens_in_cmux_browser: false,
        external_rules: vec!["re:^https://bank\\.example/".into()],
        ..Routing::default()
    };
    assert!(!setting.opens_in_cmux(link("https://example.com/"), false));
    assert!(setting.opens_in_cmux(link("https://example.com/"), true));
    assert!(!setting.opens_in_cmux(link("https://bank.example/login"), true));
    // A link with no usable host goes out, as in classic.
    assert!(!Routing::default().opens_in_cmux(link("https://"), true));
}

#[test]
fn text_values_for_the_lists_are_refused() {
    let (setting, problems) = Routing::read(
        &json!({ "browser": { "hostsToOpenInEmbeddedBrowser": "a.example\nb.example" } }),
    );
    assert!(setting.embedded_hosts.is_empty());
    assert_eq!(paths(&problems), ["browser.hostsToOpenInEmbeddedBrowser"]);
    assert_eq!(problems[0].message, "expected an array of strings");
}

#[test]
fn the_new_toggle_wins_over_classics() {
    assert!(
        !routing(json!({ "browser": { "openTerminalLinksInCmuxBrowser": false } }))
            .opens_in_cmux_browser
    );
    assert!(
        routing(json!({ "browser": {
        "openLinksInCmuxBrowser": true, "openTerminalLinksInCmuxBrowser": false } }))
        .opens_in_cmux_browser
    );
    let (_, problems) = Routing::read(&json!({ "browser": {
        "openLinksInCmuxBrowser": "on", "openTerminalLinksInCmuxBrowser": "off" } }));
    assert_eq!(paths(&problems), ["browser.openLinksInCmuxBrowser"]);
    // Only a `browser` object is read.
    assert_eq!(Routing::read(&json!({ "browser": true })), (Routing::default(), Vec::new()));
}

#[test]
fn sign_in_pages_open_in_cmux_when_links_go_out() {
    let defaults = routing(json!({}));
    assert!(defaults.sign_in_pages_in_cmux);
    let device = sign_in("https://example.com/device?code=ABCD-1234", true);
    assert_eq!(defaults.target(device, false, false), RouteTarget::CmuxBrowser);

    let off = routing(json!({ "browser": { "openLinksInCmuxBrowser": false } }));
    assert_eq!(off.target(device, false, false), RouteTarget::CmuxBrowser);
    assert_eq!(
        off.target(sign_in("https://github.com/login/device", true), false, false),
        RouteTarget::CmuxBrowser
    );
    assert_eq!(off.target(link("https://example.com/article"), false, false), RouteTarget::System);
}

#[test]
fn the_host_allowlist_keeps_sign_in_pages() {
    let setting = routing(json!({ "browser": { "hostsToOpenInEmbeddedBrowser": ["localhost"] } }));
    assert_eq!(
        setting.target(sign_in("https://github.com/login/device", true), false, false),
        RouteTarget::CmuxBrowser
    );
    assert_eq!(
        setting.target(link("https://github.com/manaflow-ai"), false, false),
        RouteTarget::System
    );
}

#[test]
fn always_external_still_wins_over_sign_in_pages() {
    let setting =
        routing(json!({ "browser": { "urlsToAlwaysOpenExternally": ["github.com/login"] } }));
    assert_eq!(
        setting.target(sign_in("https://github.com/login/device", true), false, false),
        RouteTarget::System
    );
}

#[test]
fn sign_in_pages_off_follow_the_link_settings() {
    let device = sign_in("https://github.com/login/device", true);
    let setting = routing(json!({ "browser": {
        "openSignInPagesInCmux": false, "openLinksInCmuxBrowser": false } }));
    assert!(!setting.sign_in_pages_in_cmux);
    assert_eq!(setting.target(device, false, false), RouteTarget::System);
    let links_on = routing(json!({ "browser": { "openSignInPagesInCmux": false } }));
    assert_eq!(links_on.target(device, false, false), RouteTarget::CmuxBrowser);
}

#[test]
fn browser_off_sends_everything_out() {
    let setting = routing(json!({ "browser": { "enabled": false } }));
    assert_eq!(
        setting.target(sign_in("https://github.com/login/device", true), false, false),
        RouteTarget::System
    );
    assert!(!setting.opens_in_cmux(link("https://example.com/"), true));
}

#[test]
fn a_non_bool_value_is_diagnosed() {
    let (setting, problems) =
        Routing::read(&json!({ "browser": { "openSignInPagesInCmux": "yes" } }));
    assert!(setting.sign_in_pages_in_cmux);
    assert_eq!(paths(&problems), ["browser.openSignInPagesInCmux"]);
    assert_eq!(problems[0].message, "expected true or false");
}

#[test]
fn only_web_links_open_in_cmux_and_other_target_flips() {
    let setting = routing(json!({ "browser": { "urlsToAlwaysOpenExternally": ["billing"] } }));
    assert_eq!(setting.target(link("mailto:a@example.com"), false, false), RouteTarget::System);
    assert_eq!(
        setting.target(link("HTTPS://example.com/"), false, false),
        RouteTarget::CmuxBrowser
    );
    assert_eq!(setting.target(link("https://example.com/"), true, false), RouteTarget::System);
    assert_eq!(
        setting.target(link("https://example.com/billing"), true, false),
        RouteTarget::CmuxBrowser
    );
    assert_eq!(setting.target(link("https://"), true, false), RouteTarget::System);
}

#[test]
fn pull_request_pages_are_off_by_default() {
    let (setting, problems) = Routing::read(&json!({}));
    assert!(!setting.pull_requests_in_github_page && problems.is_empty());
    let on = routing(json!({ "browser": { "openPullRequestsInGitHubPage": true } }));
    assert!(on.pull_requests_in_github_page);
    assert!(on.opens_in_cmux_browser && on.sign_in_pages_in_cmux && on.browser_enabled);
    let (bad, problems) =
        Routing::read(&json!({ "browser": { "openPullRequestsInGitHubPage": "github" } }));
    assert!(!bad.pull_requests_in_github_page);
    assert_eq!(paths(&problems), ["browser.openPullRequestsInGitHubPage"]);
}

#[test]
fn routing_round_trips_through_json() {
    let setting = Routing {
        opens_in_cmux_browser: false,
        embedded_hosts: vec!["a".into()],
        external_rules: vec!["b".into()],
        browser_enabled: false,
        sign_in_pages_in_cmux: false,
        pull_requests_in_github_page: true,
    };
    assert_eq!(Routing::from_json(&setting.json()), Some(setting));
    assert_eq!(Routing::from_json(&json!({})), Some(Routing::default()));
    assert_eq!(Routing::from_json(&json!({ "embeddedHosts": [1] })), None);
}

#[test]
fn hosts_normalize_as_classic_did() {
    for (raw, host) in [
        ("Example.COM", Some("example.com")),
        ("  example.com.  ", Some("example.com")),
        ("https://Example.com:8443/path", Some("example.com")),
        ("//example.com/x", Some("example.com")),
        ("localhost:3000", Some("localhost")),
        ("example.com/path?q#f", Some("example.com")),
        ("[::1]:8080", Some("::1")),
        ("[fe80::1", Some("fe80::1")),
        ("fe80::1", Some("fe80::1")),
        ("bücher.example", Some("xn--bcher-kva.example")),
        ("...", None),
        ("   ", None),
        ("", None),
    ] {
        assert_eq!(normalized_host(raw).as_deref(), host, "{raw}");
    }
}

fn opener(root: Value) -> (Opener, Vec<Problem>) {
    Opener::read(&root)
}

#[test]
fn unset_opens_in_cmux() {
    let (setting, problems) = opener(json!({}));
    assert!(problems.is_empty());
    assert_eq!(
        setting.decide("https://signin.aws.amazon.com/x", &["aws"], false),
        (Target::Cmux, None)
    );
}

fn app(name: &str, profile: Option<&str>) -> Target {
    Target::App { app: name.into(), profile: profile.map(Into::into) }
}

#[test]
fn targets_parse() {
    for (text, target) in [
        ("cmux", Target::Cmux),
        ("system", Target::System),
        ("Default", Target::System),
        ("Chrome", app("Google Chrome", None)),
        ("chrome@Profile 1", app("Google Chrome", Some("Profile 1"))),
        ("safari", app("Safari", None)),
        ("arc", app("Arc", None)),
        ("firefox@work", app("Firefox", Some("work"))),
        ("edge", app("Microsoft Edge", None)),
        ("brave@", app("Brave Browser", None)),
        ("app:Zen", app("Zen", None)),
        ("APP: Zen ", app("Zen", None)),
        (
            "app:/Applications/Vivaldi.app@Default",
            app("/Applications/Vivaldi.app", Some("Default")),
        ),
        (
            "command:~/bin/pick-browser --verbose",
            Target::Command("~/bin/pick-browser --verbose".into()),
        ),
        ("Command:a@b", Target::Command("a@b".into())),
    ] {
        assert_eq!(Target::parse(text), Some(target), "{text}");
    }
}

#[test]
fn unknown_targets_are_refused() {
    for text in ["", "netscape", "app:", "command:", "app:@x", "  "] {
        assert_eq!(Target::parse(text), None, "{text:?}");
    }
}

#[test]
fn targets_round_trip_through_json() {
    for target in [
        Target::Cmux,
        Target::System,
        app("Arc", None),
        app("Firefox", Some("w")),
        Target::Command("pick".into()),
    ] {
        assert_eq!(Target::from_json(&target.json()), Some(target));
    }
}

#[test]
fn first_matching_rule_wins() {
    let (setting, problems) =
        opener(json!({ "terminal": { "linkOpener": { "default": "system", "rules": [
        "caller:aws -> chrome@Work",
        "caller:gh,git github.com/login -> safari",
        "re:^https://[^/]*\\.corp\\.example\\.com/ -> app:Arc",
        "caller:aws -> firefox",
        "* -> command:~/bin/pick",
    ] } } }));
    assert!(problems.is_empty());
    assert_eq!(setting.rules.len(), 5);
    assert_eq!(
        setting.decide("https://signin.aws.amazon.com/oauth", &["python3.12", "aws", "zsh"], false),
        (app("Google Chrome", Some("Work")), Some(0))
    );
    assert_eq!(
        setting.decide("https://github.com/login/device", &["GH"], false),
        (app("Safari", None), Some(1))
    );
    assert_eq!(setting.decide("https://github.com/cli/cli", &["gh"], false).1, Some(4));
    assert_eq!(
        setting.decide("https://wiki.corp.example.com/a", &["node"], false),
        (app("Arc", None), Some(2))
    );
}

#[test]
fn no_rule_matching_uses_the_default() {
    let (setting, _) = opener(json!({ "terminal": { "linkOpener": {
        "default": "safari", "rules": ["caller:gcloud -> chrome"] } } }));
    assert_eq!(
        setting.decide("https://accounts.google.com/o", &["npm"], false),
        (app("Safari", None), None)
    );
    assert_eq!(setting.decide("https://accounts.google.com/o", &["gcloud"], false).1, Some(0));
}

#[test]
fn caller_globs_match_whole_names() {
    let rule = Rule::parse("caller:python3* -> system").unwrap();
    let url = "https://a.example/";
    assert!(rule.matches(url, &["Python3.12"]));
    assert!(!rule.matches(url, &["ipython"]));
    assert!(!rule.matches::<&str>(url, &[]));
    let rule = Rule::parse("  caller:g?,,aws   github.com  /login -> cmux  ").unwrap();
    assert_eq!(rule.text, "caller:g?,,aws   github.com  /login -> cmux");
    assert_eq!(rule.callers, ["g?", "aws"]);
    assert_eq!(rule.url_pattern.as_deref(), Some("github.com /login"));
    assert!(Rule::parse("* -> cmux").unwrap().url_pattern.is_none());
}

#[test]
fn bad_opener_values_are_reported_and_skipped() {
    let (setting, problems) = opener(json!({ "terminal": { "linkOpener": {
        "default": "netscape", "rules": ["no arrow", "caller:aws -> chrome", "x -> nowhere"] } } }));
    assert_eq!(setting.default_target, Target::Cmux);
    let texts: Vec<&str> = setting.rules.iter().map(|rule| rule.text.as_str()).collect();
    assert_eq!(texts, ["caller:aws -> chrome"]);
    assert_eq!(
        paths(&problems),
        ["terminal.linkOpener.default", "terminal.linkOpener.rules", "terminal.linkOpener.rules"]
    );
    assert_eq!(problems[1].message, "expected <match> -> <target>, such as caller:aws -> chrome");
    let (_, problems) =
        opener(json!({ "terminal": { "linkOpener": { "rules": "caller:aws -> chrome" } } }));
    assert_eq!(problems[0].message, "expected an array of strings");
}

#[test]
fn the_opener_reads_command_defaults() {
    let (setting, _) = opener(json!({ "terminal": { "linkOpener": {
        "default": "command:pick", "rules": ["caller:aws -> system"] } } }));
    assert_eq!(setting.default_target, Target::Command("pick".into()));
    assert_eq!(setting.rules.len(), 1);
    assert_eq!(Opener::from_json(&setting.json()), Some(setting));
}

#[test]
fn program_sign_in_pages_open_in_cmux_over_the_default_target() {
    let setting = Opener {
        default_target: app("Helium", None),
        rules: vec![Rule::parse("caller:aws -> chrome@Work").unwrap()],
    };
    let on = routing(json!({}));
    let device = "https://example.com/device?code=ABCD-1234";
    let keeps = on.keeps_sign_in_page_in_cmux(true);
    assert_eq!(setting.decide(device, &["gh", "zsh"], keeps), (Target::Cmux, None));
    assert_eq!(
        setting.decide(device, &["aws"], keeps),
        (app("Google Chrome", Some("Work")), Some(0))
    );
    assert_eq!(
        setting.decide(
            "https://example.com/article",
            &["gh"],
            on.keeps_sign_in_page_in_cmux(false)
        ),
        (app("Helium", None), None)
    );
    let off = routing(json!({ "browser": { "openSignInPagesInCmux": false } }));
    assert_eq!(
        setting.decide(device, &["gh"], off.keeps_sign_in_page_in_cmux(true)),
        (app("Helium", None), None)
    );
}

#[test]
fn profiles_launch_only_browsers_that_take_them() {
    let url = "https://a.example/";
    assert_eq!(
        app("Google Chrome", Some("Profile 1")).launch(url),
        Some(json!({
        "app": "Google Chrome", "arguments": ["--profile-directory=Profile 1", url], "newInstance": true }))
    );
    assert_eq!(
        app("Firefox", Some("work")).launch(url),
        Some(json!({
        "app": "Firefox", "arguments": ["-P", "work", "-new-tab", url], "newInstance": true }))
    );
    assert_eq!(
        app("Safari", Some("x")).launch(url),
        Some(json!({ "app": "Safari", "arguments": [], "newInstance": false }))
    );
    assert_eq!(
        app("Arc", None).launch(url),
        Some(json!({ "app": "Arc", "arguments": [], "newInstance": false }))
    );
    assert_eq!(Target::Cmux.launch(url), None);
}

#[test]
fn link_placement_reads_each_choice() {
    assert_eq!(read_placement(&json!({})), ("split-right", None));
    for choice in PLACEMENTS {
        assert_eq!(
            read_placement(&json!({ "layout": { "linkPlacement": choice } })),
            (choice, None)
        );
    }
    let (placement, problem) = read_placement(&json!({ "layout": { "linkPlacement": "left" } }));
    assert_eq!(placement, "split-right");
    let problem = problem.unwrap();
    assert_eq!(problem.path, "layout.linkPlacement");
    assert_eq!(problem.message, r#"expected one of "split-right", "new-column", "same-pane""#);
}

#[test]
fn link_clicks_default_to_chrome_with_cmd_click_on_link_placement() {
    let (setting, problems) = read_clicks(&json!({}));
    assert!(problems.is_empty());
    assert_eq!(
        Value::Object(setting),
        json!({
        "cmdClick": "linkPlacement", "cmdShiftClick": "foregroundTab", "shiftClick": "newWindow",
        "optionClick": "download", "middleClick": "backgroundTab" })
    );

    let (setting, problems) = read_clicks(&json!({ "browser": { "links": {
        "shiftClick": "linkPlacement", "cmdClick": "backgroundTab" } } }));
    assert!(problems.is_empty());
    assert_eq!(setting["shiftClick"], "linkPlacement");
    assert_eq!(setting["cmdClick"], "backgroundTab");

    let (setting, problems) =
        read_clicks(&json!({ "browser": { "links": { "middleClick": "explode" } } }));
    assert_eq!(setting["middleClick"], "backgroundTab");
    assert_eq!(paths(&problems), ["browser.links.middleClick"]);
    assert_eq!(
        problems[0].message,
        r#"expected one of "currentTab", "backgroundTab", "foregroundTab", "linkPlacement", "newWindow", "download""#
    );

    let (_, problems) = read_clicks(&json!({ "browser": { "links": [] } }));
    assert_eq!(problems, [Problem::new("browser.links", "expected an object")]);
}

#[test]
fn ssh_hosts_are_the_strings_written() {
    assert!(ssh_hosts(&json!({})).is_empty());
    assert!(ssh_hosts(&json!({ "ssh": { "linkAllowedHosts": "a" } })).is_empty());
    let root = json!({ "ssh": { "linkAllowedHosts": ["build.example.com", 1, "fe80::1"] } });
    assert_eq!(ssh_hosts(&root), ["build.example.com", "fe80::1"]);
    assert_eq!(ssh_hosts_allowing(&root, "fe80::1"), None);
    assert_eq!(ssh_hosts_allowing(&root, ""), None);
    assert_eq!(
        ssh_hosts_allowing(&root, "new"),
        Some(vec!["build.example.com".into(), "fe80::1".into(), "new".into()])
    );
}
