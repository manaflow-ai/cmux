use super::{
    DELIVERED, allowed, delivered_names_in, is_secret, machine_files_stamp_in, startup_files,
    storable,
};

/// A delivered name is not on the allow-list itself: only the local
/// spawn paths (`pairs_for`) add it, so nested-session restoration and
/// remote-origin launches, which go through `allowed`, never get it.
#[test]
fn delivered_names_stay_off_the_allow_list() {
    let before = std::mem::replace(
        &mut *DELIVERED.write().unwrap(),
        vec!["CLAUDE_CODE_OAUTH_TOKEN".into(), "DEMO_KEY".into()],
    );
    assert!(!allowed("DEMO_KEY", "dummy", None));
    assert!(!allowed("DEMO_KEY", "dummy", Some("codex")));
    assert!(!allowed("CLAUDE_CODE_OAUTH_TOKEN", "dummy", None));
    *DELIVERED.write().unwrap() = before;
}

/// Gemini and Muse credentials follow their ACP harness across the
/// daemon-to-agent boundary, while staying scoped away from other agents.
/// A provider key with one owning family besides the multi-provider
/// harnesses (`foreign_login::provider_key_owner`) comes from the login
/// shell for that family, as it stays in the daemon's env for it, and for
/// no other single-agent family.
#[test]
fn a_provider_key_reaches_its_own_family_from_the_login_shell() {
    for (key, own) in [
        ("AZURE_OPENAI_API_KEY", "codex"),
        ("XAI_API_KEY", "grok"),
        ("DEEPSEEK_API_KEY", "deepseek"),
        ("OPENAI_BASE_URL", "codex"),
        ("ANTHROPIC_BASE_URL", "claude"),
        ("GOOGLE_API_KEY", "gemini"),
    ] {
        assert!(allowed(key, "dummy", Some(own)), "{own} gets {key}");
        for other in ["claude", "codex", "gemini", "grok", "deepseek", "muse"] {
            if other != own && !(other == "gemini" && key.starts_with("GOOGLE_")) {
                assert!(!allowed(key, "dummy", Some(other)), "{other} never gets {key}");
            }
        }
    }
    // Every owned key, by the one table both sides read.
    for key in super::PROVIDER_KEYS {
        if let Some(own) = crate::agent::foreign_login::provider_key_owner(key) {
            assert!(allowed(key, "dummy", Some(own)), "{own} gets {key}");
        }
    }
}

#[test]
fn provider_credentials_are_scoped_to_gemini_and_muse() {
    assert!(allowed("GEMINI_API_KEY", "secret", Some("gemini")));
    assert!(allowed("GOOGLE_API_KEY", "secret", Some("gemini")));
    assert!(allowed("MUSE_API_KEY", "secret", Some("muse")));
    assert!(allowed("META_API_KEY", "secret", Some("muse")));
    assert!(!allowed("MUSE_API_KEY", "secret", Some("gemini")));
    assert!(!allowed("META_API_KEY", "secret", Some("claude")));
}

/// A multi-provider harness waits for the shell read that fetches its
/// keys, at most `TIMEOUT`, and goes on as soon as a read ends; another
/// family never waits.
#[tokio::test(start_paused = true)]
async fn a_provider_harness_waits_for_the_read_that_fetches_its_keys() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    let start = tokio::time::Instant::now();
    super::wait_while(|| true, super::TIMEOUT).await;
    assert_eq!(start.elapsed(), super::TIMEOUT, "the wait is bounded");
    let pending = Arc::new(AtomicBool::new(true));
    let read = pending.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        read.store(false, Ordering::SeqCst);
        super::READ_ENDED.notify_waiters();
    });
    let start = tokio::time::Instant::now();
    let waiting = pending.clone();
    super::wait_while(move || waiting.load(Ordering::SeqCst), super::TIMEOUT).await;
    let waited = start.elapsed();
    assert_eq!(waited, std::time::Duration::from_millis(200), "it goes on when the read ends");
}

