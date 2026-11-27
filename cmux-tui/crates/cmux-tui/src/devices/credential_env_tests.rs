//! Every credential-like environment variable name in cmux-tui's Rust sources is either one no
//! `cmux` child inherits ([`super::CREDENTIAL_ENV`]) or one [`ALLOWED`] lets through on purpose,
//! with its reason. A new name that is neither fails here, so it is decided, not missed.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// Names a `cmux` child (`cmux acp`, the acpmux daemon it may start and the agents that daemon
/// runs) keeps on purpose, each group with why.
const ALLOWED: &[&str] = &[
    // The agents' own logins: the harnesses the daemon runs read them (acpmux login_env.rs,
    // agent_login.rs, byo_endpoint.rs, harness_health/agent_files.rs).
    "AI_GATEWAY_API_KEY",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "AWS_ACCESS_KEY_ID",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_SHARED_CREDENTIALS_FILE",
    "AZURE_OPENAI_API_KEY",
    "CEREBRAS_API_KEY",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CMUX_BYO_API_KEY",
    "CODEX_API_KEY",
    "COPILOT_GITHUB_TOKEN",
    "CURSOR_API_KEY",
    "CURSOR_AUTH_TOKEN",
    "DEEPINFRA_API_KEY",
    "DEEPSEEK_API_KEY",
    "FIREWORKS_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_GENERATIVE_AI_API_KEY",
    "GROK_API_KEY",
    "GROQ_API_KEY",
    "HF_TOKEN",
    "KIMI_API_KEY",
    "META_API_KEY",
    "MINIMAX_API_KEY",
    "MISTRAL_API_KEY",
    "MOONSHOT_API_KEY",
    "MUSE_API_KEY",
    "NOUS_API_KEY",
    "OPENAI_API_KEY",
    "OPENCODE_AUTH_CONTENT",
    "OPENROUTER_API_KEY",
    "PERPLEXITY_API_KEY",
    "TEAM_GATEWAY_TOKEN",
    "TOGETHER_AI_API_KEY",
    "TOGETHER_API_KEY",
    "XAI_API_KEY",
    "ZAI_API_KEY",
    // Tools an agent's shell runs with the person's own credentials (gh, npm, ssh, docker,
    // stripe), and the daemon's own GitHub reads (acpmux github_broker.rs).
    "DOCKER_AUTH_CONFIG",
    "GH_ENTERPRISE_TOKEN",
    "GH_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
    "GITHUB_TOKEN",
    "NPM_TOKEN",
    "SSH_AUTH_SOCK",
    "SSH_PRIVATE_KEY",
    "STRIPE_API_KEY",
    // No secret: which login a harness uses, a mode, a scheme or a switch.
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
    "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
    "CLAUDE_CODE_SKIP_VERTEX_AUTH",
    "CMUX_AUTH_CALLBACK_SCHEME",
    "CMUX_CLAUDE_AUTH",
    "CMUX_CODEX_AUTH",
    "CMUX_DEV_AUTH_ACCOUNT",
    "CMUX_DEV_AUTH_PROFILE",
    "CMUX_DEV_AUTH_REPLACE_SESSION",
    "CMUX_GEMINI_AUTH",
    "CMUX_GROK_AUTH",
    "CMUX_LINK_TOKEN_VERIFIER",
    "CMUX_RELAY_JOIN_TICKET_TTL_SECONDS",
    "CMUX_RELAY_JOIN_TIMEOUT_SECONDS",
    "CMUX_RELAY_TICKET_ISSUER",
    "CMUX_TEST_JOIN_ENABLE_FAKE",
    "CODEX_PROMPT_CACHE_KEY",
    "SR2_AUTO_COMPACT_TOKENS",
    "SUBROUTER_SESSION_KEY",
    // Public keys: nothing to hide.
    "CMUX_SERVER_RELEASE_KEYS",
    "CMUX_TUI_TEST_CONTENT_PUBLIC_KEY",
    "WEFT_TICKET_PUBKEY",
    // acpmux's session proofs: an agent's `cmux acp send` shows its own to the daemon that issued
    // it, and the daemon never passes it on (acpmux client.rs, hub/start_gate.rs, sender_token.rs,
    // secret_mcp.rs).
    "ACPMUX_SECRET_SESSION",
    "ACPMUX_SECRET_TOOLS",
    "ACPMUX_SENDER_TOKEN",
    "ACPMUX_SESSION_TOKEN",
    "ACPMUX_SESSION_TOKEN_SOCKET",
    // The computer-use helper's tokens: the daemon reads them to reach the helper and keeps them
    // from its agents itself (acpmux cua_socket.rs AGENT_SCRUBBED_ENV).
    "CMUX_CUA_SOCKET_AUTH_TOKEN",
    "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN",
    "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN",
    "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN",
    // A terminal's and a Chief's credentials: acpmux drops them itself before anything else runs
    // (acpmux cli/entry.rs, config/nested_env.rs).
    "CMUX_LAUNCH_CREDENTIAL",
    "MUX_AGENT_TOKEN_FILE",
    // No environment variable: redaction and secret-scan fixtures, a vault's secret names,
    // the X authority file, ssh's and git's own names.
    "ACCESSTOKEN",
    "ACCESS_KEY",
    "APIKEY",
    "API_KEY",
    "API_TOKEN",
    "AUTHKEY",
    "CLOUD_TOKEN",
    "CMUX_TUI_TEST_CREATE_BIND_GATE_KEY",
    "DEFAULT_KEY",
    "DEMO_KEY",
    "FAMILY_KEY",
    "GIT_AUTHOR_DATE",
    "GIT_AUTHOR_EMAIL",
    "GIT_AUTHOR_NAME",
    "GROQ_SECRET",
    "IASEEDAWSKEY012345",
    "LESSKEY",
    "LESSKEYIN",
    "OPENAI_ORG_TOKEN",
    "OPENROUTER_REFERER_TOKEN",
    "OTHER_KEY",
    "OTHER_TOKEN",
    "PRIVATE_KEY",
    "PRIVATE_TOKEN",
    "PROFILE_KEY",
    "ROUTER_KEY",
    "SEEDAWSKEY",
    "SSH_AUTH_INFO_0",
    "TOP_LEVEL_KEY",
    "VAULT_SECRET",
    "XAUTHORITY",
];

