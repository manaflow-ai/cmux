//! `cmux tui …` and the terminal UI's own download (CMUX-570).
//!
//! The interactive terminal UI (src/app.rs, src/ui: the ratatui front end) is
//! the `tui` cargo feature. The app's bundled bin/cmux is built without it: the
//! app and its agents never run it, and it is the part of the binary a person
//! runs in a terminal. A build without it hands every TUI entry (bare `cmux`,
//! `cmux attach`, `cmux tui`) to a downloaded cmux-tui, which is the same
//! program with the feature on, versioned and published on its own
//! (npm/PyPI `cmux`, files.cmux.com/cmux-tui). That binary talks to the app's
//! daemon over the control socket and refuses a protocol or API skew with the
//! update command of the side that is too old (session/remote.rs
//! `skew_refusal`), so a mismatch says what to run.
//!
//! `cmux tui install` downloads it from the published manifest and checks its
//! sha256 before it is put in place; `cmux tui path` prints where it is looked
//! for. A build with the feature runs `cmux tui [ARGS]` as `cmux [ARGS]`.

use std::ffi::OsString;
use std::path::PathBuf;

/// The manifest the published cmux-tui binaries are listed in, with their sha256
/// (cmux-tui-artifacts.yml, `cmux-tui/latest/manifest.json`).
pub(crate) const DEFAULT_MANIFEST_URL: &str =
    "https://files.cmux.com/cmux-tui/latest/manifest.json";

/// What `cmux tui ARGS` asks for.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum TuiCommand {
    /// `cmux tui install [--manifest-url URL] [--force]`.
    Install { manifest_url: String, force: bool },
    /// `cmux tui path`: where the downloaded terminal UI is looked for.
    Path,
    /// `cmux tui [ARGS]`: run the terminal UI with ARGS, as bare `cmux ARGS` did.
    Run(Vec<String>),
}

/// Parses the words after `tui`.
pub(crate) fn parse(args: &[String]) -> Result<TuiCommand, String> {
    match args.first().map(String::as_str) {
        Some("install") => {
            let mut manifest_url = std::env::var("CMUX_TUI_MANIFEST_URL")
                .ok()
                .filter(|url| !url.is_empty())
                .unwrap_or_else(|| DEFAULT_MANIFEST_URL.to_string());
            let mut force = false;
            let mut rest = args[1..].iter();
            while let Some(arg) = rest.next() {
                match arg.as_str() {
                    "--force" => force = true,
                    "--manifest-url" => {
                        manifest_url = rest
                            .next()
                            .ok_or_else(|| "--manifest-url needs a URL".to_string())?
                            .clone();
                    }
                    other => {
                        return Err(format!("unknown argument to `cmux tui install`: {other}"));
                    }
                }
            }
            if !manifest_url.starts_with("https://") {
                return Err(format!("the manifest URL must be https: {manifest_url}"));
            }
            Ok(TuiCommand::Install { manifest_url, force })
        }
        Some("path") if args.len() == 1 => Ok(TuiCommand::Path),
        _ => Ok(TuiCommand::Run(args.to_vec())),
    }
}

/// The file name of the downloaded terminal UI on this platform.
fn binary_name() -> &'static str {
    if cfg!(windows) { "cmux-tui.exe" } else { "cmux-tui" }
}

/// Where `cmux tui install` puts the terminal UI: `$CMUX_TUI_HOME/bin`, else
/// `~/.cmux-tui/bin` (`%LOCALAPPDATA%\cmux-tui\bin` on Windows).
pub(crate) fn install_dir() -> Option<PathBuf> {
    if let Some(home) = std::env::var_os("CMUX_TUI_HOME").filter(|home| !home.is_empty()) {
        return Some(PathBuf::from(home).join("bin"));
    }
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA").map(|dir| PathBuf::from(dir).join("cmux-tui").join("bin"))
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("HOME")
            .filter(|home| !home.is_empty())
            .map(|home| PathBuf::from(home).join(".cmux-tui").join("bin"))
    }
}

