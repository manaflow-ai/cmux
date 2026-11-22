//! Live model lists from Claude Code's and Codex's own CLIs
//! (`acpmux::live_models`), against fakes that speak each CLI's protocol:
//! tests/fake_live_claude.py (stream-json control requests) and
//! tests/fake_codex_app_server.py (`codex app-server` JSON-RPC lines).

use acpmux::live_models::{Cache, CacheKey, Cli, LiveModel, probe};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn fake(name: &str) -> Vec<String> {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join(name);
    vec!["python3".to_owned(), script.to_string_lossy().into_owned()]
}

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-live-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn ids(models: &[LiveModel]) -> Vec<&str> {
    models.iter().map(|m| m.id.as_str()).collect()
}

const DEADLINE: Duration = Duration::from_secs(10);

#[tokio::test]
async fn claude_lists_its_models_with_efforts_and_fast_mode() {
    let cwd = scratch("claude");
    let started = Instant::now();
    let models = probe(Cli::Claude, &fake("fake_live_claude.py"), &env(&[]), &cwd, DEADLINE)
        .await
        .unwrap_or_else(|e| panic!("{e:#}"));
    eprintln!("live claude probe (cold): {} ms", started.elapsed().as_millis());
    // No "default" row, no disabled model, no update notice.
    assert_eq!(ids(&models), ["opus", "sonnet[1m]", "claude-opus-5"]);
    let opus = &models[0];
    assert_eq!(opus.name, "Opus 5.5", "a description that extends the name wins");
    assert_eq!(opus.efforts, ["low", "medium", "high", "xhigh", "max"]);
    assert_eq!(opus.fast, Some(true));
    // supportsEffort without levels: Claude Code's usual four.
    assert_eq!(models[1].efforts, ["low", "medium", "high", "max"]);
    assert_eq!(models[1].name, "Sonnet (1M context)");
    assert_eq!(models[2].fast, Some(false));
}

#[tokio::test]
async fn an_older_claude_code_without_list_models_answers_from_initialize() {
    let cwd = scratch("claude-old");
    let models = probe(
        Cli::Claude,
        &fake("fake_live_claude.py"),
        &env(&[("FAKE_LIST", "refuse")]),
        &cwd,
        DEADLINE,
    )
    .await
    .unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(ids(&models), ["opus"]);
}

#[tokio::test]
async fn codex_lists_every_page_without_hidden_models_and_the_default_first() {
    let cwd = scratch("codex");
    let started = Instant::now();
    let models = probe(Cli::Codex, &fake("fake_codex_app_server.py"), &env(&[]), &cwd, DEADLINE)
        .await
        .unwrap_or_else(|e| panic!("{e:#}"));
    eprintln!("live codex probe (cold): {} ms", started.elapsed().as_millis());
    assert_eq!(ids(&models), ["gpt-6.1-sol", "gpt-6-astra"]);
    let (sol, astra) = (&models[0], &models[1]);
    assert!(sol.is_default);
    assert_eq!(sol.efforts, ["low", "high"]);
    assert_eq!(sol.fast, Some(false), "only the default tier: no fast mode");
    assert_eq!(astra.name, "GPT-6-Astra");
    assert_eq!(astra.efforts, ["low", "medium"]);
    assert_eq!(astra.default_effort.as_deref(), Some("medium"));
    assert_eq!(astra.fast, Some(true));
}

#[tokio::test]
async fn a_signed_out_codex_reports_why() {
    let cwd = scratch("codex-unauth");
    let err = probe(
        Cli::Codex,
        &fake("fake_codex_app_server.py"),
        &env(&[("FAKE_CODEX", "unauth")]),
        &cwd,
        DEADLINE,
    )
    .await
    .expect_err("a signed-out Codex has no list");
    assert!(format!("{err:#}").contains("Not logged in"), "{err:#}");
}

#[tokio::test]
async fn a_cli_that_never_answers_ends_at_the_deadline() {
    let cwd = scratch("codex-hang");
    let started = Instant::now();
    let err = probe(
        Cli::Codex,
        &fake("fake_codex_app_server.py"),
        &env(&[("FAKE_CODEX", "hang")]),
        &cwd,
        Duration::from_millis(400),
    )
    .await
    .expect_err("no answer, no list");
    assert!(format!("{err:#}").contains("did not arrive"), "{err:#}");
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
}

#[tokio::test]
async fn probes_run_side_by_side() {
    let cwd = scratch("parallel");
    let slow = env(&[("FAKE_DELAY", "0.6")]);
    let (claude_argv, codex_argv) = (fake("fake_live_claude.py"), fake("fake_codex_app_server.py"));
    let started = Instant::now();
    let (claude, codex) = tokio::join!(
        probe(Cli::Claude, &claude_argv, &slow, &cwd, DEADLINE),
        probe(Cli::Codex, &codex_argv, &slow, &cwd, DEADLINE),
    );
    let took = started.elapsed();
    eprintln!("claude + codex probes side by side, 0.6 s per answer: {} ms", took.as_millis());
    assert!(claude.is_ok() && codex.is_ok());
    // Claude writes 2 answers (1.2 s), Codex 4 lines (2.4 s); in a row they take 3.6 s.
    assert!(took < Duration::from_millis(3200), "the probes waited for each other: {took:?}");
}

#[test]
fn a_cached_list_lasts_until_its_program_changes() {
    let root = scratch("cache");
    let program = root.join("claude");
    std::fs::write(&program, "v1").unwrap();
    let cache = Cache::new(root.join("live-models"));
    let models = vec![LiveModel {
        id: "opus".into(),
        name: "Opus".into(),
        efforts: vec!["high".into()],
        default_effort: None,
        fast: Some(true),
        is_default: false,
    }];
    let key = CacheKey::of(&program).unwrap();
    cache.store("claude", &key, &models).unwrap();
    let started = Instant::now();
    assert_eq!(cache.load("claude", Some(&program)), Some(models.clone()));
    assert_eq!(cache.load_all().get("claude"), Some(&models));
    eprintln!("cached live list read: {} us", started.elapsed().as_micros());
    // A CLI update (another binary) discards it.
    std::fs::write(&program, "version two").unwrap();
    assert_eq!(cache.load("claude", Some(&program)), None);
    assert!(cache.load_all().is_empty());
}
