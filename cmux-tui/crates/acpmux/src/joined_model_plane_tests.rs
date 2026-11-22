//! `joined_model_plane.rs`: the decision table and the egress policy for the machine credential.

use super::*;
use std::sync::atomic::{AtomicU32, Ordering};

struct Machine {
    root: PathBuf,
    home: PathBuf,
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn machine(cloud_image: bool) -> Machine {
    static N: AtomicU32 = AtomicU32::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let root =
        std::env::temp_dir().join(format!("acpmux-joined-model-plane-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    if cloud_image {
        std::fs::write(root.join("etc/cmux/vm-kind"), "owner\n").unwrap();
        std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    }
    let home = root.join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    Machine { root, home }
}

fn join() -> Join {
    Join::of("https://hub.example.com").unwrap()
}

async fn claude(
    m: &Machine,
    var: &[(&str, &str)],
    join: Option<&Join>,
) -> Option<[(String, String); 2]> {
    let mut env: BTreeMap<String, String> =
        var.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    env.insert("HOME".to_owned(), m.home.to_string_lossy().into_owned());
    let map = env.clone();
    let var = move |k: &str| map.get(k).cloned();
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    crate::claude_cloud_auth::joined_pair(&inputs, &env, None, &m.home, join, |_| async { true })
        .await
}

fn pair() -> [(String, String); 2] {
    [
        ("ANTHROPIC_BASE_URL".to_owned(), "https://hub.example.com".to_owned()),
        ("ANTHROPIC_API_KEY".to_owned(), crate::codex_cloud_auth::PLACEHOLDER_KEY.to_owned()),
    ]
}

#[test]
fn a_join_is_an_https_origin_with_a_dns_host() {
    let j = Join::of("https://Hub.Example.com/").unwrap();
    assert_eq!(j.origin(), "https://hub.example.com");
    assert_eq!(j.host(), "hub.example.com");
    assert_eq!(Join::of("https://hub.example.com:8443").unwrap().host(), "hub.example.com:8443");
    for bad in ["http://hub.example.com", "http://127.0.0.1:8080", "https://10.0.0.1", "nope"] {
        assert_eq!(Join::of(bad), None, "{bad}");
    }
}

/// The decision table: joined and opted in gives the pair; not joined, a Cloud image, not
/// opted in, or a sign-in the person set in the launch gives none.
#[tokio::test]
async fn claude_team_mode_on_a_joined_machine_only_when_asked() {
    let m = machine(false);
    let j = join();
    let team = [("CMUX_CLAUDE_AUTH", "team")];
    assert_eq!(claude(&m, &team, Some(&j)).await, Some(pair()));
    // Not joined.
    assert_eq!(claude(&m, &team, None).await, None);
    // Not opted in: no choice, or own.
    assert_eq!(claude(&m, &[], Some(&j)).await, None);
    assert_eq!(claude(&m, &[("CMUX_CLAUDE_AUTH", "own")], Some(&j)).await, None);
    // A person's own key or endpoint in the launch keeps own, opted in or not.
    for own in [("ANTHROPIC_API_KEY", "sk-own"), ("ANTHROPIC_BASE_URL", "https://x.test")] {
        assert_eq!(claude(&m, &[team[0], own], Some(&j)).await, None, "{own:?}");
    }
    // A saved sign-in with no opt-in stays own.
    std::fs::write(m.home.join(".claude/.credentials.json"), r#"{"claudeAiOauth":{"a":1}}"#)
        .unwrap();
    assert_eq!(claude(&m, &[], Some(&j)).await, None);
    std::fs::remove_file(m.home.join(".claude/.credentials.json")).unwrap();
    // `cr use team claude` opts in; the env pin `own` wins over it.
    let dir = m.home.join(".config/cmux/agent-auth");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("claude"), "team\n").unwrap();
    assert_eq!(claude(&m, &[], Some(&j)).await, Some(pair()));
    assert_eq!(claude(&m, &[("CMUX_CLAUDE_AUTH", "own")], Some(&j)).await, None);
    // An owner Cloud image keeps its edge (`team_pair`), never the hub route.
    let cloud = machine(true);
    assert_eq!(claude(&cloud, &team, Some(&j)).await, None);
}

#[tokio::test]
async fn a_hub_host_that_does_not_resolve_keeps_own() {
    let m = machine(false);
    let env = BTreeMap::from([
        ("HOME".to_owned(), m.home.to_string_lossy().into_owned()),
        ("CMUX_CLAUDE_AUTH".to_owned(), "team".to_owned()),
    ]);
    let map = env.clone();
    let var = move |k: &str| map.get(k).cloned();
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    let j = join();
    let got = crate::claude_cloud_auth::joined_pair(&inputs, &env, None, &m.home, Some(&j), |h| {
        assert_eq!(h, "hub.example.com");
        async { false }
    })
    .await;
    assert_eq!(got, None);
}

#[test]
fn codex_opts_in_by_env_or_choice() {
    let m = machine(false);
    let vars = |pairs: &'static [(&'static str, &'static str)]| {
        move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| (*v).to_owned())
    };
    let check = |pairs: &'static [(&'static str, &'static str)]| {
        let var = vars(pairs);
        let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
        opted_in(&inputs, "CMUX_CODEX_AUTH", "codex")
    };
    assert!(check(&[("CMUX_CODEX_AUTH", "team")]));
    assert!(check(&[("CMUX_CODEX_AUTH", " team\n")]));
    assert!(!check(&[]));
    assert!(!check(&[("CMUX_CODEX_AUTH", "own")]));
    let dir = m.home.join(".config/cmux/agent-auth");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("codex"), "team\n").unwrap();
    assert!(check(&[]));
    assert!(!check(&[("CMUX_CODEX_AUTH", "own")]));
    // Claude's choice is not Codex's.
    std::fs::remove_file(dir.join("codex")).unwrap();
    std::fs::write(dir.join("claude"), "team\n").unwrap();
    assert!(!check(&[]));
}

