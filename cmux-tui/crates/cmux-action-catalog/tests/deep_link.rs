//! cmux-next object links: the app's DeepLink cases (CmuxNextActionsTests DeepLink*Tests,
//! AgentLinkSchemaTests, LinkExportTests), held against this module, plus the C ABI.

use cmux_action_catalog::deep_link::*;
use cmux_action_catalog::ffi::{ERR_INVALID, OK, cmux_deep_link_call, cmux_deep_link_free};
use serde_json::{Value, json};
use std::path::PathBuf;

// affected-reads: schemas/deeplinks/agent-link.json plans/cmux-next/links.json
fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn agent(harness: &str, session: &str) -> Target {
    Target::Agent { harness: harness.into(), session: session.into() }
}

fn tab(id: &str) -> DeepLink {
    DeepLink::new(Target::Tab(id.into()))
}

const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const MACHINE: &str = "machine_0123456789abcdef0123456789abcdef";

// MARK: DeepLinkAgentTests

#[test]
fn an_agent_link_parses_to_its_harness_and_session() {
    let link = parse("cmux://agent/claude/0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d", "cmux");
    assert_eq!(link, Some(DeepLink::new(agent("claude", "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d"))));
}

#[test]
fn hints_are_kept_and_formatted_back() {
    let text = "cmux://agent/codex/019a-thread_7?host=build-mac&name=Lanternfish";
    let link = parse(text, "cmux").unwrap();
    assert_eq!(link.target, agent("codex", "019a-thread_7"));
    assert_eq!(link.host_hint.as_deref(), Some("build-mac"));
    assert_eq!(link.name_hint.as_deref(), Some("Lanternfish"));
    assert_eq!(link.url("cmux").as_deref(), Some(text));
}

#[test]
fn formatted_agent_links_parse_back_to_the_same_link() {
    let links = [
        DeepLink::new(agent("claude", "s1")),
        DeepLink::new(agent("opencode", "ses_01.a-b")),
        DeepLink { host_hint: Some("build-mac".into()), ..DeepLink::new(agent("gemini", "x")) },
        DeepLink { name_hint: Some("Lanternfish".into()), ..DeepLink::new(agent("pi", "x")) },
        DeepLink {
            machine: Some(MACHINE.into()),
            host_hint: Some("h".into()),
            name_hint: Some("n".into()),
            ..DeepLink::new(agent("amp", "x"))
        },
    ];
    for link in links {
        let url = link.url("cmux-dev").unwrap();
        assert_eq!(parse(&url, "cmux-dev"), Some(link));
    }
}

#[test]
fn malformed_agent_links_are_refused() {
    for text in [
        "cmux://agent/claude",
        "cmux://agent/claude/s1/extra",
        "cmux://agent",
        "cmux://agent/Claude/s1",
        "cmux://agent/clau_de/s1",
        "cmux://agent/claude/s%201",
        "cmux://agent/claude/s1#turn-t1",
        "cmux://agent/claude/s1#x",
        "other-app://agent/claude/s1",
        "cmux://user@agent/claude/s1",
        "cmux://agent:8080/claude/s1",
        "cmux://agent/claude/..",
        "cmux://agent/claude/.",
    ] {
        assert_eq!(parse(text, "cmux"), None, "{text}");
    }
}

#[test]
fn a_too_long_session_or_harness_is_refused() {
    let a = |n| "a".repeat(n);
    assert!(parse(&format!("cmux://agent/claude/{}", a(257)), "cmux").is_none());
    assert!(parse(&format!("cmux://agent/claude/{}", a(256)), "cmux").is_some());
    assert!(parse("cmux://agent/claude/session:with:colon", "cmux").is_some());
    assert!(parse(&format!("cmux://agent/{}/s1", a(65)), "cmux").is_none());
    assert!(DeepLink::new(agent("claude", &a(256))).url("cmux").is_some());
    assert!(DeepLink::new(agent("claude", &a(257))).url("cmux").is_none());
    assert!(DeepLink::new(agent("Claude", "s1")).url("cmux").is_none());
    assert!(DeepLink::new(agent("claude", "...")).url("cmux").is_none());
}

#[test]
fn malformed_hints_are_dropped_not_the_link() {
    for text in [
        "cmux://agent/claude/s1?host=build%20mac&name=Lanternfish".to_owned(),
        "cmux://agent/claude/s1?host=&name=".to_owned(),
        format!("cmux://agent/claude/s1?host={}", "h".repeat(65)),
        "cmux://agent/claude/s1?host=a/b".to_owned(),
        "cmux://agent/claude/s1?name=%3Cscript%3E".to_owned(),
        "cmux://agent/claude/s1?host=..".to_owned(),
    ] {
        let link = parse(&text, "cmux").unwrap();
        assert_eq!(link.target, agent("claude", "s1"));
        assert_eq!(link.host_hint, None);
        let name = text.contains("name=Lanternfish").then(|| "Lanternfish".to_owned());
        assert_eq!(link.name_hint, name, "{text}");
    }
}

#[test]
fn hints_never_ride_on_other_links() {
    let link = parse(&format!("cmux://tab/{TAB}?host=build-mac&name=Lanternfish"), "cmux").unwrap();
    assert_eq!(link, tab(TAB));
    assert_eq!(link.url("cmux"), Some(format!("cmux://tab/{TAB}")));
    assert_eq!(DeepLink { host_hint: Some("build-mac".into()), ..tab(TAB) }.url("cmux"), None);
}

