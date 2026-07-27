use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
#[cfg(unix)]
use std::{ffi::OsStr, os::unix::ffi::OsStrExt};

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;
const CMUX_TUI_SOURCE_PATHS: &[&str] = &["Cargo.toml", "Cargo.lock", "bindings/rust", "crates"];
const GHOSTTY_SOURCE_PATHS: &[&str] = &["build.zig", "build.zig.zon", "include", "pkg", "src"];

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
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| repository_root.join("ghostty"));

    track_source_paths(workspace_root, CMUX_TUI_SOURCE_PATHS);
    track_source_paths(&ghostty_root, GHOSTTY_SOURCE_PATHS);
    track_git_identity(repository_root);
    track_git_identity(&ghostty_root);

    if !nonempty_env("CMUX_TUI_BUILD_COMMIT") && !nonempty_env("CMUX_MUX_BUILD_COMMIT") {
        let identity = source_identity(workspace_root, workspace_root, CMUX_TUI_SOURCE_PATHS)
            .expect("derive an exact cmux-tui source identity");
        println!("cargo:rustc-env=CMUX_TUI_SOURCE_COMMIT={identity}");
    }
    if !nonempty_env("CMUX_TUI_GHOSTTY_COMMIT") {
        let identity = source_identity(&ghostty_root, &ghostty_root, GHOSTTY_SOURCE_PATHS)
            .expect("derive an exact Ghostty source identity");
        println!("cargo:rustc-env=CMUX_TUI_SOURCE_GHOSTTY_COMMIT={identity}");
    }
}

fn nonempty_env(name: &str) -> bool {
    env::var_os(name).is_some_and(|value| !value.is_empty())
}

fn track_source_paths(root: &Path, paths: &[&str]) {
    for path in paths {
        println!("cargo:rerun-if-changed={}", root.join(path).display());
    }
}

fn source_identity(git_root: &Path, fallback_root: &Path, paths: &[&str]) -> io::Result<String> {
    if let Some(commit) = optional_git_bytes(git_root, &["rev-parse", "HEAD"])? {
        let commit = std::str::from_utf8(&commit)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "git commit is not UTF-8"))?
            .trim();
        if commit.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "git commit is empty"));
        }
        let status = required_git_bytes_for_paths(
            git_root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            paths,
        )?;
        if status.is_empty() {
            return Ok(commit.to_string());
        }
        return Ok(format!("{commit}-dirty-{:016x}", dirty_fingerprint(git_root, paths)?));
    }
    directory_fingerprint(fallback_root, paths)
        .map(|fingerprint| format!("source-{fingerprint:016x}"))
}

fn dirty_fingerprint(root: &Path, paths: &[&str]) -> io::Result<u64> {
    let mut hash = FNV_OFFSET;
    hash_component(
        &mut hash,
        &required_git_bytes_for_paths(root, &["diff", "--binary", "--full-index", "HEAD"], paths)?,
    );
    let untracked = required_git_bytes_for_paths(
        root,
        &["ls-files", "-z", "--others", "--exclude-standard"],
        paths,
    )?;
    for path in untracked.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
        hash_component(&mut hash, path);
        hash_filesystem_entry(&mut hash, &path_from_git_bytes(root, path)?)?;
    }
    Ok(hash)
}

fn directory_fingerprint(root: &Path, paths: &[&str]) -> io::Result<u64> {
    fn visit(root: &Path, path: &Path, hash: &mut u64) -> io::Result<()> {
        let mut entries = fs::read_dir(path)?.collect::<Result<Vec<_>, _>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let name = entry.file_name();
            if matches!(
                name.to_str(),
                Some(".git" | "target" | ".zig-cache" | "zig-cache" | "zig-out")
            ) {
                continue;
            }
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path)?;
            if metadata.file_type().is_dir() {
                visit(root, &path, hash)?;
            } else {
                hash_component(
                    hash,
                    path.strip_prefix(root).unwrap_or(&path).as_os_str().as_encoded_bytes(),
                );
                hash_filesystem_entry(hash, &path)?;
            }
        }
        Ok(())
    }

    let mut hash = FNV_OFFSET;
    for path in paths {
        let path = root.join(path);
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_dir() {
            visit(root, &path, &mut hash)?;
        } else {
            hash_component(
                &mut hash,
                path.strip_prefix(root).unwrap_or(&path).as_os_str().as_encoded_bytes(),
            );
            hash_filesystem_entry(&mut hash, &path)?;
        }
    }
    Ok(hash)
}