#[test]
fn codex_gets_a_provider_for_the_hub_route_with_only_the_placeholder() {
    let mut argv: Vec<String> =
        ["codex", "-c", "model=\"gpt-5\"", "app-server"].map(str::to_owned).to_vec();
    assert!(!names_provider(&argv));
    apply_codex(&mut argv, &join());
    assert_eq!(argv[..4], ["codex", "-c", "model=\"gpt-5\"", "app-server"]);
    let overrides: Vec<&str> = argv[4..].iter().skip(1).step_by(2).map(String::as_str).collect();
    assert!(argv[4..].iter().step_by(2).all(|a| a == "-c"));
    assert_eq!(
        overrides,
        [
            "model_provider=\"cmux_hub\"",
            "model_providers.cmux_hub.name=\"cmux\"",
            "model_providers.cmux_hub.base_url=\"https://hub.example.com/v1\"",
            "model_providers.cmux_hub.wire_api=\"responses\"",
            "model_providers.cmux_hub.requires_openai_auth=false",
            "model_providers.cmux_hub.http_headers={ \"x-cmux-inference-authorization\" = \
             \"Bearer cmux-secret://CMUX_MACHINE_CREDENTIAL\" }",
        ]
    );
    assert!(names_provider(&argv));
    assert!(!argv.iter().any(|a| a.contains("cmm_")));
}

#[test]
fn claude_headers_keep_theirs_and_end_with_the_placeholder() {
    assert_eq!(
        claude_headers("x-cmux-workspace-id: ws\nX-CMUX-Inference-Authorization: Bearer forged"),
        "x-cmux-workspace-id: ws\n\
         x-cmux-inference-authorization: Bearer cmux-secret://CMUX_MACHINE_CREDENTIAL"
    );
    assert_eq!(
        claude_headers(""),
        "x-cmux-inference-authorization: Bearer cmux-secret://CMUX_MACHINE_CREDENTIAL"
    );
    // `apply_team` keeps it: an `x-cmux-` line.
    let kept = crate::claude_cloud_auth::cmux_headers(&claude_headers("x-personal: 1"));
    assert_eq!(
        kept,
        "x-cmux-inference-authorization: Bearer cmux-secret://CMUX_MACHINE_CREDENTIAL"
    );
}

/// The proxy's entry fills the credential only toward the hub's host, on its port.
#[test]
fn the_egress_policy_allows_the_credential_only_for_the_hub_host() {
    let secret = secret(&join(), Zeroizing::new("cmm_real".to_owned())).unwrap();
    let policy = crate::vault::egress::policy_with(Some(secret), Vec::new());
    let header = header_value();
    let (value, names) = policy.substitute_header(&header, "hub.example.com", 443).unwrap();
    assert_eq!(value.as_str(), "Bearer cmm_real");
    assert_eq!(names, [CREDENTIAL_NAME]);
    assert!(policy.intercepts("hub.example.com", 443));
    for (host, port) in [
        ("api.anthropic.com", 443),
        ("hub.example.com", 8443),
        ("evil.hub.example.com", 443),
        ("hub.example.com.evil.test", 443),
    ] {
        assert!(policy.substitute_header(&header, host, port).is_none(), "{host}:{port}");
        assert!(!policy.intercepts(host, port), "{host}:{port}");
    }
    assert!(!format!("{:?}", policy.secrets()).contains("cmm_real"));
}