#[test]
fn existing_links_format_exactly_as_before() {
    for text in [
        "cmux://workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://pane/pane_0123456789abcdef0123456789abcdef",
        "cmux://tab/tab_0123456789abcdef0123456789abcdef?machine=machine_0123456789abcdef0123456789abcdef",
        "cmux://session/ses-01.example_a",
        "cmux://session/ses-01.example_a#turn-turn_7",
        "cmux://chief/2e448bc2/session/01a12408-f0a2",
        "cmux://workspace/6B1F0A52-6C0F-4B44-9A43-0F4C2C0E6D11?stable_workspace_id=0E3C1F8A-1A2B-4C3D-8E9F-0A1B2C3D4E5F",
    ] {
        let link = parse(text, "cmux").unwrap();
        assert!(link.host_hint.is_none() && link.name_hint.is_none());
        assert_eq!(link.url("cmux").as_deref(), Some(text));
    }
}

#[test]
fn legacy_links_read_as_nightly_read_them() {
    let w = "6b1f0a52-6c0f-4b44-9a43-0f4c2c0e6d11";
    let s = "0E3C1F8A-1A2B-4C3D-8E9F-0A1B2C3D4E5F";
    let upper = w.to_uppercase();
    assert_eq!(
        parse(&format!("cmux://workspace/{w}/panel/{s}?stable_surface_id={s}"), "cmux")
            .unwrap()
            .target,
        Target::LegacySurface {
            workspace: upper.clone(),
            surface: s.into(),
            fallback_workspace: None,
            fallback_surface: Some(s.into())
        }
    );
    assert_eq!(
        parse(&format!("cmux://workspace/{w}/PANE/{s}"), "cmux").unwrap().target,
        Target::LegacyPane { workspace: upper.clone(), pane: s.into() }
    );
    assert!(parse(&format!("cmux://workspace/{w}?stable_workspace_id=nope"), "cmux").is_none());
    assert!(parse(&format!("cmux://workspace/{w}#x"), "cmux").is_none());
    assert!(parse(&format!("cmux://workspace/{w}/tab/{s}"), "cmux").is_none());
    let link = parse(&format!("cmux://workspace/{w}/surface/{s}?stable_workspace_id={w}"), "cmux")
        .unwrap();
    assert_eq!(
        link.url("cmux"),
        Some(format!("cmux://workspace/{upper}/surface/{s}?stable_workspace_id={upper}"))
    );
    assert_eq!(
        app_link(&format!("cmux://workspace/{w}"), "cmux-dev", true),
        None,
        "a legacy link is not an app link"
    );
}

#[test]
fn schemes_compare_case_insensitively_and_the_callback_is_no_link() {
    assert!(parse(&format!("CMUX://TAB/{TAB}"), "cmux").is_some());
    assert!(parse(&format!("cmux://tab/{TAB}"), "CMUX").is_some());
    assert!(parse("cmux://auth-callback/x", "cmux").is_none());
    assert!(parse(&format!("cmux:tab/{TAB}"), "cmux").is_none());
    assert!(parse(&format!("cmux:///{TAB}"), "cmux").is_none());
    assert!(DeepLink::new(Target::Tab(TAB.into())).url("1cmux").is_none());
}

// MARK: Which tab an agent link opens

const SESSION: &str = "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d";

fn candidate(tab: &str, harness: Option<&str>, session: Option<&str>) -> AgentCandidate {
    AgentCandidate {
        tab: tab.into(),
        harness: harness.map(Into::into),
        session: session.map(Into::into),
    }
}

fn first(harness: &str, adopted: Option<&str>, terminals: &[AgentCandidate]) -> Option<String> {
    agent_tabs(harness, SESSION, adopted, terminals).into_iter().next()
}

#[test]
fn which_tab_an_agent_link_opens() {
    let t = [candidate("term-1", Some("claude"), Some(SESSION))];
    assert_eq!(first("claude", Some("chat-1"), &t).as_deref(), Some("chat-1"));
    let t = [
        candidate("term-0", Some("claude"), Some("other")),
        candidate("term-1", None, None),
        candidate("term-2", Some("claude"), Some(SESSION)),
    ];
    assert_eq!(first("claude", None, &t).as_deref(), Some("term-2"));
    let t = [
        candidate("term-1", Some("codex"), Some(SESSION)),
        candidate("term-2", Some("Claude"), Some(SESSION)),
    ];
    assert_eq!(first("claude", None, &t).as_deref(), Some("term-2"));
    assert_eq!(first("gemini", None, &t), None);
    let t = [candidate("term-1", None, Some(SESSION))];
    assert_eq!(first("claude", None, &t).as_deref(), Some("term-1"));
    let t = [
        candidate("term-1", Some("general-purpose"), Some(SESSION)),
        candidate("term-2", Some("claude-code"), Some(SESSION)),
    ];
    assert_eq!(agent_tabs("claude", SESSION, None, &t), ["term-2", "term-1"]);
    assert_eq!(agent_tabs("codex", SESSION, None, &t), ["term-1"]);
    let t = [
        candidate("term-1", None, Some(SESSION)),
        candidate("term-2", Some("claude"), Some(SESSION)),
        candidate("term-3", Some("codex"), Some(SESSION)),
    ];
    assert_eq!(agent_tabs("claude", SESSION, Some("chat-1"), &t), ["chat-1", "term-2", "term-1"]);
    assert_eq!(first("claude", None, &[candidate("term-1", Some("claude"), Some("other"))]), None);
    assert_eq!(first("claude", None, &[]), None);
}

// MARK: DeepLinkAgentWebTests

