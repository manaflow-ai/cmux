use super::{help, resolve_runner, scope_help};
use std::fs;

#[test]
fn resolves_the_installed_runner_name() {
    let root = std::env::temp_dir().join(format!("cmux-code-mode-runner-{}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let installed = root.join("cmux-code-mode-runner");
    fs::write(&installed, b"#!/bin/sh\n").unwrap();
    assert_eq!(resolve_runner(Some(root.join("cmux"))), installed);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn docs_help_routes_before_code_mode_commands() {
    let args = ["help".to_owned(), "docs".to_owned()];
    assert!(matches!(
        crate::cli::parse(&args, crate::cli::Surface::Cmux),
        Ok(crate::cli::ParsedCommand::Help(Some(scope))) if scope == "docs"
    ));
}

#[test]
fn run_scope_help_is_owned_by_code_mode() {
    assert_eq!(scope_help("run").as_deref(), Some(help()));
    assert!(scope_help("docs").is_none());
}