/// `joined_without_sign_in`'s table over `m` with launch env `var`.
fn without_sign_in(m: &Machine, var: &[(&str, &str)]) -> bool {
    let mut env: BTreeMap<String, String> =
        var.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    env.insert("HOME".to_owned(), m.home.to_string_lossy().into_owned());
    let map = env.clone();
    let var = move |k: &str| map.get(k).cloned();
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    crate::claude_cloud_auth::joined_without_sign_in(&inputs, &env, None, &m.home)
}

/// A joined launch with no pin, no choice and no sign-in of its own is the one the launch error
/// names; any sign-in, pin or choice is not.
#[test]
fn a_joined_launch_with_no_sign_in_and_no_choice_is_named() {
    let m = machine(false);
    assert!(without_sign_in(&m, &[]));
    for own in [
        ("ANTHROPIC_API_KEY", "sk-own"),
        ("ANTHROPIC_AUTH_TOKEN", "t"),
        ("CLAUDE_CODE_OAUTH_TOKEN", "t"),
        ("ANTHROPIC_BASE_URL", "https://x.test"),
        ("CMUX_CLAUDE_AUTH", "own"),
        ("CMUX_CLAUDE_AUTH", "team"),
    ] {
        assert!(!without_sign_in(&m, &[own]), "{own:?}");
    }
    std::fs::write(m.home.join(".claude/.credentials.json"), r#"{"claudeAiOauth":{"a":1}}"#)
        .unwrap();
    assert!(!without_sign_in(&m, &[]));
    std::fs::remove_file(m.home.join(".claude/.credentials.json")).unwrap();
    let dir = m.home.join(".config/cmux/agent-auth");
    std::fs::create_dir_all(&dir).unwrap();
    for choice in ["own\n", "team\n"] {
        std::fs::write(dir.join("claude"), choice).unwrap();
        assert!(!without_sign_in(&m, &[]), "{choice:?}");
    }
    // The fix it names writes exactly the choice `opted_in` reads.
    std::fs::write(dir.join("claude"), "team\n").unwrap();
    let home = m.home.clone();
    let var = |k: &str| (k == "HOME").then(|| home.to_string_lossy().into_owned());
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    assert!(opted_in(&inputs, "CMUX_CLAUDE_AUTH", "claude"));
    let text = no_sign_in();
    assert!(text.contains(
        "`mkdir -p ~/.config/cmux/agent-auth && echo team > ~/.config/cmux/agent-auth/claude`"
    ));
    assert!(text.starts_with("This machine is joined to your team but has no Claude sign-in"));
}

/// An opted-in launch that keeps own on purpose (a pair of its own, an `own` pin over the
/// choice) is no decline; one with neither that got no pair is the hub's host.
#[test]
fn an_opted_in_launch_keeps_own_only_on_purpose() {
    let m = machine(false);
    let own = |var: &[(&str, &str)]| {
        let mut env: BTreeMap<String, String> =
            var.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        env.insert("HOME".to_owned(), m.home.to_string_lossy().into_owned());
        let map = env.clone();
        let var = move |k: &str| map.get(k).cloned();
        let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
        crate::claude_cloud_auth::joined_own_reason(&inputs, &env, None, &m.home)
    };
    assert_eq!(own(&[("CMUX_CLAUDE_AUTH", "team")]), None);
    assert_eq!(
        own(&[
            ("CMUX_CLAUDE_AUTH", "team"),
            ("ANTHROPIC_BASE_URL", "https://x.test"),
            ("ANTHROPIC_AUTH_TOKEN", "t"),
        ]),
        Some("the launch sets ANTHROPIC_BASE_URL itself")
    );
    assert_eq!(
        own(&[("CMUX_CLAUDE_AUTH", "team"), ("ANTHROPIC_API_KEY", "sk-own")]),
        Some("the launch sets ANTHROPIC_API_KEY itself")
    );
    assert_eq!(own(&[("CMUX_CLAUDE_AUTH", "own")]), Some("CMUX_CLAUDE_AUTH pins own"));
    let text = declined_text("claude", "revoked: run machine add again");
    assert_eq!(
        text,
        "This launch chose your team's model route (`team` in CMUX_CLAUDE_AUTH or \
~/.config/cmux/agent-auth/claude), but this joined machine cannot use it: revoked: run machine \
add again."
    );
}