#[test]
fn a_footer_link_is_the_agent_link_it_names() {
    let link = agent_web(
        "https://cmux.com/deeplink/agent?harness=claude&session=01a18a35-b23b-7b61-9798-dba14474a974&host=cosmic-gray",
    )
    .unwrap();
    assert_eq!(link.target, agent("claude", "01a18a35-b23b-7b61-9798-dba14474a974"));
    assert_eq!(link.host_hint.as_deref(), Some("cosmic-gray"));
    assert_eq!(
        link.url("cmux").as_deref(),
        Some("cmux://agent/claude/01a18a35-b23b-7b61-9798-dba14474a974?host=cosmic-gray")
    );
    for text in [
        "https://www.cmux.com/deeplink/agent/?harness=codex&session=s:1",
        "https://cmux.com/en/deeplink/agent?harness=codex&session=s:1",
        "https://cmux.com/zh-CN/deeplink/agent?harness=codex&session=s:1&name=lane",
    ] {
        assert_eq!(agent_web(text).unwrap().target, agent("codex", "s:1"), "{text}");
    }
    let link =
        agent_web("https://cmux.com/deeplink/agent?harness=claude&session=s1&message=m_1").unwrap();
    assert_eq!(link.message.as_deref(), Some("m_1"));
}

#[test]
fn a_web_link_with_no_harness_names_its_session_id() {
    let url = "https://cmux.com/deeplink/agent?session=01a19f86-e54b-78b3-9911-4326190bc1aa&host=cosmic-gray";
    assert_eq!(agent_web(url), None);
    assert_eq!(agent_web_session(url).as_deref(), Some("01a19f86-e54b-78b3-9911-4326190bc1aa"));
    assert_eq!(
        agent_web_session("https://cmux.com/deeplink/agent?harness=claude&session=s1"),
        None
    );
    assert_eq!(agent_web_session("https://cmux.com/deeplink/agent?session=a&session=b"), None);
    assert_eq!(agent_web_session("https://evil.com/deeplink/agent?session=s1"), None);
    assert_eq!(
        agent_web_session("https://cmux.com/deeplink/agent?id=aid-81baa1463f6190d4c5dc"),
        None
    );
}

#[test]
fn any_other_web_url_is_not_an_agent_link() {
    for text in [
        "https://cmux.com/deeplink/agent?id=aid-81baa1463f6190d4c5dc",
        "https://cmux.com/deeplink/agent?harness=claude",
        "https://cmux.com/deeplink/agent?harness=claude&session=a&session=b",
        "https://cmux.com/deeplink/agent?harness=Not%20one&session=s1",
        "http://cmux.com/deeplink/agent?harness=claude&session=s1",
        "https://evil.com/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com.evil.com/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com:8443/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com/x/y/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com/deeplink/agentx?harness=claude&session=s1",
        "https://cmux.com/deeplink/agent?harness=claude&session=s1#frag",
        "cmux://agent/claude/s1",
        // A harness or session that would read as more path.
        "https://cmux.com/deeplink/agent?harness=claude%2Fx&session=s1",
        "https://cmux.com/deeplink/agent?harness=&session=s1",
    ] {
        assert_eq!(agent_web(text), None, "{text}");
    }
}

// MARK: DeepLinkAgentReferenceTests

#[test]
fn a_footer_link_and_what_the_page_opens_name_the_reference() {
    let id = "aid-d750cf10922c785efa64";
    for text in [
        "cmux://agent?id=aid-d750cf10922c785efa64",
        "cmux://agent/?id=aid-d750cf10922c785efa64",
        "cmux-dev-tag://agent?id=aid-d750cf10922c785efa64",
        "https://cmux.com/deeplink/agent?id=aid-d750cf10922c785efa64",
        "https://www.cmux.com/en/deeplink/agent/?id=aid-d750cf10922c785efa64",
    ] {
        assert_eq!(agent_reference(text, "cmux-dev-tag").as_deref(), Some(id), "{text}");
        assert!(opens_agent_chat(text, "cmux-dev-tag"));
    }
    for text in [
        "cmux://agent?id=aid-D750CF10922C785EFA64",
        "cmux://agent?id=aid-d750cf10922c785efa6",
        "cmux://agent?id=aid-d750cf10922c785efa64%0A",
        "cmux://agent?id=aid-d750cf10922c785efa64&id=aid-d750cf10922c785efa64",
        "cmux://agent?id=aid-d750cf10922c785efa64&session=s1",
        "cmux://agent?id=aid-d750cf10922c785efa64&harness=claude",
        "cmux://agent/claude/s1?id=aid-d750cf10922c785efa64",
        "cmux://agent?id=aid-d750cf10922c785efa64#x",
        "cmux://session?id=aid-d750cf10922c785efa64",
        "other://agent?id=aid-d750cf10922c785efa64",
        "https://evil.com/deeplink/agent?id=aid-d750cf10922c785efa64",
        "https://cmux.com/deeplink/agent?harness=claude&session=s1",
        "cmux://agent",
    ] {
        assert_eq!(agent_reference(text, "cmux-dev-tag"), None, "{text}");
    }
    assert_eq!(agent_web(&format!("https://cmux.com/deeplink/agent?id={id}")), None);
    assert!(is_agent_reference(id));
    assert!(!is_agent_reference(&format!("{id}\n")));
    assert!(opens_agent_chat("cmux-dev-tag://agent/claude/s1", "cmux-dev-tag"));
    assert!(!opens_agent_chat("cmux://agent/claude/s1", "cmux-dev-tag"));
}

