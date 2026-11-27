use super::super::tests::context;
use super::super::*;

fn status_of(context: &Context, provider: &str) -> Value {
    let plan = Plan { action: Action::Status, providers: vec![provider.into()] };
    let result = run_with_context(&plan, context);
    assert!(!result.failed, "{provider}: {}", result.value);
    result.value["providers"][0].clone()
}

#[cfg(unix)]
#[test]
fn status_reports_a_conflict_where_install_would_refuse() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());

    // A plugin file cmux did not write.
    let amp = context.home.join(".config/amp/plugins/cmux-tui-journal.ts");
    atomic_write(&amp, b"export default custom;\n", Some(0o600)).unwrap();
    let status = status_of(&context, "amp");
    assert_eq!(status["state"], "conflict", "{status}");
    assert_eq!(status["reason"], "not_owned", "{status}");
    assert!(status["detail"].as_str().is_some_and(|detail| !detail.is_empty()), "{status}");

    // A symlink in place of a plugin file, even one pointing at cmux's own content.
    let target = root.path().join("opencode.js");
    atomic_write(&target, include_bytes!("../assets/agent-hooks/opencode.js"), Some(0o600))
        .unwrap();
    let opencode = context.home.join(".config/opencode/plugins/cmux-tui-journal.js");
    fs::create_dir_all(opencode.parent().unwrap()).unwrap();
    symlink(&target, &opencode).unwrap();
    let status = status_of(&context, "opencode");
    assert_eq!(status["state"], "conflict", "{status}");
    assert_eq!(status["reason"], "symlink", "{status}");

    // A directory in place of a plugin file.
    fs::create_dir_all(context.home.join(".pi/agent/extensions/cmux-tui-journal.ts")).unwrap();
    let status = status_of(&context, "pi");
    assert_eq!(status["state"], "conflict", "{status}");
    assert_eq!(status["reason"], "not_a_file", "{status}");

    // A symlinked JSON settings file.
    let settings = root.path().join("claude-settings.json");
    atomic_write(&settings, b"{}\n", Some(0o600)).unwrap();
    let claude = context.home.join(".claude/settings.json");
    fs::create_dir_all(claude.parent().unwrap()).unwrap();
    symlink(&settings, &claude).unwrap();
    let status = status_of(&context, "claude");
    assert_eq!(status["state"], "conflict", "{status}");
    assert_eq!(status["reason"], "symlink", "{status}");

    // A Hermes plugin directory holding a file cmux did not write.
    let hermes = context.home.join(".hermes/plugins/cmux-tui-journal");
    atomic_write(&hermes.join("notes.txt"), b"mine\n", Some(0o600)).unwrap();
    let status = status_of(&context, "hermes-agent");
    assert_eq!(status["state"], "conflict", "{status}");
    assert_eq!(status["reason"], "not_owned", "{status}");

    // Every conflict above is one install refuses, and status left the files alone.
    for provider in ["amp", "opencode", "pi", "claude", "hermes-agent"] {
        let plan = Plan { action: Action::Install, providers: vec![provider.into()] };
        assert!(run_with_context(&plan, &context).failed, "{provider} install should refuse");
    }
    assert_eq!(fs::read_to_string(&amp).unwrap(), "export default custom;\n");
    assert_eq!(fs::read_to_string(&settings).unwrap(), "{}\n");

    // Missing files still read as absent, without a reason.
    let status = status_of(&context, "campfire");
    assert_eq!(status["state"], "absent", "{status}");
    assert!(status.get("reason").is_none(), "{status}");
}

#[cfg(unix)]
#[test]
fn status_reports_an_unreadable_plugin_as_unavailable() {
    use std::os::unix::fs::PermissionsExt as _;

    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let amp = context.home.join(".config/amp/plugins/cmux-tui-journal.ts");
    atomic_write(&amp, b"export default custom;\n", Some(0o600)).unwrap();
    fs::set_permissions(&amp, fs::Permissions::from_mode(0o000)).unwrap();
    if fs::read(&amp).is_ok() {
        // Running as root reads through mode 000; nothing to observe.
        return;
    }
    let status = status_of(&context, "amp");
    fs::set_permissions(&amp, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(status["state"], "unavailable", "{status}");
    assert_eq!(status["reason"], "unreadable", "{status}");
}