/// The downloaded terminal UI this process hands off to: `$CMUX_TUI_BIN`, else
/// the one `cmux tui install` put in [`install_dir`]. Never this binary itself
/// (the app bundle's `cmux-tui` alias is this file), so a hand-off cannot loop.
pub(crate) fn locate() -> Option<PathBuf> {
    let candidate = std::env::var_os("CMUX_TUI_BIN")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .or_else(|| install_dir().map(|dir| dir.join(binary_name())))?;
    if !candidate.is_file() {
        return None;
    }
    let own = std::env::current_exe().ok().and_then(|exe| exe.canonicalize().ok());
    let theirs = candidate.canonicalize().ok()?;
    (own.as_deref() != Some(theirs.as_path())).then_some(candidate)
}

/// The message a build without the terminal UI prints when none is installed.
pub(crate) fn missing_message() -> String {
    let dir = install_dir()
        .map_or_else(|| "~/.cmux-tui/bin".to_string(), |dir| dir.display().to_string());
    format!(
        "This cmux is the app's command-line tool; the terminal UI is a separate download.\n\
         Install it (one command; the download is checked by sha256) into {dir}:\n\
         \n    cmux tui install\n\
         \n\
         or with npm (`npm install --global cmux`) or uv (`uv tool install cmux`).\n\
         Then run `cmux` (or `cmux tui`) again; it connects to the running cmux."
    )
}

/// Runs the downloaded terminal UI with `args` (the words after the program
/// name, `tui` already removed), waits for it and returns its exit code.
pub(crate) fn run_downloaded(args: &[OsString]) -> i32 {
    let Some(binary) = locate() else {
        eprintln!("{}", missing_message());
        return 2;
    };
    // A child in this process's group and session, with the terminal: it gets
    // the window-size and hang-up signals the terminal sends, and this process
    // only waits and passes its exit on.
    match cmux_process::Command::new(&binary).args(args).status() {
        Ok(status) => exit_code(status),
        Err(error) => {
            eprintln!("cmux: cannot run the terminal UI at {}: {error}", binary.display());
            1
        }
    }
}

/// The exit code a shell would report for `status` (128 + the signal on Unix).
fn exit_code(status: std::process::ExitStatus) -> i32 {
    #[cfg(unix)]
    if let Some(signal) = std::os::unix::process::ExitStatusExt::signal(&status) {
        return 128 + signal;
    }
    status.code().unwrap_or(1)
}

/// `cmux tui path`.
pub(crate) fn print_path() -> i32 {
    match locate() {
        Some(path) => {
            println!("{}", path.display());
            0
        }
        None => {
            eprintln!("{}", missing_message());
            1
        }
    }
}

/// The manifest's name for this platform's terminal UI binary.
pub(crate) fn manifest_binary_key(os: &str, arch: &str) -> Option<String> {
    let target = match (os, arch) {
        ("macos", "aarch64") => "aarch64-apple-darwin",
        ("macos", "x86_64") => "x86_64-apple-darwin",
        ("linux", "x86_64") => "x86_64-unknown-linux-musl",
        ("linux", "aarch64") => "aarch64-unknown-linux-musl",
        ("windows", "x86_64") => "x86_64-pc-windows-gnu",
        _ => return None,
    };
    let ext = if os == "windows" { ".exe" } else { "" };
    Some(format!("cmux-tui-{target}{ext}"))
}

/// One binary to download: its URL beside the manifest and its sha256.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ManifestEntry {
    pub(crate) url: String,
    pub(crate) sha256: String,
    pub(crate) commit: Option<String>,
}

/// Reads this platform's entry from a published manifest. The binary sits beside
/// the manifest (`<base>/cmux-tui-<target>`), as cmux-tui-artifacts.yml lays it out.
pub(crate) fn manifest_entry(
    manifest_url: &str,
    manifest: &serde_json::Value,
    key: &str,
) -> Result<ManifestEntry, String> {
    let sha256 = manifest["binaries"][key].as_str().ok_or_else(|| {
        format!("the manifest has no {key} (no terminal UI is published for this platform yet)")
    })?;
    if sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!("the manifest's sha256 for {key} is malformed"));
    }
    let base = manifest_url
        .split(['?', '#'])
        .next()
        .and_then(|url| url.rsplit_once('/'))
        .map(|(base, _)| base)
        .ok_or_else(|| format!("cannot place {key} beside {manifest_url}"))?;
    Ok(ManifestEntry {
        url: format!("{base}/{key}"),
        sha256: sha256.to_ascii_lowercase(),
        commit: manifest["commit"].as_str().map(str::to_string),
    })
}

