use super::*;
use crate::config::HarnessKind;
use crate::cpu_class::{CpuClass, DEFAULT, default_for};

/// A remote chain's `argv[0]` is the resolved file (`fix_remote_executable`), and the native
/// installer's `claude` resolves to `versions/<version>`: still Claude Code, not a launcher.
#[test]
fn cpu_class_of_a_resolved_remote_program() {
    let dir = tempfile::tempdir().unwrap();
    let installed = dir.path().join(".local/share/claude/versions/2.1.34");
    std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
    std::fs::write(&installed, "").unwrap();
    let claude = dir.path().join("claude");
    std::os::unix::fs::symlink(&installed, &claude).unwrap();
    let launcher = dir.path().join("sr2");
    std::fs::write(&launcher, "").unwrap();
    let class = |program: &Path| {
        let resolved = remote_executable(program.to_str().unwrap()).map_err(|_| "refused");
        default_for(HarnessKind::ClaudeStdio, &[resolved.unwrap()])
    };
    assert_eq!(class(&claude), DEFAULT);
    assert_eq!(class(&launcher), CpuClass::Normal);
}