fn hash_filesystem_entry(hash: &mut u64, path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        hash_component(hash, b"symlink");
        hash_component(hash, fs::read_link(path)?.as_os_str().as_encoded_bytes());
    } else if metadata.file_type().is_file() {
        hash_component(hash, b"file");
        hash_component(hash, &fs::read(path)?);
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported source entry {}", path.display()),
        ));
    }
    Ok(())
}

fn hash_component(hash: &mut u64, bytes: &[u8]) {
    hash_bytes(hash, &(bytes.len() as u64).to_le_bytes());
    hash_bytes(hash, bytes);
}

fn hash_bytes(hash: &mut u64, bytes: &[u8]) {
    for byte in bytes {
        *hash ^= u64::from(*byte);
        *hash = hash.wrapping_mul(FNV_PRIME);
    }
}

fn track_git_identity(root: &Path) {
    let Some(head) = git_text(root, &["rev-parse", "--git-path", "HEAD"]) else { return };
    println!("cargo:rerun-if-changed={}", resolve_git_path(root, &head).display());
    if let Some(reference) = git_text(root, &["symbolic-ref", "-q", "HEAD"])
        && let Some(reference_path) =
            git_text(root, &["rev-parse", "--git-path", reference.as_str()])
    {
        println!("cargo:rerun-if-changed={}", resolve_git_path(root, &reference_path).display());
    }
    if let Some(packed_refs) = git_text(root, &["rev-parse", "--git-path", "packed-refs"]) {
        println!("cargo:rerun-if-changed={}", resolve_git_path(root, &packed_refs).display());
    }
}

fn resolve_git_path(root: &Path, value: &str) -> PathBuf {
    let path = PathBuf::from(value);
    if path.is_absolute() { path } else { root.join(path) }
}