/// Which names a spawn waits for after a cached start, from its final env
/// plan: a multi-provider harness any provider key or base URL; Claude and
/// Codex the base URL they read, never a key (their own wait is
/// `Plan::wait`); a reference always; never a name the plan sets or
/// removes (a route's unset), nor anything on a remote-origin plan.
#[test]
fn a_spawn_waits_only_for_values_its_plan_takes_from_the_shell() {
    use super::ChildEnv;
    use std::collections::BTreeMap;
    let plan = |family, profile, remote, explicit: &[(&str, Option<&str>)]| ChildEnv {
        family,
        profile,
        remote,
        explicit: Some(
            explicit.iter().map(|(k, v)| (k.to_string(), v.map(str::to_owned))).collect(),
        ),
    };
    let takes = |p: &ChildEnv, name: &str| p.takes(name, &p.refs());
    for family in ["opencode", "opencode-v2", "pi", "prime", "cmux-harness", "hermes"] {
        for key in ["OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_BASE_URL"] {
            assert!(takes(&plan(family, None, false, &[]), key), "{family} waits for {key}");
        }
    }
    assert!(takes(&plan("claude", None, false, &[]), "ANTHROPIC_BASE_URL"));
    assert!(takes(&plan("codex", None, false, &[]), "OPENAI_BASE_URL"));
    for (family, key) in [
        ("claude", "OPENAI_BASE_URL"),
        ("claude", "ANTHROPIC_API_KEY"),
        ("claude", "ANTHROPIC_AUTH_TOKEN"),
        ("claude", "OPENROUTER_API_KEY"),
        ("codex", "ANTHROPIC_BASE_URL"),
        ("codex", "OPENAI_API_KEY"),
        ("gemini", "OPENAI_BASE_URL"),
        ("gemini", "GOOGLE_API_KEY"),
        ("deepseek", "OPENAI_BASE_URL"),
        ("opencode", "GITHUB_TOKEN"),
    ] {
        assert!(!takes(&plan(family, None, false, &[]), key), "{family} never waits for {key}");
    }
    // A route that unsets it (codex-login), or a profile that sets it: never.
    let route: BTreeMap<String, String> =
        [(crate::routes::UNSET_KEY.to_owned(), "OPENAI_API_KEY,OPENAI_BASE_URL".to_owned())].into();
    let unset = plan("codex", Some(&route), false, &[("OPENAI_BASE_URL", None)]);
    assert!(!takes(&unset, "OPENAI_BASE_URL"));
    // An Anthropic endpoint harness clears the Claude provider env it does not set.
    let own: BTreeMap<String, String> =
        [(crate::byo_endpoint::OWN_ENDPOINT_KEY.to_owned(), "anthropic".to_owned())].into();
    let cleared = plan("claude", Some(&own), false, &[("ANTHROPIC_BASE_URL", None)]);
    assert!(!takes(&cleared, "ANTHROPIC_BASE_URL"));
    // A scrub is not an unset: the nested-session scrub (a daemon started
    // inside a Claude Code turn) removes the inherited ANTHROPIC_BASE_URL,
    // and the login import puts the person's own back, so a cached start
    // still waits for it.
    let scrubbed = plan("claude", None, false, &[("ANTHROPIC_BASE_URL", None)]);
    assert!(takes(&scrubbed, "ANTHROPIC_BASE_URL"));
    let scrubbed = plan("pi", None, false, &[("OPENROUTER_API_KEY", None)]);
    assert!(takes(&scrubbed, "OPENROUTER_API_KEY"));
    let set = plan("claude", None, false, &[("ANTHROPIC_BASE_URL", Some("https://r.invalid"))]);
    assert!(!takes(&set, "ANTHROPIC_BASE_URL"));
    // A remote-origin plan takes no login value.
    assert!(!takes(&plan("codex", None, true, &[]), "OPENAI_BASE_URL"));
    assert!(!takes(&plan("pi", None, true, &[]), "OPENROUTER_API_KEY"));
    // A `${env:X}` reference needs X, whatever the family, name or plan.
    let refs: BTreeMap<String, String> = [
        ("ANTHROPIC_BASE_URL".to_owned(), "${env:ANTHROPIC_BASE_URL}".to_owned()),
        ("TEAM_HEADER".to_owned(), "Bearer ${env:TEAM_GATEWAY_TOKEN}".to_owned()),
    ]
    .into();
    let by_ref = plan("claude", Some(&refs), true, &[("ANTHROPIC_BASE_URL", Some("x"))]);
    assert!(takes(&by_ref, "ANTHROPIC_BASE_URL"));
    assert!(takes(&by_ref, "TEAM_GATEWAY_TOKEN"));
    assert!(!takes(&by_ref, "OTHER_TOKEN"));
    // Not built yet (a reference missing): only references.
    let unbuilt = ChildEnv { explicit: None, ..plan("claude", Some(&refs), false, &[]) };
    assert!(takes(&unbuilt, "TEAM_GATEWAY_TOKEN"));
    assert!(!takes(&plan("pi", None, false, &[]), "GITHUB_TOKEN"));
}

