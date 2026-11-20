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

fn machine(kind: &str) -> Machine {
    static N: AtomicU32 = AtomicU32::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let root =
        std::env::temp_dir().join(format!("acpmux-provider-cloud-auth-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
    std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    std::fs::write(
        root.join("etc/cmux/model-plane.env"),
        "export CMUX_CODEROUTER_URL='https://coderouter.cmux.internal'\n",
    )
    .unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    Machine { root, home }
}

const BOTH: Providers = Providers { gemini: true, xai: true };

async fn mode(m: &Machine, p: Provider, var: &[(&str, &str)], probe: Option<Providers>) -> Mode {
    let map: BTreeMap<String, String> =
        var.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    let var = move |k: &str| map.get(k).cloned();
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    decide(p, &inputs, |origin| async move {
        assert_eq!(origin, "https://coderouter.cmux.internal");
        probe
    })
    .await
}

fn team(p: Provider) -> Mode {
    Mode::Team(p.team_env("https://coderouter.cmux.internal"))
}

#[tokio::test]
async fn team_mode_injects_exactly_the_gateway_vars() {
    let m = machine("owner");
    let got = mode(&m, Provider::Grok, &[], Some(BOTH)).await;
    assert_eq!(
        got,
        Mode::Team(vec![
            (
                "GROK_MODELS_BASE_URL".to_owned(),
                "https://coderouter.cmux.internal/xai/v1".to_owned()
            ),
            (
                // Grok CLI's key probe and turns go to the gateway too, or its ACP
                // `session/new` refuses the placeholder key (#43857).
                "GROK_XAI_API_BASE_URL".to_owned(),
                "https://coderouter.cmux.internal/xai/v1".to_owned()
            ),
            ("XAI_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()),
        ])
    );
    let got = mode(&m, Provider::Gemini, &[], Some(BOTH)).await;
    assert_eq!(
        got,
        Mode::Team(vec![
            ("GOOGLE_GEMINI_BASE_URL".to_owned(), "https://coderouter.cmux.internal".to_owned()),
            ("GEMINI_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()),
        ])
    );
    // Every name a team launch sets is one a sign-in never sees.
    for p in [Provider::Gemini, Provider::Grok] {
        for (k, _) in p.team_env("https://o") {
            assert!(crate::agent_login::MODEL_PLANE_ENV.contains(&k.as_str()), "{k}");
        }
    }
    // apply_team puts them over the launch's own values.
    let mut env = BTreeMap::from([("XAI_API_KEY".to_owned(), "cmux-secret://x".to_owned())]);
    let Mode::Team(vars) = team(Provider::Grok) else { unreachable!() };
    apply_team(&mut env, vars);
    assert_eq!(env["XAI_API_KEY"], PLACEHOLDER_KEY);
    assert_eq!(env.len(), 3);
}

#[tokio::test]
async fn an_own_login_keeps_own_mode() {
    let m = machine("owner");
    std::fs::create_dir_all(m.home.join(".gemini")).unwrap();
    std::fs::write(m.home.join(".gemini/oauth_creds.json"), "{}").unwrap();
    assert_eq!(mode(&m, Provider::Gemini, &[], Some(BOTH)).await, Mode::Own("login"));
    std::fs::create_dir_all(m.home.join(".grok")).unwrap();
    std::fs::write(m.home.join(".grok/auth.json"), r#"{"t":"x"}"#).unwrap();
    assert_eq!(mode(&m, Provider::Grok, &[], Some(BOTH)).await, Mode::Own("login"));
    // GROK_HOME moves the store: an empty one there is no sign-in.
    let other = m.root.join("grok-home");
    std::fs::create_dir_all(&other).unwrap();
    let home = other.to_string_lossy().into_owned();
    assert_eq!(
        mode(&m, Provider::Grok, &[("GROK_HOME", &home)], Some(BOTH)).await,
        team(Provider::Grok)
    );
    // A recorded `team` choice, or the env pin, wins over the sign-in.
    let dir = m.home.join(".config/cmux/agent-auth");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("grok"), "team\n").unwrap();
    assert_eq!(mode(&m, Provider::Grok, &[], Some(BOTH)).await, team(Provider::Grok));
    std::fs::write(dir.join("grok"), "own\n").unwrap();
    assert_eq!(mode(&m, Provider::Grok, &[], Some(BOTH)).await, Mode::Own("chosen"));
    assert_eq!(
        mode(&m, Provider::Grok, &[("CMUX_GROK_AUTH", "team")], Some(BOTH)).await,
        team(Provider::Grok)
    );
    assert_eq!(
        mode(&m, Provider::Gemini, &[("CMUX_GEMINI_AUTH", "own")], Some(BOTH)).await,
        Mode::Own("env")
    );
}

#[tokio::test]
async fn a_real_env_key_keeps_own_mode_and_a_placeholder_does_not() {
    let m = machine("owner");
    for (p, k) in [
        (Provider::Gemini, "GEMINI_API_KEY"),
        (Provider::Gemini, "GOOGLE_API_KEY"),
        (Provider::Grok, "XAI_API_KEY"),
        (Provider::Grok, "GROK_CODE_XAI_API_KEY"),
    ] {
        assert_eq!(mode(&m, p, &[(k, "real-key-123")], Some(BOTH)).await, Mode::Own("key"));
        assert_eq!(mode(&m, p, &[(k, PLACEHOLDER_KEY)], Some(BOTH)).await, team(p), "{k}");
        assert_eq!(
            mode(&m, p, &[(k, "cmux-secret://vault/XAI_API_KEY")], Some(BOTH)).await,
            team(p),
            "{k}"
        );
        assert_eq!(mode(&m, p, &[(k, "")], Some(BOTH)).await, team(p), "{k}");
    }
    // A key in Gemini's own `.env` is its sign-in.
    std::fs::create_dir_all(m.home.join(".gemini")).unwrap();
    std::fs::write(m.home.join(".gemini/.env"), "GEMINI_API_KEY=real\n").unwrap();
    assert_eq!(mode(&m, Provider::Gemini, &[], Some(BOTH)).await, Mode::Own("login"));
}

#[tokio::test]
async fn a_persons_own_endpoint_or_auth_choice_keeps_own_mode() {
    let m = machine("owner");
    for (p, k, v) in [
        (Provider::Gemini, "GOOGLE_GEMINI_BASE_URL", "https://proxy.example.test"),
        (Provider::Gemini, "GOOGLE_GENAI_USE_VERTEXAI", "true"),
        (Provider::Gemini, "GOOGLE_GENAI_USE_GCA", "TRUE"),
        (Provider::Grok, "GROK_MODELS_BASE_URL", "https://proxy.example.test/v1"),
        (Provider::Grok, "GROK_XAI_API_BASE_URL", "https://proxy.example.test/v1"),
    ] {
        assert_eq!(mode(&m, p, &[(k, v)], Some(BOTH)).await, Mode::Own("endpoint"), "{k}");
    }
    assert_eq!(
        mode(&m, Provider::Gemini, &[("GOOGLE_GENAI_USE_VERTEXAI", "false")], Some(BOTH)).await,
        team(Provider::Gemini)
    );
    let settings = m.home.join(".gemini/settings.json");
    std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
    for (body, own) in [
        (r#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#, true),
        (r#"{"selectedAuthType":"vertex-ai"}"#, true),
        (r#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#, false),
        (r#"{"security":{"auth":{"selectedType":"gateway"}}}"#, false),
        (r#"{"theme":"dark"}"#, false),
    ] {
        std::fs::write(&settings, body).unwrap();
        let want = if own { Mode::Own("endpoint") } else { team(Provider::Gemini) };
        assert_eq!(mode(&m, Provider::Gemini, &[], Some(BOTH)).await, want, "{body}");
    }
}

#[tokio::test]
async fn a_probe_that_fails_or_says_false_keeps_own_mode() {
    let m = machine("owner");
    assert_eq!(mode(&m, Provider::Grok, &[], None).await, Mode::Own("probe-failed"));
    let gemini_only = Providers { gemini: true, xai: false };
    assert_eq!(mode(&m, Provider::Grok, &[], Some(gemini_only)).await, Mode::Own("not-served"));
    assert_eq!(mode(&m, Provider::Gemini, &[], Some(gemini_only)).await, team(Provider::Gemini));
    // No https origin: nowhere to send, and the probe is never asked.
    std::fs::write(m.root.join("etc/cmux/model-plane.env"), "export CMUX_CODEROUTER_URL=''\n")
        .unwrap();
    let var = |_: &str| -> Option<String> { None };
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    let never = |_: String| -> std::future::Ready<Option<Providers>> { panic!("probed") };
    let got = decide(Provider::Grok, &inputs, never).await;
    assert_eq!(got, Mode::Own("no-team-plane"));
}

#[tokio::test]
async fn a_team_machine_or_another_box_is_left_alone() {
    assert_eq!(mode(&machine("team"), Provider::Grok, &[], Some(BOTH)).await, Mode::LeftAlone);
    let plain = machine("owner");
    std::fs::remove_file(plain.root.join("etc/cmux/agent-auth.sh")).unwrap();
    assert_eq!(mode(&plain, Provider::Gemini, &[], Some(BOTH)).await, Mode::LeftAlone);
}

/// The view a launch's own-key check reads, with no daemon or login value but `HOME`.
fn launch(
    m: &Machine,
    p: Provider,
    vault: &[(&str, &str)],
    machine: &[(&str, &str)],
    pending: &[&str],
) -> LaunchEnv {
    launch_from(m, p, vault, machine, pending, false)
}

/// [`launch`], local or `remote`-origin.
fn launch_from(
    m: &Machine,
    p: Provider,
    vault: &[(&str, &str)],
    machine: &[(&str, &str)],
    pending: &[&str],
    remote: bool,
) -> LaunchEnv {
    let pairs = |v: &[(&str, &str)]| -> Vec<(String, String)> {
        v.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    };
    let daemon = BTreeMap::from([("HOME".to_owned(), m.home.to_string_lossy().into_owned())]);
    LaunchEnv::new(
        p.name(),
        BTreeMap::new(),
        daemon,
        pairs(vault),
        pairs(machine).into_iter().collect(),
        pending.iter().map(|n| (*n).to_owned()).collect(),
        remote,
    )
}

async fn launch_mode(m: &Machine, p: Provider, launch: &LaunchEnv) -> Mode {
    decide_launch(p, launch, &m.root, |origin| async move {
        assert_eq!(origin, "https://coderouter.cmux.internal");
        Some(BOTH)
    })
    .await
}

/// #43800: a key of the person's own that only the vault or `machine.env` holds, or one the
/// login shell sets that this daemon has not read yet, keeps own mode; the gateway's
/// placeholder never replaces it.
#[tokio::test]
async fn a_vault_or_machine_env_key_keeps_own_mode() {
    let m = machine("owner");
    for (p, k) in [
        (Provider::Gemini, "GEMINI_API_KEY"),
        (Provider::Gemini, "GOOGLE_API_KEY"),
        (Provider::Grok, "XAI_API_KEY"),
        (Provider::Grok, "GROK_CODE_XAI_API_KEY"),
    ] {
        // A vault entry the egress proxy fills: the launch holds its `cmux-secret://` name.
        let held = cmux_vault_egress::placeholder(k);
        let got = launch_mode(&m, p, &launch(&m, p, &[(k, &held)], &[], &[])).await;
        assert_eq!(got, Mode::Own("key"), "vault proxy {k}");
        // A vault entry delivered as its value.
        let got = launch_mode(&m, p, &launch(&m, p, &[(k, "real-key-123")], &[], &[])).await;
        assert_eq!(got, Mode::Own("key"), "vault value {k}");
        // `machine.env`, which `login_env::var` never shows.
        let got = launch_mode(&m, p, &launch(&m, p, &[], &[(k, "real-key-123")], &[])).await;
        assert_eq!(got, Mode::Own("key"), "machine.env {k}");
        // The login shell sets it; this daemon has not read it yet.
        let got = launch_mode(&m, p, &launch(&m, p, &[], &[], &[k])).await;
        assert_eq!(got, Mode::Own("key"), "pending {k}");
    }
}

/// #43800 review: a remote-origin launch (a Cloud chat the app starts through its peer link)
/// gets no vault, `machine.env` or login value (`agent/command.rs`), so a key held only there
/// is no key of its own: it goes to the team's gateway, never own mode with no key. A key in
/// its own profile still keeps own.
#[tokio::test]
async fn a_remote_launch_counts_only_the_key_it_gets() {
    let m = machine("owner");
    for (p, k) in [(Provider::Gemini, "GEMINI_API_KEY"), (Provider::Grok, "XAI_API_KEY")] {
        let held = cmux_vault_egress::placeholder(k);
        let cases: [(Vec<(&str, &str)>, Vec<(&str, &str)>, Vec<&str>); 4] = [
            (vec![(k, held.as_str())], vec![], vec![]),
            (vec![(k, "real-key-123")], vec![], vec![]),
            (vec![], vec![(k, "real-key-123")], vec![]),
            (vec![], vec![], vec![k]),
        ];
        for (vault, machine, pending) in cases {
            let env = launch_from(&m, p, &vault, &machine, &pending, true);
            assert_eq!(launch_mode(&m, p, &env).await, team(p), "remote {k}");
        }
        let mut env = launch_from(&m, p, &[], &[], &[], true);
        env.env.insert(k.to_owned(), "real-key-123".to_owned());
        assert_eq!(launch_mode(&m, p, &env).await, Mode::Own("key"), "remote profile {k}");
    }
}

/// No key anywhere, or only a reference nothing fills, still goes to the team's gateway.
#[tokio::test]
async fn no_own_key_anywhere_still_goes_to_team_mode() {
    let m = machine("owner");
    for p in [Provider::Gemini, Provider::Grok] {
        assert_eq!(launch_mode(&m, p, &launch(&m, p, &[], &[], &[])).await, team(p));
        let k = p.key_vars()[0];
        for v in [PLACEHOLDER_KEY, "cmux-secret://vault/XAI_API_KEY", ""] {
            let got = launch_mode(&m, p, &launch(&m, p, &[], &[(k, v)], &[])).await;
            assert_eq!(got, team(p), "machine.env {k}={v}");
            let got = launch_mode(&m, p, &launch(&m, p, &[(k, v)], &[], &[])).await;
            assert_eq!(got, team(p), "vault {k}={v}");
        }
        // The vault's placeholder for another name, and a secret the shell has not given yet
        // for an unrelated name.
        let other = cmux_vault_egress::placeholder("OTHER_API_KEY");
        let got = launch_mode(&m, p, &launch(&m, p, &[(k, &other)], &[], &[])).await;
        assert_eq!(got, team(p), "{k}={other}");
        let got = launch_mode(&m, p, &launch(&m, p, &[], &[], &["OTHER_API_KEY"])).await;
        assert_eq!(got, team(p));
    }
}

#[test]
fn the_probe_answer_is_two_booleans() {
    let v = serde_json::json!({"gemini": true, "xai": false});
    assert_eq!(parse_providers(&v), Some(Providers { gemini: true, xai: false }));
    assert_eq!(parse_providers(&serde_json::json!({"gemini": true})), None);
    assert_eq!(parse_providers(&serde_json::json!({"gemini": "yes", "xai": true})), None);
    assert_eq!(parse_providers(&serde_json::json!([])), None);
}

#[test]
fn only_the_agent_itself_and_its_family() {
    let argv = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert!(launches_itself(Provider::Gemini, &argv(&["/usr/bin/gemini", "--experimental-acp"])));
    assert!(launches_itself(Provider::Grok, &argv(&["grok", "agent", "stdio"])));
    assert!(!launches_itself(Provider::Grok, &argv(&["/usr/bin/wrapper", "grok"])));
    assert!(!launches_itself(Provider::Gemini, &[]));
    assert_eq!(Provider::for_family("gemini"), Some(Provider::Gemini));
    assert_eq!(Provider::for_family("grok"), Some(Provider::Grok));
    assert_eq!(Provider::for_family("claude"), None);
}

#[tokio::test]
async fn an_unreachable_origin_answers_none_within_the_deadline() {
    // A port nothing listens on: refused at once, never past the deadline, and cached.
    let started = Instant::now();
    let origin = "http://127.0.0.1:9".to_owned();
    assert_eq!(probe_providers(origin.clone()).await, None);
    assert!(started.elapsed() <= PROBE_DEADLINE + Duration::from_millis(500));
    assert!(PROBES.lock().unwrap().contains_key(&origin));
}
