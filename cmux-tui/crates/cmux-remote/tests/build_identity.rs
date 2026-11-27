use std::env;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const BUILD_COMMIT_ENV: &str = "CMUX_TUI_BUILD_COMMIT";
const BUILD_IDENTITY_PREFIX: &str = "cargo:rustc-env=CMUX_TUI_BUILD_IDENTITY=";

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct BuildFixture {
    root: PathBuf,
    manifest_dir: PathBuf,
    executable: PathBuf,
}

impl BuildFixture {
    fn new() -> Self {
        let unique = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock is before the Unix epoch")
            .as_nanos();
        let root = env::temp_dir()
            .join(format!("cmux-build-identity-{}-{nanos}-{unique}", std::process::id()));
        let manifest_dir = root.join("cmux-tui/crates/cmux-remote");
        fs::create_dir_all(&manifest_dir).unwrap();
        fs::write(root.join(".gitignore"), "cmux-tui/target/\n").unwrap();
        fs::write(root.join("cmux-tui/source.txt"), "clean\n").unwrap();
        fs::write(
            manifest_dir.join("Cargo.toml"),
            "[package]\nname = \"cmux-build-identity-fixture\"\nversion = \"0.0.0\"\nedition = \"2024\"\n\n[build-dependencies]\ncmux-tui-source-watch = { path = \"../..\" }\n",
        )
        .unwrap();
        fs::write(
            root.join("cmux-tui/Cargo.toml"),
            "[package]\nname = \"cmux-tui-source-watch\"\nversion = \"0.0.0\"\nedition = \"2024\"\nbuild = \"source-watch-build.rs\"\n\n[lib]\npath = \"source-watch.rs\"\n\n[workspace]\nmembers = [\"crates/cmux-remote\"]\nresolver = \"2\"\n",
        )
        .unwrap();
        fs::write(root.join("cmux-tui/source-watch.rs"), "pub const ACTIVE: () = ();\n").unwrap();
        fs::write(root.join("cmux-tui/source-watch-build.rs"), "fn main() {}\n").unwrap();
        fs::create_dir_all(manifest_dir.join("src")).unwrap();
        fs::write(
            manifest_dir.join("src/main.rs"),
            "fn main() { println!(\"{}\", env!(\"CMUX_TUI_BUILD_IDENTITY\")); }\n",
        )
        .unwrap();
        fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("build.rs"),
            manifest_dir.join("build.rs"),
        )
        .unwrap();
        let lockfile = Command::new(env::var_os("CARGO").unwrap_or_else(|| "cargo".into()))
            .arg("generate-lockfile")
            .arg("--manifest-path")
            .arg(manifest_dir.join("Cargo.toml"))
            .output()
            .unwrap();
        assert_success("generate fixture lockfile", &lockfile);

        run_git(&root, ["init", "--quiet"]);
        run_git(&root, ["add", "."]);
        run_git(
            &root,
            [
                "-c",
                "user.name=cmux test",
                "-c",
                "user.email=cmux@example.test",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--quiet",
                "-m",
                "fixture",
            ],
        );

        let executable = root.join(format!("build-script{}", env::consts::EXE_SUFFIX));
        let source_watch = root.join("libcmux_tui_source_watch.rlib");
        let output = Command::new(env::var_os("RUSTC").unwrap_or_else(|| "rustc".into()))
            .arg("--crate-name=cmux_tui_source_watch")
            .arg("--crate-type=rlib")
            .arg(root.join("cmux-tui/source-watch.rs"))
            .arg("-o")
            .arg(&source_watch)
            .output()
            .unwrap();
        assert_success("compile source watcher", &output);
        let output = Command::new(env::var_os("RUSTC").unwrap_or_else(|| "rustc".into()))
            .arg("--edition=2024")
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("build.rs"))
            .arg("--extern")
            .arg(format!("cmux_tui_source_watch={}", source_watch.display()))
            .arg("-o")
            .arg(&executable)
            .output()
            .unwrap();
        assert_success("compile build.rs", &output);

        Self { root, manifest_dir, executable }
    }

    fn source_path(&self) -> PathBuf {
        self.root.join("cmux-tui/source.txt")
    }

    fn write_source(&self, contents: &str) {
        fs::write(self.source_path(), contents).unwrap();
    }

    fn head(&self) -> String {
        let output = Command::new("git")
            .current_dir(&self.root)
            .args(["rev-parse", "HEAD"])
            .output()
            .unwrap();
        assert_success("read fixture HEAD", &output);
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    }

    fn run_output(&self, override_identity: Option<&str>) -> Output {
        let mut command = Command::new(&self.executable);
        command.env("CARGO_MANIFEST_DIR", &self.manifest_dir).env_remove(BUILD_COMMIT_ENV);
        if let Some(identity) = override_identity {
            command.env(BUILD_COMMIT_ENV, identity);
        }
        command.output().unwrap()
    }

    fn run(&self, override_identity: Option<&str>) -> String {
        let output = self.run_output(override_identity);
        assert_success("run build.rs", &output);
        String::from_utf8(output.stdout).unwrap()
    }

    fn identity(&self, override_identity: Option<&str>) -> String {
        self.run(override_identity)
            .lines()
            .find_map(|line| line.strip_prefix(BUILD_IDENTITY_PREFIX))
            .expect("build script did not emit a build identity")
            .to_owned()
    }

    fn cargo_identity_with_log(&self) -> (String, String) {
        let target = self.root.join("cargo-target");
        let output = Command::new(env::var_os("CARGO").unwrap_or_else(|| "cargo".into()))
            .arg("build")
            .arg("--verbose")
            .arg("--manifest-path")
            .arg(self.manifest_dir.join("Cargo.toml"))
            .arg("--target-dir")
            .arg(&target)
            .output()
            .unwrap();
        assert_success("build fixture with Cargo", &output);
        let cargo_log = String::from_utf8(output.stderr).unwrap();
        let binary = target
            .join("debug")
            .join(format!("cmux-build-identity-fixture{}", env::consts::EXE_SUFFIX));
        let output = Command::new(binary).output().unwrap();
        assert_success("run Cargo-built fixture", &output);
        (String::from_utf8(output.stdout).unwrap().trim().to_owned(), cargo_log)
    }

    fn cargo_identity(&self) -> String {
        self.cargo_identity_with_log().0
    }
}