#[test]
fn a_locale_matches_as_icu_reads_it() {
    // ICU's `$` also matches before a final newline, so a `%0A` locale is still a locale.
    assert_eq!(
        agent_reference("https://cmux.com/en%0A/deeplink/agent?id=aid-d750cf10922c785efa64", "x")
            .as_deref(),
        Some("aid-d750cf10922c785efa64")
    );
    assert_eq!(
        agent_reference("https://cmux.com/EN/deeplink/agent?id=aid-d750cf10922c785efa64", "x"),
        None
    );
}

// MARK: DeepLinkGroupTests

const GROUP: &str = "grp_f9a917b1721deb93e834";
const WORKSPACE: &str = "ws_44220fb62e6d67c82e50c9faf18eb4c3";

#[test]
fn a_group_link_parses_and_formats_back() {
    let text = format!("cmux://group/{GROUP}");
    let link = parse(&text, "cmux").unwrap();
    assert_eq!(link.target, Target::Group { id: GROUP.into(), workspace: None });
    assert_eq!(link.url("cmux"), Some(text));
    let text = format!("cmux://group/{GROUP}/workspace/{WORKSPACE}");
    let link = parse(&text, "cmux").unwrap();
    assert_eq!(link.target, Target::Group { id: GROUP.into(), workspace: Some(WORKSPACE.into()) });
    assert_eq!(link.url("cmux"), Some(text));
}

#[test]
fn a_malformed_group_link_is_not_a_link() {
    for text in [
        "cmux://group/grp_F9A917B1721DEB93E834",
        "cmux://group/grp_f9a917b1721deb93e83",
        "cmux://group/grp_f9a917b1721deb93e8345",
        "cmux://group/ws_44220fb62e6d67c82e50c9faf18eb4c3",
        "cmux://group/grp_f9a917b1721deb93e834/workspace/grp_f9a917b1721deb93e834",
        "cmux://group/grp_f9a917b1721deb93e834/tab/tab_44220fb62e6d67c82e50c9faf18eb4c3",
        "cmux://group/grp_f9a917b1721deb93e834#turn-1",
        "cmux://group/grp_f9a917b1721deb93e834/workspace/ws_44220fb62e6d67c82e50c9faf18eb4c3/x",
    ] {
        assert_eq!(parse(text, "cmux"), None, "{text}");
    }
}

#[test]
fn the_web_form_opens_the_same_group() {
    let prod = group_web(&format!("https://cloud-api.cmux.dev/g/{GROUP}")).unwrap();
    assert_eq!(prod.target, Target::Group { id: GROUP.into(), workspace: None });
    let staging =
        group_web(&format!("https://cloud-api-staging.cmux.dev/g/{GROUP}/w/{WORKSPACE}")).unwrap();
    assert_eq!(
        staging.target,
        Target::Group { id: GROUP.into(), workspace: Some(WORKSPACE.into()) }
    );
    assert!(group_web(&format!("https://cmux.com/g/{GROUP}")).is_some());
    assert_eq!(app_link(&format!("https://cmux.com/g/{GROUP}"), "cmux-dev", false), Some(prod));
    for text in [
        "https://evil.example/g/grp_f9a917b1721deb93e834",
        "http://cloud-api.cmux.dev/g/grp_f9a917b1721deb93e834",
        "https://cloud-api.cmux.dev:8443/g/grp_f9a917b1721deb93e834",
        "https://cloud-api.cmux.dev/g/grp_f9a917b1721deb93e834?run=1",
        "https://cloud-api.cmux.dev/g/grp_nothex!",
        "https://cloud-api.cmux.dev/x/grp_f9a917b1721deb93e834",
    ] {
        assert_eq!(group_web(text), None, "{text}");
    }
}

// MARK: DeepLinkCloudSessionTests

const TEAM: &str = "team_0123456789abcdefghij";
const VM: &str = "vm_8c2f41aa";

fn cloud(session: &str, machine: &str, kind: CloudSessionKind) -> Target {
    Target::CloudSession {
        team: TEAM.into(),
        machine: machine.into(),
        session: session.into(),
        kind,
    }
}

#[test]
fn cloud_links_parse_and_format_back() {
    let text = format!("cmux://cloud/session/{TEAM}/{VM}/s_01HZY.claude:2");
    let link = parse(&text, "cmux").unwrap();
    assert_eq!(link.target, cloud("s_01HZY.claude:2", VM, CloudSessionKind::Chat));
    assert_eq!(link.url("cmux"), Some(text));
    let text = format!("cmux://cloud/workspace/{TEAM}/vm-legacy01/ws_44220fb62e6d");
    let link = parse(&text, "cmux").unwrap();
    assert_eq!(link.target, cloud("ws_44220fb62e6d", "vm-legacy01", CloudSessionKind::Workspace));
    assert_eq!(link.url("cmux"), Some(text));
    // A cloud link reads no parameter, so even `machine` is ignored by name.
    let parsed =
        read(&format!("cmux://cloud/session/{TEAM}/{VM}/s1?machine={MACHINE}"), "cmux").unwrap();
    assert_eq!(parsed.ignored, ["machine"]);
    assert_eq!(parsed.link.machine.as_deref(), Some(MACHINE));
}

