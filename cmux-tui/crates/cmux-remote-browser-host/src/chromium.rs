//! The headless Chromium a Linux host drives (docs/remote-browser-on-vm.md):
//! found, started with `--remote-debugging-pipe` (it reads commands on fd 3
//! and writes answers and events on fd 4), and read on a thread of its own.
//! No debugging port opens. The child leads its own process group, so its
//! drop ends Chromium and every helper it started.

use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;

use serde_json::Value;

use crate::cdp::{CdpSink, PipeDeframer, encode_command};

/// Where the binary comes from, first match wins: `CMUX_RB_CHROMIUM`, then
/// `CMUX_CHROME_HEADLESS_SHELL` (what `scripts/ci/ensure-system-chrome.sh`
/// prints), then `chrome-headless-shell` next to this binary (the installed
/// layout), then these names on `PATH`.
pub const PATH_NAMES: &[&str] = &[
    "chrome-headless-shell",
    "chromium",
    "chromium-browser",
    "google-chrome",
    "google-chrome-stable",
];

/// The Chromium binary to run, if there is one.
pub fn find() -> Option<PathBuf> {
    for var in ["CMUX_RB_CHROMIUM", "CMUX_CHROME_HEADLESS_SHELL"] {
        if let Some(path) = std::env::var_os(var).map(PathBuf::from)
            && path.is_file()
        {
            return Some(path);
        }
    }
    let beside = std::env::current_exe().ok().and_then(|exe| {
        let dir = exe.parent()?;
        [dir.join("chrome-headless-shell"), dir.join("chrome-headless-shell/chrome-headless-shell")]
            .into_iter()
            .find(|p| p.is_file())
    });
    if beside.is_some() {
        return beside;
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .flat_map(|dir| PATH_NAMES.iter().map(move |name| dir.join(name)))
        .find(|p| p.is_file())
}

/// The profile every tab of this machine shares, so a login survives a host
/// restart: `CMUX_RB_PROFILE_DIR`, else
/// `$XDG_DATA_HOME/cmux-tui/browser-host/profiles/default` (or under
/// `~/.local/share`).
pub fn profile_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CMUX_RB_PROFILE_DIR") {
        return Some(PathBuf::from(dir));
    }
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))?;
    Some(data.join("cmux-tui/browser-host/profiles/default"))
}

/// The command line: headless, the pipe, the profile, and no first-run,
/// sync or background networking a person did not ask for.
pub fn args(profile: &Path) -> Vec<String> {
    let mut args = vec![
        "--headless".to_string(),
        "--remote-debugging-pipe".to_string(),
        format!("--user-data-dir={}", profile.display()),
        "--no-first-run".to_string(),
        "--no-default-browser-check".to_string(),
        "--disable-background-networking".to_string(),
        "--disable-sync".to_string(),
        "--disable-component-update".to_string(),
        "--hide-scrollbars".to_string(),
        "--mute-audio".to_string(),
        // The first target; tabs are made with Target.createTarget.
        "about:blank".to_string(),
    ];
    if std::env::var_os("CMUX_RB_NO_SANDBOX").is_some() {
        // Root in a container has no user namespaces for the sandbox (CI).
        args.insert(0, "--no-sandbox".to_string());
    }
    args
}

/// A running Chromium: commands go in through [`CdpSink`]; its messages
/// arrive on the channel given to [`Chromium::start`].
pub struct Chromium {
    child: cmux_process::Child,
    to_chromium: std::io::PipeWriter,
    next_id: u64,
}

impl std::fmt::Debug for Chromium {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Chromium").field("pid", &self.child.id()).finish()
    }
}

/// A message from Chromium, or the end of its pipe (it exited).
#[derive(Debug)]
pub enum FromChromium {
    Message(Value),
    Gone(String),
}

impl Chromium {
    /// Starts `binary` with [`args`] and a thread that sends each message,
    /// wrapped by `wrap`, to `events`.
    pub fn start<T: Send + 'static>(
        binary: &Path,
        profile: &Path,
        events: Sender<T>,
        wrap: fn(FromChromium) -> T,
    ) -> std::io::Result<Self> {
        std::fs::create_dir_all(profile)?;
        let (commands_read, to_chromium) = std::io::pipe()?;
        let (mut from_chromium, answers_write) = std::io::pipe()?;
        let mut cmd = cmux_process::Command::new(binary);
        cmd.args(args(profile))
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::inherit());
        cmd.inherit_fd(commands_read.as_fd(), 3)?;
        cmd.inherit_fd(answers_write.as_fd(), 4)?;
        let child = cmd.spawn()?;
        // Only the child holds its ends now: its exit ends the reader.
        drop((commands_read, answers_write));
        std::thread::Builder::new().name("chromium-pipe".into()).spawn(move || {
            let mut deframer = PipeDeframer::default();
            let mut buf = vec![0u8; 256 * 1024];
            let reason = loop {
                let n = match from_chromium.read(&mut buf) {
                    Ok(0) => break "Chromium closed its pipe".to_string(),
                    Ok(n) => n,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(e) => break format!("pipe read: {e}"),
                };
                deframer.extend(&buf[..n]);
                loop {
                    match deframer.next_message() {
                        Ok(Some(message)) => {
                            if events.send(wrap(FromChromium::Message(message))).is_err() {
                                return;
                            }
                        }
                        Ok(None) => break,
                        Err(e) => {
                            let _ = events.send(wrap(FromChromium::Gone(format!("pipe: {e:?}"))));
                            return;
                        }
                    }
                }
            };
            let _ = events.send(wrap(FromChromium::Gone(reason)));
        })?;
        Ok(Self { child, to_chromium, next_id: 1 })
    }

    pub fn pid(&self) -> u32 {
        self.child.id()
    }
}

impl CdpSink for Chromium {
    fn send(&mut self, session: Option<&str>, method: &str, params: Value) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let bytes = encode_command(id, session, method, &params);
        // A write to an exited Chromium fails; the reader reports it gone.
        if let Err(e) = self.to_chromium.write_all(&bytes) {
            eprintln!("serve: chromium {method}: {e}");
        }
        id
    }
}
