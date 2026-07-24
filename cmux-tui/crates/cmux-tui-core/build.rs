use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

fn main() {
    for name in [
        "CMUX_TUI_BUILD_COMMIT",
        "CMUX_MUX_BUILD_COMMIT",
        "CMUX_TUI_GHOSTTY_COMMIT",
        "CMUX_GHOSTTY_SRC",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
    }

    let manifest_dir =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("Cargo sets CARGO_MANIFEST_DIR"));
    let workspace_root =
        manifest_dir.ancestors().nth(2).expect("cmux-tui-core is inside the workspace");
    let repository_root =
        workspace_root.parent().expect("the cmux-tui workspace is inside the repository");
    let ghostty_root = env::var_os("CMUX_GHOSTTY_SRC")
        .map(PathBuf::from)
        .unwrap_or_else(|| repository_root.join("ghostty"));

    println!("cargo:rerun-if-changed={}", workspace_root.join("Cargo.toml").display());
    println!("cargo:rerun-if-changed={}", workspace_root.join("Cargo.lock").display());
    println!("cargo:rerun-if-changed={}", workspace_root.join("crates").display());
    println!("cargo:rerun-if-changed={}", ghostty_root.join("build.zig").display());
    println!("cargo:rerun-if-changed={}", ghostty_root.join("include").display());
    println!("cargo:rerun-if-changed={}", ghostty_root.join("src").display());
    track_git_identity(repository_root);
    track_git_identity(&ghostty_root);

    if env::var_os("CMUX_TUI_BUILD_COMMIT").is_none()
        && env::var_os("CMUX_MUX_BUILD_COMMIT").is_none()
        && let Some(identity) = source_identity(workspace_root, workspace_root)
    {
        println!("cargo:rustc-env=CMUX_TUI_SOURCE_COMMIT={identity}");
    }
    if env::var_os("CMUX_TUI_GHOSTTY_COMMIT").is_none()
        && let Some(identity) = source_identity(&ghostty_root, &ghostty_root)
    {
        println!("cargo:rustc-env=CMUX_TUI_SOURCE_GHOSTTY_COMMIT={identity}");
    }
}

fn source_identity(git_root: &Path, fallback_root: &Path) -> Option<String> {
    if let Some(commit) = git_text(git_root, &["rev-parse", "HEAD"]) {
        let status =
            git_bytes(git_root, &["status", "--porcelain=v1", "--untracked-files=all", "--", "."])?;
        if status.is_empty() {
            return Some(commit);
        }
        return Some(format!("{commit}-dirty-{:016x}", dirty_fingerprint(git_root)?));
    }
    directory_fingerprint(fallback_root)
        .ok()
        .map(|fingerprint| format!("source-{fingerprint:016x}"))
}

fn dirty_fingerprint(root: &Path) -> Option<u64> {
    let mut hash = FNV_OFFSET;
    hash_bytes(&mut hash, &git_bytes(root, &["diff", "--binary", "HEAD", "--", "."])?);
    let untracked =
        git_bytes(root, &["ls-files", "-z", "--others", "--exclude-standard", "--", "."])?;
    for path in untracked.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
        hash_bytes(&mut hash, path);
        let path = std::str::from_utf8(path).ok()?;
        hash_bytes(&mut hash, &fs::read(root.join(path)).ok()?);
    }
    Some(hash)
}

fn directory_fingerprint(root: &Path) -> std::io::Result<u64> {
    fn visit(root: &Path, path: &Path, hash: &mut u64) -> std::io::Result<()> {
        let mut entries = fs::read_dir(path)?.collect::<Result<Vec<_>, _>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let name = entry.file_name();
            if matches!(name.to_str(), Some(".git" | "target" | "zig-cache" | "zig-out")) {
                continue;
            }
            let path = entry.path();
            if path.is_dir() {
                visit(root, &path, hash)?;
            } else if path.is_file() {
                hash_bytes(
                    hash,
                    path.strip_prefix(root).unwrap_or(&path).as_os_str().as_encoded_bytes(),
                );
                hash_bytes(hash, &fs::read(path)?);
            }
        }
        Ok(())
    }

    let mut hash = FNV_OFFSET;
    visit(root, root, &mut hash)?;
    Ok(hash)
}

fn hash_bytes(hash: &mut u64, bytes: &[u8]) {
    for byte in bytes {
        *hash ^= u64::from(*byte);
        *hash = hash.wrapping_mul(FNV_PRIME);
    }
}

fn track_git_identity(root: &Path) {
    let Some(head) = git_text(root, &["rev-parse", "--git-path", "HEAD"]) else { return };
    println!("cargo:rerun-if-changed={head}");
    if let Some(reference) = git_text(root, &["symbolic-ref", "-q", "HEAD"])
        && let Some(reference_path) =
            git_text(root, &["rev-parse", "--git-path", reference.as_str()])
    {
        println!("cargo:rerun-if-changed={reference_path}");
    }
}

fn git_text(root: &Path, args: &[&str]) -> Option<String> {
    let output = git_bytes(root, args)?;
    let value = std::str::from_utf8(&output).ok()?.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn git_bytes(root: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let output = Command::new("git").arg("-C").arg(root).args(args).output().ok()?;
    output.status.success().then_some(output.stdout)
}
