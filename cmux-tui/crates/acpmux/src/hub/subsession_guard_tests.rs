use super::argv_full_access;

fn argv(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn a_command_that_skips_the_checks_is_full_access() {
    for a in [
        &["claude", "--dangerously-skip-permissions"][..],
        &["claude", "--permission-mode", "bypassPermissions"],
        &["claude", "--permission-mode=bypassPermissions"],
        &["codex", "-s", "danger-full-access"],
        &["codex", "--sandbox=danger-full-access"],
        &["codex", "-c", "sandbox_mode=\"danger-full-access\""],
        &["codex", "--dangerously-bypass-approvals-and-sandbox"],
    ] {
        assert!(argv_full_access(&argv(a)).is_some(), "{a:?}");
    }
    for a in [
        &["claude", "--permission-mode", "default"][..],
        &["codex", "-s", "workspace-write"],
        &["opencode", "acp"],
    ] {
        assert!(argv_full_access(&argv(a)).is_none(), "{a:?}");
    }
}

#[test]
fn attached_short_flags_and_gemini_auto_approval_are_full_access() {
    for a in [
        &["codex", "-sdanger-full-access"][..],
        &["codex", "-csandbox_mode=danger-full-access"],
        &["gemini", "-y"],
        &["qwen", "--approval-mode", "yolo"],
        &["gemini", "--approval-mode=auto_edit"],
    ] {
        assert!(argv_full_access(&argv(a)).is_some(), "{a:?}");
    }
    for a in [&["gemini", "--approval-mode", "default"][..], &["codex", "-sworkspace-write"]] {
        assert!(argv_full_access(&argv(a)).is_none(), "{a:?}");
    }
}