#[test]
fn a_malformed_cloud_link_is_not_a_link() {
    for text in [
        "cmux://cloud/session/team_0123456789ABCDEFGHIJ/vm_8c2f41aa/s1",
        "cmux://cloud/session/team_0123456789abcdefghi/vm_8c2f41aa/s1",
        "cmux://cloud/session/grp_0123456789abcdefghij/vm_8c2f41aa/s1",
        "cmux://cloud/session/team_0123456789abcdefghij/box_8c2f41aa/s1",
        "cmux://cloud/session/team_0123456789abcdefghij/vm_/s1",
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa/-s1",
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa",
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa/s1/x",
        "cmux://cloud/chat/team_0123456789abcdefghij/vm_8c2f41aa/s1",
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa/s1#turn-2",
    ] {
        assert_eq!(parse(text, "cmux"), None, "{text}");
    }
    let id = "a".repeat(129);
    assert!(parse(&format!("cmux://cloud/session/{TEAM}/{VM}/{id}"), "cmux").is_none());
    assert!(parse(&format!("cmux://cloud/session/{TEAM}/{VM}/{}", &id[1..]), "cmux").is_some());
}

#[test]
fn the_key_and_either_scheme_name_the_same_session() {
    let key = cloud_session(&format!("  cloud:{TEAM}/{VM}/s1\n")).unwrap();
    assert_eq!(key.target, cloud("s1", VM, CloudSessionKind::Chat));
    let dev = cloud_session(&format!("cmux-dev://cloud/workspace/{TEAM}/{VM}/ws_1")).unwrap();
    assert_eq!(dev.target, cloud("ws_1", VM, CloudSessionKind::Workspace));
    assert_eq!(cloud_session(&format!("cloud:{TEAM}/{VM}")), None);
    assert_eq!(cloud_session("cmux://workspace/ws_44220fb62e6d67c82e50c9faf18eb4c3"), None);
    assert_eq!(cloud_session(&format!("https://example.com/cloud/session/{TEAM}/{VM}/s1")), None);
    assert_eq!(cloud_session(&format!("https://cloud/session/{TEAM}/{VM}/s1")), None);
}

// MARK: AgentLinkSchemaTests

fn schema() -> Value {
    let text = std::fs::read_to_string(repo().join("schemas/deeplinks/agent-link.json"))
        .expect("the schema");
    serde_json::from_str(&text).expect("schema JSON")
}

fn fields(link: &DeepLink) -> Option<Value> {
    let Target::Agent { harness, session } = &link.target else { return None };
    let mut map = serde_json::Map::new();
    map.insert("harness".into(), json!(harness));
    map.insert("session".into(), json!(session));
    for (key, value) in [
        ("machine", &link.machine),
        ("host", &link.host_hint),
        ("name", &link.name_hint),
        ("message", &link.message),
    ] {
        if let Some(value) = value {
            map.insert(key.into(), json!(value));
        }
    }
    Some(Value::Object(map))
}

#[test]
fn the_parser_reads_the_schemas_parameters() {
    let schema = schema();
    assert_eq!(schema["nativeHost"], "agent");
    assert_eq!(schema["pathParams"], json!(["harness", "session"]));
    let mut queries: Vec<String> =
        serde_json::from_value(schema["queryParams"].clone()).expect("queryParams");
    let mut read: Vec<String> =
        parameters(&agent("claude", "s1")).iter().map(|s| s.to_string()).collect();
    queries.sort();
    read.sort();
    assert_eq!(queries, read);
}

/// The schema's charsets, probe for probe (the patterns are `^(?!\.+$)[class]{lo,hi}$` or
/// `^prefix[class]{n}$`, checked here by hand since the crate has no regex engine).
#[test]
fn the_parsers_charsets_are_the_schemas() {
    let probes: Vec<String> = [
        "a",
        "A",
        "claude-code",
        "Claude",
        "ses-01.example_a",
        "msg_01hq9f4c7k",
        "5cf944c9-b816-486a-a3aa-c89b3faea35f",
        "machine_0123456789abcdef0123456789abcdef",
        "machine_0123456789ABCDEF0123456789abcdef",
        "machine_0123456789abcdef",
        "",
        ".",
        "..",
        "...",
        "a b",
        "a/b",
        "a?b",
        "a%20b",
        "<script>",
        "a@b",
        "a:b",
        "session:with:colon",
    ]
    .iter()
    .map(|s| s.to_string())
    .chain([64, 65, 200, 201, 256, 257].iter().map(|n| "a".repeat(*n)))
    .collect();
    let schema = schema();
    let params = schema["params"].as_object().expect("params");
    let mut names: Vec<&String> = params.keys().collect();
    names.sort();
    assert_eq!(names, ["harness", "host", "machine", "message", "name", "session"]);
    for (name, spec) in params {
        let pattern = spec["pattern"].as_str().expect("a pattern");
        let reads: fn(&str) -> bool = match name.as_str() {
            "harness" => is_harness,
            "session" => is_agent_session,
            "host" | "name" => is_hint,
            "message" => is_agent_message,
            "machine" => |t| is_resource_id(t, "machine_"),
            _ => unreachable!(),
        };
        for probe in &probes {
            assert_eq!(reads(probe), matches_pattern(pattern, probe), "{name} reads {probe:?}");
        }
    }
}

