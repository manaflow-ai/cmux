use super::{harness_name, source_name};

#[test]
fn w3h_vocabulary_has_one_name_per_harness_and_source() {
    for alias in ["claude", "claude-code", "claude_code", "Claude Code", "CLAUDE-CODE"] {
        assert_eq!(harness_name(alias), "claude", "{alias}");
    }
    for alias in ["codex", "codex-cli", "openai-codex"] {
        assert_eq!(harness_name(alias), "codex", "{alias}");
    }
    assert_eq!(harness_name("open-code"), "opencode");
    assert_eq!(harness_name("gemini-cli"), "gemini");
    assert_eq!(harness_name("ampcode"), "amp");
    assert_eq!(harness_name("agy"), "antigravity");
    assert_eq!(harness_name("Pi"), "pi");
    assert_eq!(source_name("detected"), "plugin");
    assert_eq!(source_name("plugin"), "plugin");
    assert_eq!(source_name("hook"), "hook");
    assert_eq!(source_name("osc7501"), "program_status");
    assert_eq!(source_name("program_status"), "program_status");
    assert_eq!(source_name("socket"), "socket");
}
