//! `agent hook status` names what blocks `install` instead of reporting it
//! as absent: a symlink, a non-file, a plugin file cmux-tui did not write, or a
//! target it cannot inspect. The checks mirror install's own refusals, which
//! `ensure_replaceable_target` keeps here beside them.

use std::fs;
use std::io;
use std::path::Path;

use anyhow::Context as _;
use serde_json::{Value, json};

use super::{Format, Provider, is_owned_plugin};

/// The status row for a provider whose target install would refuse.
pub(super) fn conflict_row(provider: Provider, path: &Path) -> Option<Value> {
    let conflict = install_conflict(provider, path)?;
    Some(json!({
        "provider":provider.id,
        "path":path,
        "state":conflict.state(),
        "reason":conflict.reason,
        "detail":conflict.detail,
        "changed":false,
    }))
}

/// Why an existing hook target blocks `install`. `status` reports it instead
/// of "absent" so a caller does not offer an install the installer refuses.
#[derive(Debug)]
struct Conflict {
    /// `symlink`, `not_a_file`, `not_a_directory`, `not_owned` or `unreadable`.
    reason: &'static str,
    detail: String,
}

impl Conflict {
    fn new(reason: &'static str, detail: String) -> Self {
        Self { reason, detail }
    }

    fn state(&self) -> &'static str {
        if self.reason == "unreadable" { "unavailable" } else { "conflict" }
    }
}

/// Mirrors the refusals in `install_provider`: `ensure_replaceable_target`,
/// `ensure_owned_plugin_directory` and the plugin ownership check.
fn install_conflict(provider: Provider, path: &Path) -> Option<Conflict> {
    match provider.format {
        Format::Nested { .. } | Format::Flat { .. } | Format::AntigravityJson => {
            target_kind_conflict(path, false)
        }
        Format::Plugin { .. } => {
            target_kind_conflict(path, false).or_else(|| foreign_plugin_conflict(path))
        }
        Format::HermesPlugin { .. } => target_kind_conflict(path, true)
            .or_else(|| hermes_directory_conflict(path))
            .or_else(|| {
                ["__init__.py", "plugin.yaml"].into_iter().find_map(|name| {
                    let file = path.join(name);
                    target_kind_conflict(&file, false).or_else(|| foreign_plugin_conflict(&file))
                })
            }),
        Format::RovoYaml | Format::KimiToml => None,
    }
}

fn target_kind_conflict(path: &Path, directory: bool) -> Option<Conflict> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return None,
        Err(error) => {
            return Some(Conflict::new(
                "unreadable",
                format!("cannot inspect {}: {error}", path.display()),
            ));
        }
    };
    if metadata.file_type().is_symlink() {
        return Some(Conflict::new(
            "symlink",
            format!("{} is a symlink, which cmux-tui will not replace", path.display()),
        ));
    }
    match (directory, metadata.is_dir(), metadata.is_file()) {
        (true, false, _) => Some(Conflict::new(
            "not_a_directory",
            format!("{} exists and is not a directory", path.display()),
        )),
        (false, _, false) => Some(Conflict::new(
            "not_a_file",
            format!("{} exists and is not a regular file", path.display()),
        )),
        _ => None,
    }
}

fn foreign_plugin_conflict(path: &Path) -> Option<Conflict> {
    match fs::read(path) {
        Ok(content) if is_owned_plugin(&content) => None,
        Ok(_) => Some(Conflict::new(
            "not_owned",
            format!("{} exists and is not owned by cmux-tui", path.display()),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => {
            Some(Conflict::new("unreadable", format!("cannot read {}: {error}", path.display())))
        }
    }
}

fn hermes_directory_conflict(path: &Path) -> Option<Conflict> {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return None,
        Err(error) => {
            return Some(Conflict::new(
                "unreadable",
                format!("cannot inspect {}: {error}", path.display()),
            ));
        }
    };
    for entry in entries {
        let name = match entry {
            Ok(entry) => entry.file_name(),
            Err(error) => {
                return Some(Conflict::new(
                    "unreadable",
                    format!("cannot inspect {}: {error}", path.display()),
                ));
            }
        };
        if !matches!(name.to_str(), Some("__init__.py" | "plugin.yaml" | "__pycache__")) {
            return Some(Conflict::new(
                "not_owned",
                format!("{} contains an unowned entry", path.display()),
            ));
        }
    }
    None
}

pub(super) fn ensure_replaceable_target(path: &Path) -> anyhow::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    };
    anyhow::ensure!(
        !metadata.file_type().is_symlink(),
        "refusing to replace symlink {}",
        path.display()
    );
    anyhow::ensure!(metadata.is_file(), "refusing to replace non-file {}", path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
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
}
