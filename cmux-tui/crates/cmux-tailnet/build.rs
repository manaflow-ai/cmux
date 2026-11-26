//! Links libtailscale: Tailscale's Go tsnet built as a C archive (BSD-3-Clause).
//!
//! Sources, in order:
//! - `LIBTAILSCALE_A`: a prebuilt `libtailscale.a` (CI caches one per target;
//!   it must be built from the pinned commit with `patches/` applied).
//! - `LIBTAILSCALE_SRC`: a libtailscale checkout, copied into `OUT_DIR`,
//!   patched, and built with `go build -buildmode=c-archive`.
//! - otherwise the pinned upstream commit, fetched once into a shared cache
//!   (`LIBTAILSCALE_CACHE`, else `$CARGO_HOME`, else `~/.cargo`, under
//!   `cmux-libtailscale/<pin>`; retried 3 times), is copied into `OUT_DIR`,
//!   patched and built. Each target and each clean build reuses that one fetch:
//!   a fetch per fresh `OUT_DIR` made a universal build reach GitHub twice and a
//!   proxy timeout failed it (hq run 45866961331, 2026-11-26).
//!
//! The pin is the only place the Tailscale version is chosen; bump it on
//! purpose, never float it. `patches/*.patch` are applied in name order.
//! Building from source needs Go: `go-version` beside this file names the
//! version the pinned go.mod requires, and CI installs exactly that one.
//! Bump it with the pin.

use std::path::{Path, PathBuf};
use std::process::Command;

const REPO: &str = "https://github.com/tailscale/libtailscale";
const PINNED: &str = "d1dc45d039edb7759ecbee6ba2aea0c4bca884b8";

fn main() {
    if std::env::var("CARGO_CFG_UNIX").is_err() {
        return;
    }
    println!("cargo:rerun-if-env-changed=LIBTAILSCALE_A");
    println!("cargo:rerun-if-env-changed=LIBTAILSCALE_SRC");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let key = patch_key();
    let archive = match std::env::var_os("LIBTAILSCALE_A") {
        Some(path) => PathBuf::from(path),
        None => {
            let source = match std::env::var_os("LIBTAILSCALE_SRC") {
                Some(path) => copy_source(&PathBuf::from(path), &out),
                None => fetch_pinned(&out, &key),
            };
            patch(&source, &key);
            build(&source, &out)
        }
    };
    let folder = archive.parent().expect("archive folder");
    println!("cargo:rustc-link-search=native={}", folder.display());
    println!("cargo:rustc-link-lib=static=tailscale");
    match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("macos") | Ok("ios") => {
            for framework in ["CoreFoundation", "Security", "SystemConfiguration", "IOKit"] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
            println!("cargo:rustc-link-lib=resolv");
        }
        Ok("linux") => {
            println!("cargo:rustc-link-lib=pthread");
            println!("cargo:rustc-link-lib=resolv");
        }
        _ => {}
    }
}

fn fetch_pinned(out: &Path, key: &str) -> PathBuf {
    let source = out.join(format!("libtailscale-{}", &PINNED[..12]));
    if std::fs::read_to_string(source.join(".cmux-patched")).is_ok_and(|done| done == key) {
        return source;
    }
    let _ = std::fs::remove_dir_all(&source);
    let pristine = pristine_source(out);
    run(Command::new("cp").arg("-R").arg(&pristine).arg(&source));
    source
}

/// Where the unpatched pinned checkout is kept across targets and clean builds.
fn cache_root(out: &Path) -> PathBuf {
    let home = tracked_env("LIBTAILSCALE_CACHE")
        .map(PathBuf::from)
        .or_else(|| {
            tracked_env("CARGO_HOME").map(|home| PathBuf::from(home).join("cmux-libtailscale"))
        })
        .or_else(|| {
            std::env::var_os("HOME")
                .map(|home| PathBuf::from(home).join(".cargo/cmux-libtailscale"))
        });
    match home {
        Some(root) if std::fs::create_dir_all(&root).is_ok() => root,
        _ => out.to_path_buf(),
    }
}

