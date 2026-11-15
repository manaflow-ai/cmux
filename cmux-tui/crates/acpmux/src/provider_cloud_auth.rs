//! Gemini's and Grok's sign-in mode on a cmux Cloud machine, for the launches acpmux makes itself
//! (hq#11225). Leo, 2026-11-15: "We're doing it through the gateway."
//!
//! A team in inference gateway mode serves these agents on the machine's edge origin, the same
//! origin Claude and Codex team mode use (`codex_cloud_auth::Inputs::team_origin`): Grok at
//! `<origin>/xai/v1/...`, Gemini at `<origin>/v1beta/models/...`. The guest sends the public
//! placeholder key; the edge adds the machine token, and the Worker answers with the team's key (or
//! the owner's own on a personal machine), else a 401 that says `agent.sign_in_required`
//! (`recovery::start_sign_in` and `claude_auth::is_sign_in_failure` type it as a sign-in).
//!
//! [`decide`] is `codex_cloud_auth::own_reason`'s rule for these two, on an owner machine with the
//! image's own-or-team script:
//!   env       `CMUX_GEMINI_AUTH` / `CMUX_GROK_AUTH` = `own|team` pins the launch;
//!   chosen    `~/.config/cmux/agent-auth/<agent>` holds `own` or `team` (`cr use`);
//!   login     no choice; the agent has its own sign-in (`agent_login::signed_in_at`);
//!   key       a key of its own in the launch's env: anything but the placeholder or a
//!             `cmux-secret://` reference;
//!   endpoint  the person points it somewhere themselves (a base URL, Gemini's Vertex or Google
//!             sign-in switches, a Gemini `selectedType` other than an API key or gateway);
//!   no-team-plane / probe-failed / not-served: no `https://` origin, or the origin's
//!             `GET /cmux/v1/providers` did not answer in time, or says false for this agent.
//! Otherwise team: [`Provider::team_env`] on the launch env only (never a login shell). A team
//! machine (vm-kind not `owner`) is left alone, as for Codex.
//!
//! Gemini CLI (0.67, `acpSessionManager.ts`): with no `selectedType`, a set
//! `GOOGLE_GEMINI_BASE_URL` picks its `gateway` auth for both `session/new` and `session/load`,
//! whose key is `GEMINI_API_KEY`, sent as `x-goog-api-key` to that base URL
//! (`contentGenerator.ts`). With `selectedType` `gemini-api-key` it uses the same two. Grok
//! (`11-custom-models.md`): `GROK_MODELS_BASE_URL` is its base URL for inference, `XAI_API_KEY`
//! sent as `Authorization: Bearer`.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::codex_cloud_auth::{Inputs, PLACEHOLDER_KEY};

/// An agent the gateway serves besides Claude and Codex.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    Gemini,
    Grok,
}

impl Provider {
    /// The provider of a launch's family (`config::derive_family`).
    pub fn for_family(family: &str) -> Option<Provider> {
        match family {
            "gemini" => Some(Provider::Gemini),
            "grok" => Some(Provider::Grok),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Provider::Gemini => "gemini",
            Provider::Grok => "grok",
        }
    }

    fn agent(self) -> crate::agent_login::Agent {
        match self {
            Provider::Gemini => crate::agent_login::Agent::Gemini,
            Provider::Grok => crate::agent_login::Agent::Grok,
        }
    }