/// The schema's small pattern language: an optional `(?!\.+$)`, an optional literal prefix,
/// one `[class]` and a `{n}` or `{lo,hi}` count.
fn matches_pattern(pattern: &str, text: &str) -> bool {
    let body = pattern.strip_prefix('^').and_then(|p| p.strip_suffix('$')).expect("anchored");
    let (no_dots, body) = match body.strip_prefix("(?!\\.+$)") {
        Some(rest) => (true, rest),
        None => (false, body),
    };
    let open = body.find('[').expect("a class");
    let close = body.find(']').expect("a class");
    let (prefix, class, count) = (&body[..open], &body[open + 1..close], &body[close + 1..]);
    let count = count.trim_start_matches('{').trim_end_matches('}');
    let (lo, hi): (usize, usize) = match count.split_once(',') {
        Some((lo, hi)) => (lo.parse().unwrap(), hi.parse().unwrap()),
        None => (count.parse().unwrap(), count.parse().unwrap()),
    };
    let class = class.as_bytes();
    let in_class = |b: u8| {
        let mut i = 0;
        while i < class.len() {
            if i + 2 < class.len() && class[i + 1] == b'-' {
                if (class[i]..=class[i + 2]).contains(&b) {
                    return true;
                }
                i += 3;
            } else {
                if class[i] == b {
                    return true;
                }
                i += 1;
            }
        }
        false
    };
    if no_dots && !text.is_empty() && text.bytes().all(|b| b == b'.') {
        return false;
    }
    let Some(rest) = text.strip_prefix(prefix) else { return false };
    (lo..=hi).contains(&rest.len()) && rest.bytes().all(in_class)
}

#[test]
fn every_vector_reads_and_writes_back_as_the_schema_says() {
    let schema = schema();
    let vectors = schema["vectors"].as_array().expect("vectors");
    assert!(vectors.len() >= 20);
    assert!(vectors.iter().filter(|v| v["link"].is_string()).count() >= 15);
    for vector in vectors {
        let name = vector["name"].as_str().unwrap();
        let Some(text) = vector["link"].as_str() else { continue };
        let Some(expected) = vector.get("fields").filter(|f| f.is_object()) else {
            assert!(read(text, "cmux").is_none(), "{name}: {text} is not a link");
            continue;
        };
        let parsed = read(text, "cmux").unwrap_or_else(|| panic!("{name}: {text} is a link"));
        assert_eq!(fields(&parsed.link).as_ref(), Some(expected), "{name}");
        let ignored: Vec<String> = if vector["web"].is_string() {
            Vec::new()
        } else {
            serde_json::from_value(vector["ignored"].clone()).unwrap_or_default()
        };
        assert_eq!(parsed.ignored, ignored, "{name}");
        let written = parsed.link.url("cmux").unwrap_or_else(|| panic!("{name} is written back"));
        if vector["web"].is_string() {
            assert_eq!(written, text, "{name}");
        }
        assert_eq!(parse(&written, "cmux"), Some(parsed.link), "{name} round trips");
    }
}

#[test]
fn a_message_link_names_the_message() {
    let text = "cmux://agent/claude/e8f63fd9-94e8-4878-bcd4-704659aba1f2?host=cosmic-gray&message=5cf944c9-b816-486a-a3aa-c89b3faea35f";
    let link = parse(text, "cmux").unwrap();
    assert_eq!(link.target, agent("claude", "e8f63fd9-94e8-4878-bcd4-704659aba1f2"));
    assert_eq!(link.host_hint.as_deref(), Some("cosmic-gray"));
    assert_eq!(link.message.as_deref(), Some("5cf944c9-b816-486a-a3aa-c89b3faea35f"));
    assert_eq!(link.name_hint, None);
    assert_eq!(link.url("cmux").as_deref(), Some(text));
}

#[test]
fn an_unusable_message_is_dropped_not_the_link() {
    for text in [
        "cmux://agent/claude/s1?message=m%201".to_owned(),
        "cmux://agent/claude/s1?message=".to_owned(),
        "cmux://agent/claude/s1?message=..".to_owned(),
        format!("cmux://agent/claude/s1?message={}", "m".repeat(201)),
        "cmux://agent/claude/s1?message=m-1&message=m-2".to_owned(),
    ] {
        let parsed = read(&text, "cmux").unwrap();
        assert_eq!(parsed.link.target, agent("claude", "s1"));
        assert_eq!(parsed.link.message, None);
        assert_eq!(parsed.ignored, ["message"], "{text}");
    }
}

#[test]
fn a_stray_parameter_never_costs_the_chat() {
    let cases: &[(&str, &[&str])] = &[
        ("cmux://agent/claude/s1?cwd=%2Fhome%2Fleo", &["cwd"]),
        ("cmux://agent/claude/s1?cwd=x&cwd=y", &["cwd"]),
        ("cmux://agent/claude/s1?machine=not-a-resource-id", &["machine"]),
        ("cmux://agent/claude/s1?machine", &["machine"]),
        ("cmux://agent/claude/s1?machine=", &["machine"]),
        (
            "cmux://agent/claude/s1?machine=machine_0123456789abcdef0123456789abcdef&machine=machine_fedcba9876543210fedcba9876543210",
            &["machine"],
        ),
        ("cmux://agent/claude/s1?host=a&host=b", &["host"]),
        ("cmux://agent/claude/s1?account=someone%40example.com", &["account"]),
        ("cmux://agent/claude/s1?cwd=x&host=a&host=b&machine=nope", &["machine", "host", "cwd"]),
        ("cmux://agent/claude/s1?message=&name=a&name=b", &["name", "message"]),
    ];
    for (text, ignored) in cases {
        let parsed = read(text, "cmux").unwrap();
        assert_eq!(parsed.link.target, agent("claude", "s1"));
        assert_eq!(&parsed.ignored, ignored, "{text}");
    }
}