/// A read that ends between building a command and checking its plan
/// left the command with the values from before it: it is built again.
#[tokio::test]
async fn a_command_built_while_a_read_ended_is_built_again() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let builds = AtomicUsize::new(0);
    let mut plan = super::ChildEnv { family: "pi", profile: None, remote: false, explicit: None };
    let built = super::build_ready(
        &mut plan,
        || {
            let n = builds.fetch_add(1, Ordering::SeqCst);
            if n == 0 {
                // The shell read ends after this build took its values.
                super::READS.fetch_add(1, Ordering::SeqCst);
                super::READ_ENDED.notify_waiters();
            }
            Ok::<_, String>(n)
        },
        |_| Vec::new(),
        |e| e,
    )
    .await
    .unwrap();
    assert_ne!(built, 0, "the command built before the read ended is not the one started");
}

/// A plain base URL is cached by value; one with a credential in its
/// userinfo or query is a secret, kept by name only.
#[test]
fn only_a_base_url_with_a_credential_is_a_secret() {
    for url in ["https://gateway.example/v1", "http://127.0.0.1:11434/v1", "https://api.example"] {
        assert!(!is_secret("ANTHROPIC_BASE_URL", url), "{url}");
        assert!(!is_secret("OPENAI_BASE_URL", url), "{url}");
    }
    for url in [
        "https://user:pass@gateway.example/v1",
        "https://gateway.example/v1?api_key=s3cret",
        "https://gateway.example/v1?token=s3cret",
    ] {
        assert!(is_secret("ANTHROPIC_BASE_URL", url), "{url}");
    }
}

/// A provider key exported in the login shell reaches the harnesses that
/// sign in with any provider's key (OpenCode, pi and its forks, cmux
/// Harness, Hermes) and no other family; it is kept as a secret, and no
/// other token comes in with it.
#[test]
fn provider_keys_reach_multi_provider_harnesses_only() {
    const KEYS: [&str; 14] = [
        "OPENROUTER_API_KEY",
        "GROQ_API_KEY",
        "TOGETHER_API_KEY",
        "FIREWORKS_API_KEY",
        "DEEPSEEK_API_KEY",
        "MISTRAL_API_KEY",
        "XAI_API_KEY",
        "CEREBRAS_API_KEY",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GOOGLE_GENERATIVE_AI_API_KEY",
        "HF_TOKEN",
    ];
    for family in ["opencode", "opencode-v2", "pi", "omp", "prime", "cmux-harness", "hermes"] {
        for key in KEYS {
            assert!(allowed(key, "dummy", Some(family)), "{family} gets {key}");
        }
        assert!(allowed("OPENAI_BASE_URL", "http://127.0.0.1:11434/v1", Some(family)));
        assert!(allowed("ANTHROPIC_BASE_URL", "https://gateway.example", Some(family)));
        // Explicit names only: no prefix, and no other token.
        for key in [
            "OPENROUTER_REFERER_TOKEN",
            "GROQ_SECRET",
            "OPENAI_ORG_TOKEN",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CODEX_API_KEY",
            "GITHUB_TOKEN",
            "GH_TOKEN",
            "NPM_TOKEN",
            "AWS_SECRET_ACCESS_KEY",
            "STRIPE_API_KEY",
        ] {
            assert!(!allowed(key, "dummy", Some(family)), "{family} never gets {key}");
        }
    }
    // Every other family keeps its own list.
    for key in ["OPENROUTER_API_KEY", "GROQ_API_KEY", "DEEPSEEK_API_KEY", "HF_TOKEN"] {
        for family in [None, Some("claude"), Some("codex"), Some("gemini"), Some("muse")] {
            assert!(!allowed(key, "dummy", family), "{family:?} never gets {key}");
        }
        for family in ["chief", "unii", "cursor", "deepseek", "fake"] {
            // DeepSeek Harness gets only its own key (`foreign_login::provider_key_owner`).
            if family == "deepseek" && key == "DEEPSEEK_API_KEY" {
                continue;
            }
            assert!(!allowed(key, "dummy", Some(family)), "{family} never gets {key}");
        }
    }
    assert!(!allowed("OPENAI_API_KEY", "dummy", Some("claude")));
    assert!(!allowed("ANTHROPIC_API_KEY", "dummy", Some("codex")));
    // Kept in memory as secrets: their names, never their values, reach the cache.
    for key in KEYS {
        assert!(storable(key, "dummy"), "{key} is kept");
        assert!(is_secret(key, "dummy"), "{key} is a secret");
    }
    assert!(storable("OPENAI_BASE_URL", "http://127.0.0.1:11434/v1"));
    assert!(!storable("GITHUB_TOKEN", "dummy"));
    assert!(!storable("STRIPE_API_KEY", "dummy"));
}