impl Drop for BuildFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn run_git<I, S>(root: &Path, arguments: I)
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = Command::new("git").current_dir(root).args(arguments).output().unwrap();
    assert_success("run git", &output);
}

fn assert_success(action: &str, output: &Output) {
    assert!(
        output.status.success(),
        "{action} failed with {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn dirty_source_states_at_one_head_have_distinct_identities() {
    let fixture = BuildFixture::new();
    let head = fixture.head();
    assert_eq!(fixture.identity(None), head, "a clean build did not use its exact HEAD");

    fixture.write_source("dirty state one\n");
    let first = fixture.identity(None);
    assert_eq!(fixture.identity(None), first, "one dirty source state was not deterministic");
    fixture.write_source("dirty state two\n");
    let second = fixture.identity(None);

    assert_ne!(first, head, "a dirty build reused its clean HEAD identity");
    assert_ne!(second, head, "a dirty build reused its clean HEAD identity");
    assert_ne!(first, second, "two dirty source states at the same HEAD shared an identity");

    fixture.write_source("clean\n");
    let untracked = fixture.root.join("cmux-tui/new-source.rs");
    fs::write(&untracked, "const STATE: u8 = 1;\n").unwrap();
    let untracked_first = fixture.identity(None);
    fs::write(&untracked, "const STATE: u8 = 2;\n").unwrap();
    let untracked_second = fixture.identity(None);

    assert_ne!(
        untracked_first, untracked_second,
        "two untracked source states at the same HEAD shared an identity"
    );
}

#[test]
fn release_override_remains_exact_and_stable_for_dirty_sources() {
    let fixture = BuildFixture::new();

    fixture.write_source("dirty state one\n");
    assert_eq!(fixture.identity(Some("release-build-identity")), "release-build-identity");
    fixture.write_source("dirty state two\n");
    assert_eq!(fixture.identity(Some("release-build-identity")), "release-build-identity");
}

#[test]
fn cargo_tracks_source_inputs_without_watching_target() {
    let fixture = BuildFixture::new();
    let untracked_source = fixture.root.join("cmux-tui/new-source.rs");
    fs::write(&untracked_source, "const NEW_SOURCE: bool = true;\n").unwrap();
    let target_file = fixture.root.join("cmux-tui/target/generated");
    fs::create_dir_all(target_file.parent().unwrap()).unwrap();
    fs::write(&target_file, "ignored build output\n").unwrap();

    let output = fixture.run(None);
    let tracked: Vec<_> =
        output.lines().filter_map(|line| line.strip_prefix("cargo:rerun-if-changed=")).collect();
    let source_path = fixture.source_path().canonicalize().unwrap();
    let untracked_source = untracked_source.canonicalize().unwrap();
    let target_dir = target_file.parent().unwrap().canonicalize().unwrap();

    assert!(
        tracked.iter().any(|path| Path::new(path) == source_path),
        "Cargo did not track the source input: {tracked:?}"
    );
    assert!(
        tracked.iter().any(|path| Path::new(path) == untracked_source),
        "Cargo did not track the untracked source input: {tracked:?}"
    );
    assert!(
        tracked.iter().all(|path| !Path::new(path).starts_with(&target_dir)),
        "Cargo watched target output: {tracked:?}"
    );
}

#[test]
fn incremental_cargo_detects_a_new_top_level_input_with_ignored_target_present() {
    let fixture = BuildFixture::new();
    let ignored_output = fixture.root.join("cmux-tui/target/generated");
    fs::create_dir_all(ignored_output.parent().unwrap()).unwrap();
    fs::write(ignored_output, "ignored build output\n").unwrap();
    let clean = fixture.cargo_identity();
    assert_eq!(clean, fixture.head(), "the initial Cargo build was not clean");

    let untracked = fixture.root.join("cmux-tui/new-source.rs");
    fs::write(&untracked, "const NEW_SOURCE: bool = true;\n").unwrap();
    let dirty = fixture.cargo_identity();

    assert_ne!(dirty, clean, "Cargo reused a build identity that omitted a new source input");

    let (stable, cargo_log) = fixture.cargo_identity_with_log();
    assert_eq!(stable, dirty, "an unchanged source tree changed build identity");
    assert!(
        !cargo_log.contains("Compiling cmux-build-identity-fixture"),
        "an unchanged source tree rebuilt cmux-build-identity-fixture:\n{cargo_log}"
    );
}

#[cfg(unix)]
#[test]
fn cargo_directive_paths_reject_cr_and_lf() {
    for (name, line_break) in [("carriage return", '\r'), ("line feed", '\n')] {
        let fixture = BuildFixture::new();
        let source =
            fixture.root.join(format!("cmux-tui/directive{line_break}cargo:warning=injected.rs"));
        fs::write(source, "const INJECTED: bool = true;\n").unwrap();

        let output = fixture.run_output(None);
        assert!(
            !output.status.success(),
            "build script accepted a source path containing {name}\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("Cargo directive path contains a control character"),
            "build script rejected {name} for an unexpected reason\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