/// The pinned commit, fetched once and never patched in place. A build script
/// fetches into its own temporary folder and renames it in, so concurrent
/// build scripts (one per target) never see a half-made checkout.
fn pristine_source(out: &Path) -> PathBuf {
    const DONE: &str = ".cmux-pristine";
    let root = cache_root(out);
    let cached = root.join(PINNED);
    if cached.join(DONE).is_file() {
        return cached;
    }
    let tmp = root.join(format!(".{}-{}.tmp", &PINNED[..12], std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    run(Command::new("git").args(["init", "-q"]).arg(&tmp));
    fetch_with_retry(&tmp);
    run(Command::new("git").arg("-C").arg(&tmp).args(["checkout", "-q", "FETCH_HEAD"]));
    std::fs::write(tmp.join(DONE), PINNED).expect("pristine marker");
    if std::fs::rename(&tmp, &cached).is_err() {
        // Another build script renamed its fetch in first: use that one.
        let _ = std::fs::remove_dir_all(&tmp);
        assert!(
            cached.join(DONE).is_file(),
            "libtailscale cache {} is not a finished fetch",
            cached.display()
        );
    }
    cached
}

/// A shallow fetch of the pin, 3 tries with backoff: one proxy timeout must not
/// fail a build. The panic names the URL and git's own words.
fn fetch_with_retry(source: &Path) {
    let mut last = String::new();
    for attempt in 1..=3u64 {
        let output = Command::new("git")
            .arg("-C")
            .arg(source)
            .args(["fetch", "-q", "--depth", "1", REPO, PINNED])
            .output()
            .unwrap_or_else(|error| panic!("git fetch {REPO} {PINNED}: {error}"));
        if output.status.success() {
            return;
        }
        last = String::from_utf8_lossy(&output.stderr).trim().to_string();
        println!("cargo:warning=libtailscale fetch {attempt}/3 from {REPO} failed: {last}");
        if attempt < 3 {
            std::thread::sleep(std::time::Duration::from_secs(5 * attempt));
        }
    }
    panic!(
        "could not fetch libtailscale {PINNED} from {REPO} after 3 tries: {last}; \
         set LIBTAILSCALE_SRC to a checkout or LIBTAILSCALE_A to a prebuilt archive"
    );
}

fn copy_source(from: &Path, out: &Path) -> PathBuf {
    println!("cargo:rerun-if-changed={}", from.display());
    let source = out.join("libtailscale-src");
    let _ = std::fs::remove_dir_all(&source);
    run(Command::new("cp").arg("-R").arg(from).arg(&source));
    source
}

fn patches() -> Vec<PathBuf> {
    // Read at run time, not with env!: a reused build script binary would
    // look in its old checkout and silently find no patches.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let folder = Path::new(&manifest_dir).join("patches");
    println!("cargo:rerun-if-changed={}", folder.display());
    let mut patches: Vec<PathBuf> = std::fs::read_dir(&folder)
        .map(|entries| entries.filter_map(|entry| entry.ok().map(|entry| entry.path())).collect())
        .unwrap_or_default();
    patches.retain(|path| path.extension().is_some_and(|ext| ext == "patch"));
    patches.sort();
    patches
}

/// The pin plus the patch set: a cached source with another key is fetched again.
fn patch_key() -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for patch in patches() {
        std::fs::read(&patch).expect("patch file").hash(&mut hasher);
    }
    format!("{PINNED} {:016x}", hasher.finish())
}

/// Applies `patches/` once per key (a marker file records it).
fn patch(source: &Path, key: &str) {
    let marker = source.join(".cmux-patched");
    if std::fs::read_to_string(&marker).is_ok_and(|done| done == key) {
        return;
    }
    for patch in patches() {
        run(Command::new("git")
            .arg("-C")
            .arg(source)
            .args(["apply", "--whitespace=nowarn"])
            .arg(&patch));
    }
    std::fs::write(marker, key).expect("patch marker");
}

fn build(source: &Path, out: &Path) -> PathBuf {
    let archive = out.join("libtailscale.a");
    let mut go = Command::new(std::env::var("GO").unwrap_or_else(|_| "go".into()));
    go.current_dir(source)
        .env("CGO_ENABLED", "1")
        .args(["build", "-trimpath", "-buildmode=c-archive", "-o"])
        .arg(&archive);
    configure_target(&mut go);
    match go.status() {
        Ok(status) => assert!(status.success(), "{go:?} failed: {status}"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => panic!(
            "cmux-tailnet needs Go {} to build libtailscale, and `{}` was not found: \
             install it (CI: actions/setup-go with crates/cmux-tailnet/go-version), \
             set GO to its path, or set LIBTAILSCALE_A to a prebuilt archive",
            include_str!("go-version").trim(),
            go.get_program().to_string_lossy(),
        ),
        Err(error) => panic!("{go:?}: {error}"),
    }
    archive
}

/// Cargo chooses the target; host Go defaults must never choose the archive ABI.
fn configure_target(go: &mut Command) {
    let target = std::env::var("TARGET").expect("Cargo target");
    let host = std::env::var("HOST").expect("Cargo host");
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").expect("target architecture");
    let os = std::env::var("CARGO_CFG_TARGET_OS").expect("target OS");
    let goarch = match arch.as_str() {
        "aarch64" => "arm64",
        "x86_64" => "amd64",
        _ => panic!("unsupported libtailscale architecture: {arch}"),
    };
    let goos = match os.as_str() {
        "macos" => "darwin",
        "linux" => "linux",
        _ => panic!("unsupported libtailscale OS: {os}"),
    };
    go.env("GOARCH", goarch).env("GOOS", goos);
    let underscored = target.replace('-', "_");
    let compiler =
        [format!("CC_{target}"), format!("CC_{underscored}"), "TARGET_CC".into(), "CC".into()]
            .into_iter()
            .find_map(|key| tracked_env(&key));
    if let Some(compiler) = compiler {
        go.env("CC", compiler);
    } else if os == "macos" && host.ends_with("-apple-darwin") {
        go.env("CC", "clang");
    } else if target != host {
        panic!("cross-compiling libtailscale requires CC_{underscored} (a target C compiler)");
    }
    for key in ["GO", "GOOS", "GOARCH", "SDKROOT", "CGO_ENABLED", "MACOSX_DEPLOYMENT_TARGET"] {
        println!("cargo:rerun-if-env-changed={key}");
    }
    if os == "macos" {
        let minimum = tracked_env("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|| "14.0".into());
        go.env("MACOSX_DEPLOYMENT_TARGET", &minimum);
        let apple_arch = if arch == "aarch64" { "arm64" } else { "x86_64" };
        for key in ["CGO_CFLAGS", "CGO_LDFLAGS"] {
            let existing = tracked_env(key).unwrap_or_default();
            go.env(key, format!("{existing} -arch {apple_arch} -mmacosx-version-min={minimum}"));
        }
    }
}

fn tracked_env(key: &str) -> Option<String> {
    println!("cargo:rerun-if-env-changed={key}");
    std::env::var(key).ok().filter(|value| !value.is_empty())
}

fn run(command: &mut Command) {
    let status = command.status().unwrap_or_else(|error| panic!("{command:?}: {error}"));
    assert!(status.success(), "{command:?} failed: {status}");
}
