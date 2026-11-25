//! A checkout that declares its tools with Nix: `flake.nix` with `devShells`, `shell.nix`, or
//! `devbox.json`, plus a direnv `.envrc`. `[setup]` installs Nix (the Determinate installer) or
//! devbox when the machine lacks it, then builds the shell once so the first agent starts warm.

use std::path::Path;

use serde_json::Value;

use super::project_files::{
    at, checkout_source, dotenv_keys, folder_name, looks_secret, parse_jsonc, repo_at,
    value_has_login,
};
use crate::plan::{Plan, Project, SourceKind, machine_name};

/// Installs Nix with the Determinate installer when absent.
pub const ENSURE_NIX: &str = "command -v nix >/dev/null 2>&1 || [ -x /nix/var/nix/profiles/default/bin/nix ] || curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm";

/// Puts a fresh Nix install on `PATH` (each `[setup]` line runs in a shell of its own).
pub const NIX_PROFILE: &str = "if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi";

/// Installs devbox when absent (it installs Nix itself on first use).
pub const ENSURE_DEVBOX: &str =
    "command -v devbox >/dev/null 2>&1 || curl -fsSL https://get.jetify.com/devbox | bash -s -- -f";

/// The checkout's Nix-declared environment as a project, or `None` without any of the files.
pub fn project(root: &Path) -> Option<Project> {
    let flake = std::fs::read_to_string(root.join("flake.nix")).ok();
    let shell_nix = root.join("shell.nix").is_file();
    let devbox = std::fs::read_to_string(root.join("devbox.json")).ok();
    let envrc = std::fs::read_to_string(root.join(".envrc")).ok();
    if flake.is_none() && !shell_nix && devbox.is_none() {
        return None;
    }
    let mut project = Project {
        key: root.display().to_string(),
        name: machine_name(&folder_name(root)),
        repo: Some(repo_at(root)),
        checked: true,
        ..Project::default()
    };
    let setup = &mut project.machine.setup;

    if let Some(flake) = &flake {
        if flake.contains("devShells") || flake.contains("devShell") {
            setup.push(ENSURE_NIX.into());
            setup.push(format!("{NIX_PROFILE}; nix develop -c true"));
            project.notes.push(
                "flake.nix's dev shell is built by [setup]; enter it with nix develop".into(),
            );
        } else {
            project.notes.push(
                "flake.nix has no devShells; nothing is built for it, run its packages with nix run".into(),
            );
        }
    }
    if shell_nix && !project.machine.setup.iter().any(|s| s.ends_with("nix develop -c true")) {
        let setup = &mut project.machine.setup;
        if !setup.iter().any(|s| s == ENSURE_NIX) {
            setup.push(ENSURE_NIX.into());
        }
        setup.push(format!("{NIX_PROFILE}; nix-shell --run true"));
        project.notes.push("shell.nix is built by [setup]; enter it with nix-shell".into());
    }
    if let Some(text) = &devbox {
        match parse_jsonc(text) {
            Ok(json) => {
                let setup = &mut project.machine.setup;
                setup.push(ENSURE_DEVBOX.into());
                setup.push("devbox install".into());
                let packages = packages(at(&json, &["packages"]));
                if !packages.is_empty() {
                    project.notes.push(format!("devbox packages: {}", packages.join(", ")));
                }
                if let Value::Object(env) = at(&json, &["env"]) {
                    for (k, v) in env {
                        let Some(v) = v.as_str() else { continue };
                        if looks_secret(k) || value_has_login(v) {
                            project.machine.secret_names.insert(k.clone());
                        } else {
                            project.machine.env.insert(k.clone(), v.to_owned());
                        }
                    }
                }
                if !at(&json, &["shell", "init_hook"]).is_null() {
                    project.notes.push(
                        "devbox's init_hook runs when you enter devbox shell, as before".into(),
                    );
                }
            }
            Err(e) => project.notes.push(format!("devbox.json is not JSON ({e}); not read")),
        }
    }
    if let Some(envrc) = &envrc {
        let mut note = String::from(".envrc (direnv) is in the checkout");
        if envrc.contains("use flake") || envrc.contains("use nix") {
            note.push_str(
                "; it loads the Nix shell, so install direnv and nix-direnv to keep that",
            );
        }
        let names = dotenv_keys(envrc);
        if !names.is_empty() {
            note.push_str(&format!(
                "; it exports {}, whose values stay out of the plan",
                names.join(", ")
            ));
        }
        if envrc.contains("dotenv") {
            note.push_str(
                "; it reads a .env file, deliver those values with cloud deliver-secrets",
            );
        }
        project.notes.push(note);
    }
    Some(project)
}

/// The plan for a Nix-declared checkout: one project, or none and a warning.
pub fn plan(root: &Path) -> Plan {
    let mut plan = Plan::new(checkout_source(SourceKind::Nix, root));
    match project(root) {
        Some(project) => plan.projects.push(project),
        None => plan
            .warnings
            .push(format!("no flake.nix, shell.nix or devbox.json in {}", root.display())),
    }
    plan
}

fn packages(value: &Value) -> Vec<String> {
    match value {
        Value::Array(items) => items.iter().filter_map(|i| i.as_str().map(str::to_owned)).collect(),
        Value::Object(map) => map
            .iter()
            .map(|(k, v)| match v.as_str() {
                Some(version) => format!("{k}@{version}"),
                None => k.clone(),
            })
            .collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
#[path = "nix_tests.rs"]
mod tests;