/// The hex sha256 of `bytes`.
pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    let digest = sha2::Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `cmux tui install`.
#[cfg(unix)]
pub(crate) fn install(manifest_url: &str, force: bool) -> i32 {
    match install_inner(manifest_url, force) {
        Ok(message) => {
            println!("{message}");
            0
        }
        Err(error) => {
            eprintln!("cmux tui install: {error}");
            1
        }
    }
}

#[cfg(not(unix))]
pub(crate) fn install(_manifest_url: &str, _force: bool) -> i32 {
    eprintln!(
        "cmux tui install: not available on {}; install the terminal UI with `npm install --global cmux`",
        std::env::consts::OS
    );
    1
}

#[cfg(unix)]
fn install_inner(manifest_url: &str, force: bool) -> Result<String, String> {
    use std::io::Write as _;
    use std::os::unix::fs::PermissionsExt as _;

    let key =
        manifest_binary_key(std::env::consts::OS, std::env::consts::ARCH).ok_or_else(|| {
            format!(
                "no terminal UI is published for {} {}",
                std::env::consts::OS,
                std::env::consts::ARCH
            )
        })?;
    let dir = install_dir().ok_or("cannot find the home directory (set CMUX_TUI_HOME)")?;
    let target = dir.join(binary_name());
    if target.exists() && !force && locate().is_some() {
        return Ok(format!(
            "the terminal UI is already installed at {} (`cmux tui install --force` replaces it)",
            target.display()
        ));
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("start the download: {error}"))?;
    let (entry, bytes) = runtime.block_on(async {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(300))
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION"), " tui-install"))
            .build()
            .map_err(|error| format!("http client: {error}"))?;
        let manifest: serde_json::Value = fetch(&client, manifest_url).await.and_then(|body| {
            serde_json::from_slice(&body).map_err(|error| format!("{manifest_url}: {error}"))
        })?;
        let entry = manifest_entry(manifest_url, &manifest, &key)?;
        eprintln!("downloading {}", entry.url);
        let bytes = fetch(&client, &entry.url).await?;
        Ok::<_, String>((entry, bytes))
    })?;
    let actual = sha256_hex(&bytes);
    if actual != entry.sha256 {
        return Err(format!(
            "sha256 mismatch for {}: the manifest says {}, the download is {actual}; nothing was installed",
            entry.url, entry.sha256
        ));
    }
    std::fs::create_dir_all(&dir).map_err(|error| format!("create {}: {error}", dir.display()))?;
    // Write beside the target and rename over it: a running terminal UI keeps its file.
    let partial = dir.join(format!(".{}.{}.partial", binary_name(), std::process::id()));
    let written = (|| {
        let mut file = std::fs::File::create(&partial)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::set_permissions(&partial, std::fs::Permissions::from_mode(0o755))?;
        std::fs::rename(&partial, &target)
    })();
    if let Err(error) = written {
        let _ = std::fs::remove_file(&partial);
        return Err(format!("install {}: {error}", target.display()));
    }
    let commit =
        entry.commit.as_deref().map(|commit| format!(" from commit {commit}")).unwrap_or_default();
    Ok(format!(
        "installed the terminal UI{commit} at {} (sha256 {actual}); run `cmux` or `cmux tui`",
        target.display()
    ))
}

#[cfg(unix)]
async fn fetch(client: &reqwest::Client, url: &str) -> Result<Vec<u8>, String> {
    let response = client.get(url).send().await.map_err(|error| format!("{url}: {error}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("{url}: HTTP {status}"));
    }
    response.bytes().await.map(|bytes| bytes.to_vec()).map_err(|error| format!("{url}: {error}"))
}

#[cfg(test)]
#[path = "tui_handoff_tests.rs"]
mod tests;