fn git_text(root: &Path, args: &[&str]) -> Option<String> {
    let output = optional_git_bytes(root, args).ok()??;
    let value = std::str::from_utf8(&output).ok()?.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn optional_git_bytes(root: &Path, args: &[&str]) -> io::Result<Option<Vec<u8>>> {
    let output = match Command::new("git").arg("-C").arg(root).args(args).output() {
        Ok(output) => output,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    Ok(output.status.success().then_some(output.stdout))
}

fn required_git_bytes(root: &Path, args: &[&str]) -> io::Result<Vec<u8>> {
    optional_git_bytes(root, args)?.ok_or_else(|| {
        io::Error::other(format!("git {} failed in {}", args.join(" "), root.display()))
    })
}

fn required_git_bytes_for_paths(root: &Path, args: &[&str], paths: &[&str]) -> io::Result<Vec<u8>> {
    let mut scoped = Vec::with_capacity(args.len() + paths.len() + 1);
    scoped.extend_from_slice(args);
    scoped.push("--");
    scoped.extend_from_slice(paths);
    required_git_bytes(root, &scoped)
}

#[cfg(unix)]
fn path_from_git_bytes(root: &Path, path: &[u8]) -> io::Result<PathBuf> {
    Ok(root.join(OsStr::from_bytes(path)))
}

#[cfg(not(unix))]
fn path_from_git_bytes(root: &Path, path: &[u8]) -> io::Result<PathBuf> {
    let path = std::str::from_utf8(path)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "git path is not UTF-8"))?;
    Ok(root.join(path))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use std::time::{SystemTime, UNIX_EPOCH};
    #[cfg(target_os = "linux")]
    use std::{ffi::OsString, os::unix::ffi::OsStringExt};

    struct TestRepository {
        root: PathBuf,
    }

    impl TestRepository {
        fn new(name: &str) -> Self {
            let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
            let root = env::temp_dir()
                .join(format!("cmux-source-identity-{name}-{}-{nonce}", std::process::id()));
            fs::create_dir_all(&root).unwrap();
            run_git(&root, &["init", "-q"]);
            run_git(&root, &["config", "user.email", "tests@cmux.invalid"]);
            run_git(&root, &["config", "user.name", "cmux tests"]);
            fs::write(root.join("tracked"), b"tracked").unwrap();
            run_git(&root, &["add", "tracked"]);
            run_git(&root, &["commit", "-qm", "initial"]);
            Self { root }
        }
    }

    impl Drop for TestRepository {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn run_git(root: &Path, args: &[&str]) {
        let output = Command::new("git").arg("-C").arg(root).args(args).output().unwrap();
        assert!(
            output.status.success(),
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn dirty_identity_hashes_non_utf8_untracked_paths_and_contents() {
        let repository = TestRepository::new("non-utf8");
        let name = OsString::from_vec(vec![b'n', b'o', b'n', b'-', 0xff]);
        let path = repository.root.join(name);
        fs::write(&path, b"one").unwrap();
        let first = source_identity(&repository.root, &repository.root, &["."]).unwrap();

        fs::write(path, b"two").unwrap();
        let second = source_identity(&repository.root, &repository.root, &["."]).unwrap();

        assert!(first.contains("-dirty-"));
        assert!(second.contains("-dirty-"));
        assert_ne!(first, second);
    }

    #[cfg(unix)]
    #[test]
    fn dirty_identity_hashes_dangling_symlink_targets() {
        let repository = TestRepository::new("dangling-symlink");
        let link = repository.root.join("untracked-link");
        symlink("missing-one", &link).unwrap();
        let first = source_identity(&repository.root, &repository.root, &["."]).unwrap();

        fs::remove_file(&link).unwrap();
        symlink("missing-two", &link).unwrap();
        let second = source_identity(&repository.root, &repository.root, &["."]).unwrap();

        assert_ne!(first, second);
    }

    #[test]
    fn dirty_identity_fails_closed_when_git_cannot_describe_changes() {
        let repository = TestRepository::new("git-failure");
        fs::write(repository.root.join(".git/index"), b"invalid index").unwrap();

        assert!(source_identity(&repository.root, &repository.root, &["."]).is_err());
    }

    #[test]
    fn identity_and_invalidation_share_the_same_source_scope() {
        let repository = TestRepository::new("scoped");
        fs::create_dir(repository.root.join("source")).unwrap();
        fs::create_dir(repository.root.join("docs")).unwrap();
        fs::write(repository.root.join("source/input"), b"one").unwrap();
        fs::write(repository.root.join("docs/guide"), b"one").unwrap();
        run_git(&repository.root, &["add", "source", "docs"]);
        run_git(&repository.root, &["commit", "-qm", "add scoped inputs"]);
        let clean = source_identity(&repository.root, &repository.root, &["source"]).unwrap();

        fs::write(repository.root.join("docs/guide"), b"two").unwrap();
        let docs_changed =
            source_identity(&repository.root, &repository.root, &["source"]).unwrap();
        fs::write(repository.root.join("source/input"), b"two").unwrap();
        let source_changed =
            source_identity(&repository.root, &repository.root, &["source"]).unwrap();

        assert_eq!(docs_changed, clean);
        assert!(source_changed.contains("-dirty-"));
        assert_ne!(source_changed, clean);
    }

    #[test]
    fn ghostty_identity_tracks_native_package_sources() {
        let repository = TestRepository::new("ghostty-packages");
        fs::create_dir(repository.root.join("include")).unwrap();
        fs::create_dir(repository.root.join("src")).unwrap();
        fs::create_dir_all(repository.root.join("pkg/simdutf")).unwrap();
        fs::write(repository.root.join("build.zig"), b"build").unwrap();
        fs::write(repository.root.join("build.zig.zon"), b"dependencies").unwrap();
        fs::write(repository.root.join("include/ghostty.h"), b"header").unwrap();
        fs::write(repository.root.join("src/main.zig"), b"source").unwrap();
        fs::write(repository.root.join("pkg/simdutf/input"), b"one").unwrap();
        run_git(&repository.root, &["add", "."]);
        run_git(&repository.root, &["commit", "-qm", "add native inputs"]);
        let clean =
            source_identity(&repository.root, &repository.root, GHOSTTY_SOURCE_PATHS).unwrap();

        fs::write(repository.root.join("pkg/simdutf/input"), b"two").unwrap();
        let changed =
            source_identity(&repository.root, &repository.root, GHOSTTY_SOURCE_PATHS).unwrap();

        assert_ne!(changed, clean, "Ghostty package changes retained the clean build identity");
    }
}
