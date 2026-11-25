use std::path::Path;

use super::*;

fn write(root: &Path, path: &str, text: &str) {
    std::fs::write(root.join(path), text).unwrap();
}

#[test]
fn a_flake_with_dev_shells_installs_nix_and_builds_the_shell() {
    let dir = tempfile::tempdir().unwrap();
    write(
        dir.path(),
        "flake.nix",
        "{ outputs = { self, nixpkgs }: { devShells.x86_64-linux.default = nixpkgs.mkShell {}; }; }",
    );
    write(dir.path(), "shell.nix", "{}");
    write(dir.path(), ".envrc", "use flake\nexport AWS_SECRET_ACCESS_KEY=planted-envrc\n");
    let plan = plan(dir.path());
    assert_eq!(plan.source.kind, SourceKind::Nix);
    let p = &plan.projects[0];
    assert_eq!(p.machine.setup.len(), 2, "{:?}", p.machine.setup);
    assert_eq!(p.machine.setup[0], ENSURE_NIX);
    assert!(p.machine.setup[0].contains("install.determinate.systems"));
    assert!(p.machine.setup[1].ends_with("nix develop -c true"));
    let envrc = p.notes.iter().find(|n| n.contains(".envrc")).unwrap();
    assert!(envrc.contains("nix-direnv") && envrc.contains("AWS_SECRET_ACCESS_KEY"));
    assert!(!serde_json::to_string(&plan).unwrap().contains("planted-envrc"));
}

#[test]
fn a_flake_without_dev_shells_builds_nothing() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), "flake.nix", "{ outputs = { self }: { packages = {}; }; }");
    let p = project(dir.path()).unwrap();
    assert!(p.machine.setup.is_empty());
    assert!(p.notes.iter().any(|n| n.contains("no devShells")));
}

#[test]
fn shell_nix_uses_nix_shell() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), "shell.nix", "{ pkgs ? import <nixpkgs> {} }: pkgs.mkShell {}");
    let p = project(dir.path()).unwrap();
    assert_eq!(p.machine.setup[0], ENSURE_NIX);
    assert!(p.machine.setup[1].ends_with("nix-shell --run true"));
}

#[test]
fn devbox_installs_and_maps_env() {
    let dir = tempfile::tempdir().unwrap();
    write(
        dir.path(),
        "devbox.json",
        r#"{
          // devbox allows comments
          "packages": ["nodejs@20", "python@3.12",],
          "env": { "NODE_ENV": "dev", "API_TOKEN": "planted-devbox" },
          "shell": { "init_hook": ["echo hi"] }
        }"#,
    );
    let plan = plan(dir.path());
    let p = &plan.projects[0];
    assert_eq!(p.machine.setup, vec![ENSURE_DEVBOX.to_owned(), "devbox install".to_owned()]);
    assert_eq!(p.machine.env.get("NODE_ENV").map(String::as_str), Some("dev"));
    assert!(p.machine.secret_names.contains("API_TOKEN"));
    assert!(p.notes.iter().any(|n| n.contains("nodejs@20")));
    assert!(!serde_json::to_string(&plan).unwrap().contains("planted-devbox"));
}

#[test]
fn nothing_nix_is_none() {
    let dir = tempfile::tempdir().unwrap();
    assert!(project(dir.path()).is_none());
    assert!(plan(dir.path()).projects.is_empty());
}
