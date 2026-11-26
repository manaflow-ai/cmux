//! Parity with the Mac app's link-routing tests (CmuxNextSettingsTests
//! SignInPageRoutingTests, ClassicLinkRoutingTests and
//! GitHubPullRequestPageSettingTests): every case they check, through the
//! `links.*` ops the app calls over cmux_settings_call.

use cmux_config::app_ops::{OpError, call};
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(name, &request).unwrap_or_else(|error| panic!("{name}: {error:?}"))
}

/// `links.parse` of `root`, with its diagnostics.
fn parse(root: Value) -> (Value, Vec<Value>) {
    let reply = op("links.parse", json!({"root": root}));
    (reply["routing"].clone(), reply["diagnostics"].as_array().cloned().unwrap_or_default())
}

/// The routing of `root`, which must parse clean.
fn routing(root: Value) -> Value {
    let (routing, diagnostics) = parse(root);
    assert!(diagnostics.is_empty(), "{diagnostics:?}");
    routing
}

fn target(routing: &Value, url: &str) -> String {
    op("links.target", json!({"routing": routing, "url": url}))["target"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

fn opens(routing: &Value, url: &str, explicit: bool) -> bool {
    op("links.opens_in_cmux", json!({"routing": routing, "url": url, "explicit": explicit}))["opensInCmux"]
        == json!(true)
}

fn sign_in(url: &str) -> bool {
    op("links.sign_in_page", json!({"url": url}))["signIn"] == json!(true)
}

fn paths(diagnostics: &[Value]) -> Vec<&str> {
    diagnostics.iter().filter_map(|d| d["path"].as_str()).collect()
}

// SignInPageRoutingTests

#[test]
fn sign_in_pages_are_recognized() {
    for url in [
        "https://example.com/device?code=ABCD-1234",
        "https://github.com/login/device",
        "https://github.com/login/oauth/authorize?client_id=x&state=y",
        "https://auth.openai.com/codex/device",
        "https://auth.openai.com/oauth/authorize?client_id=x",
        "https://console.opencode.ai/auth/device?code=WXYZ-0000",
        "https://claude.ai/oauth/authorize?code=true&client_id=x",
        "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
        "https://signin.aws.amazon.com/oauth?state=x",
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=x",
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        "https://microsoft.com/devicelogin",
        "https://www.google.com/device",
        "https://app.example.com/login?next=/",
        "https://example.com/sign-in",
        "https://x.awsapps.com/start/#/device?user_code=ABCD-EFGH",
    ] {
        assert!(sign_in(url), "{url}");
    }
}

#[test]
fn other_pages_are_not() {
    for url in [
        "https://example.com/",
        "https://github.com/manaflow-ai/cmux/pull/1",
        "https://github.com/manaflow-ai/cmux/blob/main/auth.rs",
        "https://news.ycombinator.com/item?id=1",
        "https://docs.example.com/guides/devices",
        "https://github.com/golang/oauth2",
        "https://pkg.go.dev/golang.org/x/oauth2",
        "https://github.com/o/r/tree/main/src/auth",
        "https://supabase.com/docs/guides/auth",
        "https://developer.android.com/studio/run/device",
        "https://login.gov/help/",
        "file:///tmp/login",
        "mailto:login@example.com",
    ] {
        assert!(!sign_in(url), "{url}");
    }
}

#[test]
fn on_by_default() {
    let routing = routing(json!({}));
    assert_eq!(routing["signInPagesInCmux"], json!(true));
    assert_eq!(target(&routing, "https://example.com/device?code=ABCD-1234"), "cmuxBrowser");
}

#[test]
fn sign_in_pages_open_in_cmux_when_links_go_to_the_default_browser() {
    let routing = routing(json!({"browser": {"openLinksInCmuxBrowser": false}}));
    assert_eq!(target(&routing, "https://example.com/device?code=ABCD-1234"), "cmuxBrowser");
    assert_eq!(target(&routing, "https://github.com/login/device"), "cmuxBrowser");
    assert_eq!(target(&routing, "https://example.com/article"), "system");
}

#[test]
fn host_allowlist_does_not_send_sign_in_pages_out() {
    let routing = routing(json!({"browser": {"hostsToOpenInEmbeddedBrowser": ["localhost"]}}));
    assert_eq!(target(&routing, "https://github.com/login/device"), "cmuxBrowser");
    assert_eq!(target(&routing, "https://github.com/manaflow-ai"), "system");
}

#[test]
fn always_external_still_wins() {
    let routing = routing(json!({"browser": {"urlsToAlwaysOpenExternally": ["github.com/login"]}}));
    assert_eq!(target(&routing, "https://github.com/login/device"), "system");
}

#[test]
fn off_leaves_sign_in_pages_to_the_link_settings() {
    let routing = routing(
        json!({"browser": {"openSignInPagesInCmux": false, "openLinksInCmuxBrowser": false}}),
    );
    assert_eq!(routing["signInPagesInCmux"], json!(false));
    assert_eq!(target(&routing, "https://github.com/login/device"), "system");
    let links_on = self::routing(json!({"browser": {"openSignInPagesInCmux": false}}));
    assert_eq!(target(&links_on, "https://github.com/login/device"), "cmuxBrowser");
}

#[test]
fn browser_off_sends_everything_out() {
    let routing = routing(json!({"browser": {"enabled": false}}));
    assert_eq!(target(&routing, "https://github.com/login/device"), "system");
}

#[test]
fn a_non_bool_value_is_diagnosed() {
    let (routing, diagnostics) = parse(json!({"browser": {"openSignInPagesInCmux": "yes"}}));
    assert_eq!(routing["signInPagesInCmux"], json!(true));
    assert_eq!(paths(&diagnostics), ["browser.openSignInPagesInCmux"]);
    assert_eq!(diagnostics[0]["kind"], json!("invalidValue"));
    assert_eq!(diagnostics[0]["message"], json!("expected true or false"));
}

// ClassicLinkRoutingTests

#[test]
fn classic_cmux_json_routes_terminal_links() {
    let routing = routing(json!({"browser": {
        "hostsToOpenInEmbeddedBrowser": ["*.example.com", "localhost"],
        "urlsToAlwaysOpenExternally": ["billing", "re:^https://docs\\.example\\.com/private/"]
    }}));
    assert!(opens(&routing, "https://app.example.com/home", false));
    assert!(opens(&routing, "https://example.com/", false));
    assert!(opens(&routing, "http://localhost:3000/", false));
    assert!(!opens(&routing, "https://github.com/manaflow-ai", false));
    assert!(!opens(&routing, "https://app.example.com/billing/usage", false));
    assert!(!opens(&routing, "https://docs.example.com/private/keys", false));
    assert!(opens(&routing, "https://docs.example.com/public/", false));
}

/// Classic's line text and comments, as `importClassicPreferences` writes them.
#[test]
fn classic_line_text_and_comments() {
    let routing = routing(json!({"browser": {
        "hostsToOpenInEmbeddedBrowser": ["*.corp.example\n\n  intranet.local  "],
        "urlsToAlwaysOpenExternally": ["*zoom.us*", "# a comment"]
    }}));
    assert_eq!(routing["embeddedHosts"], json!(["*.corp.example", "intranet.local"]));
    assert_eq!(routing["externalRules"], json!(["*zoom.us*"]));
    assert!(opens(&routing, "https://wiki.corp.example/page", false));
    assert!(opens(&routing, "http://intranet.local/", false));
    assert!(!opens(&routing, "https://example.org/", false));
    assert!(!opens(&routing, "https://stable.example/", false));
    assert!(!opens(&routing, "https://wiki.corp.example/?join=https://zoom.us/j/1", false));
    let cleared = self::routing(json!({"browser": {"urlsToAlwaysOpenExternally": ["*zoom.us*"]}}));
    assert!(opens(&cleared, "https://example.org/", false));
}

#[test]
fn explicit_skips_the_toggle_not_the_rules() {
    let routing = routing(json!({"browser": {
        "openTerminalLinksInCmuxBrowser": false,
        "urlsToAlwaysOpenExternally": ["re:^https://bank\\.example/"]
    }}));
    assert_eq!(routing["opensInCmuxBrowser"], json!(false));
    assert!(!opens(&routing, "https://example.com/", false));
    assert!(opens(&routing, "https://example.com/", true));
    assert!(!opens(&routing, "https://bank.example/login", true));
    // A link with no usable host goes out, as in classic.
    assert!(
        !op("links.opens_in_cmux", json!({"url": "https://", "explicit": true}))["opensInCmux"]
            .as_bool()
            .unwrap_or(true)
    );
}

#[test]
fn text_values_are_refused() {
    let (routing, diagnostics) =
        parse(json!({"browser": {"hostsToOpenInEmbeddedBrowser": "a.example\nb.example"}}));
    assert_eq!(routing["embeddedHosts"], json!([]));
    assert_eq!(paths(&diagnostics), ["browser.hostsToOpenInEmbeddedBrowser"]);
    assert_eq!(diagnostics[0]["message"], json!("expected an array of strings"));
}

// GitHubPullRequestPageSettingTests

#[test]
fn pull_request_page_defaults_off() {
    let routing = routing(json!({}));
    assert_eq!(routing["pullRequestsInGitHubPage"], json!(false));
    let on = self::routing(json!({"browser": {"openPullRequestsInGitHubPage": true}}));
    assert_eq!(on["pullRequestsInGitHubPage"], json!(true));
    assert_eq!(on["opensInCmuxBrowser"], json!(true));
    assert_eq!(on["signInPagesInCmux"], json!(true));
    assert_eq!(on["browserEnabled"], json!(true));
    let (wrong, diagnostics) =
        parse(json!({"browser": {"openPullRequestsInGitHubPage": "github"}}));
    assert_eq!(wrong["pullRequestsInGitHubPage"], json!(false));
    assert_eq!(paths(&diagnostics), ["browser.openPullRequestsInGitHubPage"]);
}

// LinkRouting's documented behavior

#[test]
fn defaults_match_the_schema() {
    assert_eq!(
        routing(json!({"browser": 3})),
        json!({
            "opensInCmuxBrowser": true, "embeddedHosts": [], "externalRules": [],
            "browserEnabled": true, "signInPagesInCmux": true, "pullRequestsInGitHubPage": false,
        })
    );
}

#[test]
fn the_new_open_key_wins_over_classics() {
    let routing = routing(
        json!({"browser": {"openLinksInCmuxBrowser": true, "openTerminalLinksInCmuxBrowser": false}}),
    );
    assert_eq!(routing["opensInCmuxBrowser"], json!(true));
    let (_, diagnostics) = parse(json!({"browser": {"openTerminalLinksInCmuxBrowser": 1}}));
    assert_eq!(paths(&diagnostics), ["browser.openTerminalLinksInCmuxBrowser"]);
}

#[test]
fn only_web_links_open_in_cmux_and_other_target_flips() {
    let routing = routing(json!({}));
    assert_eq!(target(&routing, "mailto:a@example.com"), "system");
    assert_eq!(target(&routing, "HTTPS://Example.com/"), "cmuxBrowser");
    let flip = |url: &str| {
        op("links.target", json!({"routing": routing, "url": url, "otherTarget": true}))["target"]
            .clone()
    };
    assert_eq!(flip("https://example.com/"), json!("system"));
    let out = self::routing(json!({"browser": {"openLinksInCmuxBrowser": false}}));
    let flip_out = op(
        "links.target",
        json!({"routing": out, "url": "https://example.com/", "otherTarget": true}),
    );
    assert_eq!(flip_out["target"], json!("cmuxBrowser"));
    let flip_no_host =
        op("links.target", json!({"routing": out, "url": "https://", "otherTarget": true}));
    assert_eq!(flip_no_host["target"], json!("system"));
}

#[test]
fn host_patterns_normalize_like_classic() {
    let routing = routing(json!({"browser": {"hostsToOpenInEmbeddedBrowser": [
        " *.Example.COM ", "https://docs.test:8443/path", "[::1]", "..dotted.test.."
    ]}}));
    assert!(opens(&routing, "https://deep.app.example.com/", false));
    assert!(!opens(&routing, "https://notexample.com/", false));
    assert!(opens(&routing, "https://docs.test/", false));
    assert!(opens(&routing, "http://[::1]:8080/", false));
    assert!(opens(&routing, "https://user@dotted.test./", false));
    let idn =
        self::routing(json!({"browser": {"hostsToOpenInEmbeddedBrowser": ["bücher.example"]}}));
    assert!(opens(&idn, "https://xn--bcher-kva.example/", false));
}

// The external-rule matcher (BrowserExternalURLPatternMatcher)

fn matches(patterns: &[&str], url: &str) -> bool {
    op("links.external_match", json!({"patterns": patterns, "target": url}))["matches"]
        == json!(true)
}

#[test]
fn rules_match_as_classic_did() {
    // Plain text: a case-insensitive substring.
    assert!(matches(&["BILLING"], "https://x.example/billing"));
    // Globs: implicit stars at both ends, `?` one character, `\*` a literal star.
    assert!(matches(&["zoom.us/j/*"], "https://zoom.us/j/123"));
    assert!(matches(&["https://?.example/"], "https://a.example/"));
    assert!(!matches(&["https://?.example/"], "https://ab.example/"));
    assert!(matches(&["a\\*b"], "https://x/a*b"));
    assert!(!matches(&["a\\*b"], "https://x/axxb"));
    // Legacy `.*` regex rules run as the linear glob.
    assert!(matches(&["example\\.com/.*/admin"], "https://example.com/x/admin"));
    assert!(!matches(&["example\\.com/.+/admin"], "https://example.com//admin"));
    assert!(matches(&["re:^https://.*\\.bank/"], "https://www.bank/"));
    // Bounded regexes.
    assert!(matches(&["re:^https?://(a|b)\\.example/"], "http://b.example/x"));
    assert!(!matches(&["re:^https?://(a|b)\\.example/"], "http://c.example/x"));
    assert!(matches(&["re:\\d{3}-\\d{4}"], "https://x/555-1234"));
    // A regex-shaped rule that is not a safe regex still matches as text.
    assert!(matches(&["(a+)+b"], "https://x/(a+)+b"));
    assert!(!matches(&["(a+)+b"], "https://x/aaab"));
    // Comments, blank lines and duplicates are dropped; an empty list matches nothing.
    assert!(!matches(&["# billing", "", "  "], "https://x/billing"));
    assert!(!matches(&[], "https://x/"));
}

#[test]
fn unsafe_regexes_never_match() {
    for rule in [
        "re:(a+)+$",     // a quantified group holding a quantifier
        "re:(a|b)*c|d",  // two alternations
        "re:a+b+",       // two variable quantifiers
        "re:(\\w)\\1",   // a backreference
        "re:(?=x)",      // a lookaround
        "re:a{1,99999}", // a bound past 16,384
        "re:[abc",       // an open class
        "re:*a",         // a quantifier with nothing before it
    ] {
        assert!(!matches(&[rule], "https://x/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"), "{rule}");
    }
    // `.*` repeated in a re: rule is the linear glob, not a backtracking regex.
    assert!(!matches(&["re:.*.*.*.*.*.*.*.*!"], &format!("https://x/{}", "a".repeat(10_000))));
}

#[test]
fn limits_bound_every_match() {
    let long = format!("https://x/{}", "a".repeat(16_384));
    assert!(!matches(&["a"], &long));
    let big = "a".repeat(4097);
    assert!(!matches(&[big.as_str()], &format!("https://x/{big}")));
    let many: Vec<String> = (0..300).map(|n| format!("r{n}x")).collect();
    let many: Vec<&str> = many.iter().map(String::as_str).collect();
    assert!(matches(&many, "https://x/r255x"));
    assert!(!matches(&many, "https://x/r256x"));
}

#[test]
fn bad_requests_are_invalid() {
    assert!(matches!(call("links.target", &json!({})), Err(OpError::Invalid(_))));
    assert!(matches!(
        call("links.target", &json!({"url": "https://x/", "routing": 1})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        call("links.external_match", &json!({"patterns": [1], "target": ""})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(call("links.parse", &json!({})), Err(OpError::Invalid(_))));
    assert_eq!(call("links.nope", &json!({})), Err(OpError::Unknown));
}