#[test]
fn the_names_of_an_agent_links_path_are_never_said_to_be_ignored() {
    let parsed = read("cmux://agent/claude/s1?session=x&harness=y&cwd=z", "cmux").unwrap();
    assert_eq!(parsed.link.target, agent("claude", "s1"));
    assert_eq!(parsed.ignored, ["session", "harness", "cwd"]);
    let used = parsed.link.used_parameters();
    assert!(used.contains(&"harness") && used.contains(&"session") && !used.contains(&"cwd"));
    let other = read(&format!("cmux://tab/{TAB}?session=x"), "cmux").unwrap();
    assert_eq!(other.ignored, ["session"]);
    assert!(other.link.used_parameters().is_empty());
}

#[test]
fn a_link_with_nothing_stray_ignores_nothing() {
    let text = format!(
        "cmux://agent/codex/s1?host=big-red&name=Rivetmoss&message=msg_1&machine={MACHINE}"
    );
    assert_eq!(read(&text, "cmux").unwrap().ignored, Vec::<String>::new());
}

#[test]
fn the_other_kinds_are_unchanged() {
    let parsed = read(&format!("cmux://tab/{TAB}?cwd=x"), "cmux").unwrap();
    assert_eq!(parsed.link, tab(TAB));
    assert_eq!(parsed.ignored, ["cwd"]);
    assert!(read("cmux://session/ses-01?machine=nope", "cmux").is_none());
    assert_eq!(read(&format!("cmux://tab/{TAB}?machine"), "cmux").unwrap().link, tab(TAB));
    let repeated = format!("cmux://tab/{TAB}?machine={MACHINE}&machine=machine_ffff");
    assert_eq!(
        read(&repeated, "cmux").unwrap().link,
        DeepLink { machine: Some(MACHINE.into()), ..tab(TAB) }
    );
    let w = "6B1F0A52-6C0F-4B44-9A43-0F4C2C0E6D11";
    let legacy = read(&format!("cmux://workspace/{w}?stable_workspace_id={w}"), "cmux").unwrap();
    assert!(legacy.ignored.is_empty());
}

#[test]
fn a_message_never_rides_on_another_link() {
    assert_eq!(DeepLink { message: Some("msg_1".into()), ..tab(TAB) }.url("cmux"), None);
    let link = parse(&format!("cmux://tab/{TAB}?message=msg_1"), "cmux").unwrap();
    assert_eq!(link.message, None);
    assert_eq!(link.url("cmux"), Some(format!("cmux://tab/{TAB}")));
}

#[test]
fn only_well_formed_messages_are_written() {
    let written = |m: &str| {
        DeepLink { message: Some(m.into()), ..DeepLink::new(agent("claude", "s1")) }.url("cmux")
    };
    assert!(written("msg_01").is_some());
    assert!(written(&"m".repeat(200)).is_some());
    assert!(written(&"m".repeat(201)).is_none());
    assert!(written("").is_none());
    assert!(written("..").is_none());
    assert!(written("msg 1").is_none());
    assert!(written("msg/1").is_none());
}

// MARK: App links and settings links

#[test]
fn app_links_open_in_either_scheme() {
    assert_eq!(app_link(&format!("cmux-dev-x://tab/{TAB}"), "cmux-dev-x", false), Some(tab(TAB)));
    assert_eq!(app_link(&format!("cmux://tab/{TAB}"), "cmux-dev-x", false), Some(tab(TAB)));
    assert_eq!(app_link(&format!("other://tab/{TAB}"), "cmux-dev-x", false), None);
    let chief = "cmux://chief/2e448bc2/session/s1";
    assert_eq!(app_link(chief, "cmux-dev-x", false), None);
    assert!(app_link(chief, "cmux-dev-x", true).is_some());
    assert_eq!(app_link(&format!("{chief}?machine={MACHINE}"), "cmux-dev-x", true), None);
}

#[test]
fn settings_links_name_their_route() {
    let route = |text: &str| settings_route(text, "cmux-dev-x");
    assert_eq!(route("cmux://settings/models").as_deref(), Some("#/settings/models"));
    assert_eq!(route("cmux-dev-x://settings/models/").as_deref(), Some("#/settings/models"));
    assert_eq!(
        route("CMUX://Settings/Models/Add").as_deref(),
        Some("#/settings/models?focus=models.add")
    );
    assert_eq!(route("cmux://settings/cloud").as_deref(), Some("#/settings/cloud"));
    assert_eq!(
        route("cmux://settings/cloud/claude").as_deref(),
        Some("#/settings/cloud?focus=cloud.claude")
    );
    assert_eq!(
        route("cmux://settings/cloud/chatgpt/").as_deref(),
        Some("#/settings/cloud?focus=cloud.chatgpt")
    );
    assert_eq!(
        route("cmux://settings/cloud/api-key").as_deref(),
        Some("#/settings/cloud?focus=cloud.apiKey")
    );
    assert_eq!(route("cmux://settings/background"), None);
    assert_eq!(route("other://settings/models"), None);
    assert_eq!(route("cmux://prefs/models"), None);
    assert_eq!(settings_path("cmux://settings/Background/", "x").as_deref(), Some("/background"));
    assert_eq!(settings_path("cmux://settings", "x").as_deref(), Some(""));
    assert_eq!(cloud_route(None), "#/settings/cloud");
}

// MARK: LinkExportTests: plans/cmux-next/links.json byte for byte