    fn pin_var(self) -> &'static str {
        match self {
            Provider::Gemini => "CMUX_GEMINI_AUTH",
            Provider::Grok => "CMUX_GROK_AUTH",
        }
    }

    /// The env names whose value is a key of the person's own.
    fn key_vars(self) -> &'static [&'static str] {
        match self {
            Provider::Gemini => &["GEMINI_API_KEY", "GOOGLE_API_KEY"],
            Provider::Grok => &["XAI_API_KEY", "GROK_CODE_XAI_API_KEY"],
        }
    }

    /// The env names that point the agent somewhere of the person's choosing.
    fn endpoint_vars(self) -> &'static [&'static str] {
        match self {
            Provider::Gemini => &["GOOGLE_GEMINI_BASE_URL"],
            Provider::Grok => &["GROK_MODELS_BASE_URL", "GROK_MODELS_LIST_URL"],
        }
    }

    /// Where the agent keeps its sign-in (`agent_login::Cli::store`).
    fn store(self, inputs: &Inputs<'_>) -> PathBuf {
        let own = |k: &str| (inputs.var)(k).filter(|v| !v.is_empty()).map(PathBuf::from);
        match self {
            Provider::Gemini => {
                own("GEMINI_CLI_HOME").unwrap_or_else(|| inputs.home.to_owned()).join(".gemini")
            }
            Provider::Grok => own("GROK_HOME").unwrap_or_else(|| inputs.home.join(".grok")),
        }
    }

    /// The env a team-mode launch gains for `origin` (no trailing slash needed); every name is in
    /// `agent_login::MODEL_PLANE_ENV`, so a sign-in never sees one.
    pub fn team_env(self, origin: &str) -> Vec<(String, String)> {
        let origin = origin.trim_end_matches('/');
        let pair = |k: &str, v: String| (k.to_owned(), v);
        match self {
            Provider::Gemini => vec![
                pair("GOOGLE_GEMINI_BASE_URL", origin.to_owned()),
                pair("GEMINI_API_KEY", PLACEHOLDER_KEY.to_owned()),
            ],
            Provider::Grok => vec![
                pair("GROK_MODELS_BASE_URL", format!("{origin}/xai/v1")),
                pair("XAI_API_KEY", PLACEHOLDER_KEY.to_owned()),
            ],
        }
    }
}

/// A key of the person's own: set, not the placeholder every guest sends, not a vault reference.
fn own_key(value: &str) -> bool {
    let v = value.trim();
    !v.is_empty() && v != PLACEHOLDER_KEY && !v.starts_with("cmux-secret://")
}