/// cmux-tui's whole tree: its crates, relays, bindings and build support (not vendored code).
fn cmux_tui_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Every `*.rs` under `dir`, without build output, vendored code and test files (their names
/// are fixtures).
fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            let skipped = ["target", "vendor", "tests", "node_modules"].contains(&name.as_str());
            if !skipped && !name.starts_with('.') {
                sources(&path, out);
            }
        } else if name.ends_with(".rs") && name != "tests.rs" && !name.ends_with("_tests.rs") {
            out.push(path);
        }
    }
}

/// The credential-like names quoted in cmux-tui's sources.
fn credential_names() -> BTreeSet<String> {
    let pattern = regex::Regex::new(
        r#""([A-Z][A-Z0-9_]*(?:TOKEN|KEY|SECRET|AUTH|CREDENTIAL|TICKET|JOIN)[A-Z0-9_]*)""#,
    )
    .unwrap();
    let mut files = Vec::new();
    sources(&cmux_tui_root(), &mut files);
    assert!(files.len() > 100, "found only {} sources under {:?}", files.len(), cmux_tui_root());
    let mut names = BTreeSet::new();
    for file in files {
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        for found in pattern.captures_iter(&text) {
            names.insert(found[1].to_owned());
        }
    }
    names
}

/// #38355 review: `CREDENTIAL_ENV` named two cmux credentials while cmux reads more, so a
/// `cmux acp` this process starts (and the daemon and agents it may start) could inherit one.
/// Each name is decided: stripped, or allowed with its reason.
#[test]
fn every_credential_env_name_is_stripped_or_allowed() {
    let undecided: Vec<String> = credential_names()
        .into_iter()
        .filter(|name| {
            !super::CREDENTIAL_ENV.contains(&name.as_str()) && !ALLOWED.contains(&name.as_str())
        })
        .collect();
    assert!(
        undecided.is_empty(),
        "credential-like env names neither in devices::CREDENTIAL_ENV nor in \
         credential_env_tests.rs ALLOWED (strip it, or allow it with a reason): {undecided:?}"
    );
    for name in super::CREDENTIAL_ENV {
        assert!(!ALLOWED.contains(name), "{name} is both stripped and allowed");
    }
}

/// The cmux credentials the review named are stripped from every `cmux` child; the ones a child
/// needs are not.
#[test]
fn the_cmux_credentials_no_child_needs_are_stripped() {
    for name in [
        "CMUX_JOIN",
        "CMUX_CLOUD_ACCESS_TOKEN",
        "CMUX_API_TOKEN",
        "CMUX_TOKEN",
        "CMUX_VM_API_KEY",
        "CMUX_MACHINE_PROVIDER_TOKEN",
        "CMUX_AUTH_CREDENTIALS_FILE",
        "CMUX_RELAY_TICKET_KEY",
        "CMUX_WORKFLOW_RUNNER_TOKEN",
    ] {
        assert!(super::CREDENTIAL_ENV.contains(&name), "{name}");
    }
    for name in ["CMUX_CLAUDE_AUTH", "ACPMUX_SESSION_TOKEN", "ANTHROPIC_API_KEY"] {
        assert!(!super::CREDENTIAL_ENV.contains(&name), "{name}");
    }
}