/// Only the names of a delivered file, in the receiver's format; a link
/// or a missing file names nothing.
#[test]
fn delivered_names_reads_only_export_names() {
    let dir = tempfile::tempdir().expect("temp home");
    let conf = dir.path().join(".config/cmux");
    std::fs::create_dir_all(&conf).expect("config dir");
    assert!(delivered_names_in(dir.path()).is_empty());
    let secrets = conf.join("machine-secrets.env");
    std::fs::write(
            &secrets,
            b"export DEMO_KEY='dummy-1'\nexport _OTHER2='a=b'\nexport 9BAD='x'\n# export NOTE='x'\nexport DEMO_KEY='dummy-2'\n",
        )
        .expect("deliver");
    assert_eq!(delivered_names_in(dir.path()), vec!["DEMO_KEY", "_OTHER2"]);
    #[cfg(unix)]
    {
        let real = dir.path().join("elsewhere.env");
        std::fs::rename(&secrets, &real).expect("move");
        std::os::unix::fs::symlink(&real, &secrets).expect("link");
        assert!(delivered_names_in(dir.path()).is_empty());
    }
}

#[test]
fn login_watch_includes_delivered_machine_files() {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .or_else(dirs::home_dir)
        .unwrap_or_default();
    let watched = startup_files();
    for name in ["machine.env", "machine-secrets.env"] {
        assert!(watched.contains(&home.join(".config/cmux").join(name)));
    }
}

#[test]
fn stamp_changes_for_delivery_rotation_and_revocation() {
    let dir = tempfile::tempdir().expect("temp home");
    let conf = dir.path().join(".config/cmux");
    std::fs::create_dir_all(&conf).expect("config dir");
    let env = conf.join("machine.env");
    let secrets = conf.join("machine-secrets.env");
    assert_eq!(machine_files_stamp_in(dir.path()), None);
    std::fs::write(&env, b"export RUN_MODE='dev'\n").expect("write machine env");
    let applied = machine_files_stamp_in(dir.path());
    assert!(applied.is_some());
    std::fs::write(&secrets, b"export SESSION_KEY='dummy-secret-1'\n").expect("deliver");
    let delivered = machine_files_stamp_in(dir.path());
    assert_ne!(delivered, applied);
    std::fs::write(&secrets, b"export SESSION_KEY='different-dummy-secret'\n").expect("rotate");
    let rotated = machine_files_stamp_in(dir.path());
    assert_ne!(rotated, delivered);
    #[cfg(unix)]
    {
        // Atomic replace with the same size changes the file identity.
        let next = conf.join("replacement");
        std::fs::write(&next, b"export SESSION_KEY='same-length-secret-001'\n")
            .expect("prepare replacement");
        let before = machine_files_stamp_in(dir.path());
        assert_eq!(
            std::fs::metadata(&next).expect("replacement").len(),
            std::fs::metadata(&secrets).expect("old value").len(),
        );
        std::fs::rename(&next, &secrets).expect("atomic replace");
        assert_ne!(machine_files_stamp_in(dir.path()), before);
    }
    std::fs::remove_file(&secrets).expect("revoke");
    assert_eq!(machine_files_stamp_in(dir.path()), applied);
    std::fs::remove_file(&env).expect("remove machine env");
    assert_eq!(machine_files_stamp_in(dir.path()), None);
}