#[test]
fn the_export_is_the_checked_in_links_json() {
    let path = repo().join("plans/cmux-next/links.json");
    let Ok(file) = std::fs::read_to_string(&path) else {
        // A sparse checkout without plans/ has nothing to compare.
        return;
    };
    let value: Value = serde_json::from_str(&file).unwrap();
    let schemes: Vec<ExportScheme> = value["schemes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| ExportScheme {
            build: row["build"].as_str().unwrap().into(),
            bundle_id: row["bundle_id"].as_str().map(Into::into),
            scheme: row["scheme"].as_str().unwrap().into(),
            example_tag: row["example_tag"].as_str().map(Into::into),
        })
        .collect();
    assert_eq!(export_json(&schemes), file);
}

// MARK: The C ABI

fn ffi(request: &Value) -> Result<Value, i32> {
    let body = request.to_string();
    let mut reply = std::ptr::null_mut();
    let mut len = 0usize;
    // SAFETY: `body` is live and both out pointers are locals.
    let status = unsafe { cmux_deep_link_call(body.as_ptr(), body.len(), &mut reply, &mut len) };
    if status != OK {
        return Err(status);
    }
    // SAFETY: on OK the reply is `len` bytes this test frees once below.
    let value = serde_json::from_slice(unsafe { std::slice::from_raw_parts(reply, len) }).unwrap();
    // SAFETY: exactly what the call wrote, freed once.
    unsafe { cmux_deep_link_free(reply, len) };
    Ok(value)
}

#[test]
fn the_c_abi_reads_and_writes_links_as_swift_codes_them() {
    let read =
        ffi(&json!({"op": "read", "url": format!("cmux://tab/{TAB}?cwd=x"), "scheme": "cmux"}))
            .unwrap();
    assert_eq!(
        read,
        json!({"link": {"target": {"tab": {"_0": TAB}}}, "ignoredParameters": ["cwd"]})
    );
    let link = json!({"target": {"agent": {"harness": "claude", "session": "s1"}}, "hostHint": "h", "nameHint": null});
    assert_eq!(
        ffi(&json!({"op": "url", "link": link, "scheme": "cmux"})).unwrap(),
        json!("cmux://agent/claude/s1?host=h")
    );
    let w = "6b1f0a52-6c0f-4b44-9a43-0f4c2c0e6d11";
    let legacy =
        ffi(&json!({"op": "parse", "url": format!("cmux://workspace/{w}"), "scheme": "cmux"}))
            .unwrap();
    assert_eq!(legacy, json!({"target": {"legacyWorkspace": {"_0": w.to_uppercase()}}}));
    let cloud = json!({"target": {"cloudSession": {"team": TEAM, "machine": VM, "session": "s1", "kind": "session"}}});
    assert_eq!(
        ffi(&json!({"op": "url", "link": cloud, "scheme": "cmux"})).unwrap(),
        json!(format!("cmux://cloud/session/{TEAM}/{VM}/s1"))
    );
    assert_eq!(
        ffi(&json!({"op": "parse", "url": "cmux://nope/x", "scheme": "cmux"})).unwrap(),
        Value::Null
    );
    assert_eq!(
        ffi(&json!({"op": "valid", "rule": "harness", "text": "claude"})).unwrap(),
        json!(true)
    );
    assert_eq!(
        ffi(&json!({"op": "valid", "rule": "resourceID", "text": MACHINE, "prefix": "machine_"}))
            .unwrap(),
        json!(true)
    );
    assert_eq!(
        ffi(&json!({"op": "parameters", "target": {"tab": {"_0": TAB}}})).unwrap(),
        json!(["machine"])
    );
    assert_eq!(
        ffi(&json!({"op": "agentTabs", "harness": "claude", "session": "s", "terminals": [
            {"tab": "t1", "session": "s"}, {"tab": "t2", "harness": "claude", "session": "s"}]}))
        .unwrap(),
        json!(["t2", "t1"])
    );
    assert_eq!(ffi(&json!({"op": "nope"})), Err(ERR_INVALID));
    let body = b"not json";
    let mut reply = std::ptr::null_mut();
    let mut len = 0usize;
    // SAFETY: `body` is live and both out pointers are locals.
    assert_eq!(
        unsafe { cmux_deep_link_call(body.as_ptr(), body.len(), &mut reply, &mut len) },
        ERR_INVALID
    );
}

/// Every target round trips through its Swift Codable shape.
#[test]
fn every_target_round_trips_through_the_c_abi() {
    let u = "6B1F0A52-6C0F-4B44-9A43-0F4C2C0E6D11";
    let links = [
        format!("cmux://workspace/ws_{}", "0".repeat(32)),
        format!("cmux://pane/pane_{}", "0".repeat(32)),
        format!("cmux://tab/{TAB}?machine={MACHINE}"),
        "cmux://session/s1#turn-t1".to_owned(),
        "cmux://chief/2e448bc2/session/s1".to_owned(),
        "cmux://agent/claude/s1?host=h&name=n&message=m".to_owned(),
        format!("cmux://group/{GROUP}/workspace/{WORKSPACE}"),
        format!("cmux://cloud/workspace/{TEAM}/{VM}/w1"),
        format!("cmux://workspace/{u}?stable_workspace_id={u}"),
        format!("cmux://workspace/{u}/pane/{u}"),
        format!("cmux://workspace/{u}/surface/{u}?stable_workspace_id={u}&stable_surface_id={u}"),
    ];
    for text in links {
        let link = ffi(&json!({"op": "parse", "url": text, "scheme": "cmux"})).unwrap();
        assert!(link.is_object(), "{text}");
        assert_eq!(
            ffi(&json!({"op": "url", "link": link, "scheme": "cmux"})).unwrap(),
            json!(text)
        );
    }
}