/// Gemini's recorded auth choice (`settings.json` `security.auth.selectedType`, or the older
/// top-level `selectedAuthType`) when it is one team mode cannot use: anything but an API key or
/// the gateway. A file that does not read as JSON says nothing.
fn gemini_selects_another(store: &std::path::Path) -> bool {
    let Ok(text) = std::fs::read_to_string(store.join("settings.json")) else { return false };
    let Ok(settings) = serde_json::from_str::<serde_json::Value>(&text) else { return false };
    let selected = settings
        .pointer("/security/auth/selectedType")
        .or_else(|| settings.get("selectedAuthType"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    !matches!(selected, "" | "gemini-api-key" | "gateway")
}

/// What a launch does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    /// Not an owner cmux Cloud image: nothing here applies.
    LeftAlone,
    /// The agent keeps its own sign-in; the reason (module docs).
    Own(&'static str),
    /// The env to add to the launch.
    Team(Vec<(String, String)>),
}

/// What the probe found the gateway serves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Providers {
    pub gemini: bool,
    pub xai: bool,
}

impl Providers {
    fn serves(self, provider: Provider) -> bool {
        match provider {
            Provider::Gemini => self.gemini,
            Provider::Grok => self.xai,
        }
    }
}

/// The mode of one launch (module docs). `probe` asks the origin what it serves; it runs only
/// when nothing else decides, and None (no answer in time, any error) keeps own.
pub async fn decide<F, Fut>(provider: Provider, inputs: &Inputs<'_>, probe: F) -> Mode
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = Option<Providers>>,
{
    if !inputs.owner_cloud_image() {
        return Mode::LeftAlone;
    }
    let var = |k: &str| (inputs.var)(k).filter(|v| !v.is_empty());
    let pinned = match var(provider.pin_var()).as_deref().map(str::trim) {
        Some("own") => return Mode::Own("env"),
        Some("team") => true,
        _ => false,
    };
    let chosen = !pinned
        && match inputs.choice_for(provider.name()) {
            Some("own") => return Mode::Own("chosen"),
            Some(_) => true,
            None => false,
        };
    if !pinned && !chosen {
        let store = provider.store(inputs);
        if crate::agent_login::signed_in_at(provider.agent(), &store) {
            return Mode::Own("login");
        }
        if provider.key_vars().iter().any(|k| var(k).is_some_and(|v| own_key(&v))) {
            return Mode::Own("key");
        }
        let switched = provider == Provider::Gemini
            && (["GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA"]
                .iter()
                .any(|k| var(k).is_some_and(|v| v.trim().eq_ignore_ascii_case("true")))
                || gemini_selects_another(&store));
        if switched || provider.endpoint_vars().iter().any(|k| var(k).is_some()) {
            return Mode::Own("endpoint");
        }
    }
    let Some(origin) = inputs.team_origin() else { return Mode::Own("no-team-plane") };
    let origin = origin.trim_end_matches('/').to_owned();
    match probe(origin.clone()).await {
        None => Mode::Own("probe-failed"),
        Some(p) if !p.serves(provider) => Mode::Own("not-served"),
        Some(_) => Mode::Team(provider.team_env(&origin)),
    }
}

/// Put team mode in a launch's profile env: [`Provider::team_env`] over whatever it had.
pub fn apply_team(env: &mut BTreeMap<String, String>, team: Vec<(String, String)>) {
    env.extend(team);
}

/// The longest a start waits for the probe, DNS included.
// timeout: a Gemini or Grok start waits at most this for the gateway probe, then starts without it
pub const PROBE_DEADLINE: Duration = Duration::from_secs(1);
/// How long an answer is reused, and a failure.
const PROBE_TTL: Duration = Duration::from_secs(60);
// timeout: not a wait; a failed probe is retried after this cache age
const PROBE_FAILED_TTL: Duration = Duration::from_secs(10);

type ProbeCache = Mutex<HashMap<String, (Instant, Option<Providers>)>>;
static PROBES: std::sync::LazyLock<ProbeCache> = std::sync::LazyLock::new(Default::default);

/// `GET <origin>/cmux/v1/providers` through the machine's edge, at most [`PROBE_DEADLINE`],
/// reused for a minute (a failure for 10 s). None on any failure.
pub async fn probe_providers(origin: String) -> Option<Providers> {
    let now = Instant::now();
    if let Some((at, answer)) = PROBES.lock().unwrap_or_else(|e| e.into_inner()).get(&origin) {
        let ttl = if answer.is_some() { PROBE_TTL } else { PROBE_FAILED_TTL };
        if now.duration_since(*at) < ttl {
            return *answer;
        }
    }
    let answer =
        tokio::time::timeout(PROBE_DEADLINE, fetch_providers(&origin)).await.ok().flatten();
    PROBES.lock().unwrap_or_else(|e| e.into_inner()).insert(origin, (Instant::now(), answer));
    answer
}

async fn fetch_providers(origin: &str) -> Option<Providers> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder()
        // timeout: the Cloud gateway's provider probe, before a Gemini or Grok start
        .timeout(PROBE_DEADLINE)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .ok()?;
    let response = client
        .get(format!("{origin}/cmux/v1/providers"))
        .bearer_auth(PLACEHOLDER_KEY)
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: serde_json::Value = response.json().await.ok()?;
    parse_providers(&body)
}

/// The probe's answer, `{gemini: bool, xai: bool}`; None for any other shape.
fn parse_providers(body: &serde_json::Value) -> Option<Providers> {
    Some(Providers { gemini: body.get("gemini")?.as_bool()?, xai: body.get("xai")?.as_bool()? })
}

/// Whether `argv` starts the agent itself (`gemini`, `grok`), not a launcher that picks its
/// provider on its own.
pub fn launches_itself(provider: Provider, argv: &[String]) -> bool {
    argv.first()
        .and_then(|program| std::path::Path::new(program).file_name())
        .is_some_and(|name| name == provider.name())
}

#[cfg(test)]
mod tests {
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
        let root = std::env::temp_dir()
            .join(format!("acpmux-provider-cloud-auth-{}-{n}", std::process::id()));
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

    async fn mode(
        m: &Machine,
        p: Provider,
        var: &[(&str, &str)],
        probe: Option<Providers>,
    ) -> Mode {
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
                ("XAI_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()),
            ])
        );
        let got = mode(&m, Provider::Gemini, &[], Some(BOTH)).await;
        assert_eq!(
            got,
            Mode::Team(vec![
                (
                    "GOOGLE_GEMINI_BASE_URL".to_owned(),
                    "https://coderouter.cmux.internal".to_owned()
                ),
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
        assert_eq!(env.len(), 2);
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
        assert_eq!(
            mode(&m, Provider::Gemini, &[], Some(gemini_only)).await,
            team(Provider::Gemini)
        );
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
        assert!(launches_itself(
            Provider::Gemini,
            &argv(&["/usr/bin/gemini", "--experimental-acp"])
        ));
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
}
