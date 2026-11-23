//! A person's additions since the image (plans/cloud/images-per-user.md in cmuxterm-hq, step 2), sent to
//! cmux-platform only under their opt-in usage-sharing setting, which is off by default.
//!
//! Leo, 2026-11-22: "we can get more ambitious with the leo-proxy and leo-shadow ideas ... im sure we can find ways
//! to increase the parallel work we can do. well, if not parallel, then like... pursuits."
//!
//! Once per idle period of the machine (no session, no turn, no workload: what the Cloud reads as idle), at most once
//! per [`MIN_GAP_MS`]:
//!
//! 1. `GET {platform}/v1/install-counts/consent` as this machine. Anything but `200 {"share": true}` (a 404 is the
//!    surface off) ends the run: nothing is collected and nothing is sent.
//! 2. Without the image's baseline ([`IMAGE_PACKAGES`]) nothing is collected or sent.
//! 3. [`collect_command`] lists the package names added since the image, `kind name` lines (the same shell as
//!    `web/scripts/cmux-vm-image/layers.ts` `userAdditionsCommand()`: keep the two alike). Names only: no versions,
//!    paths or arguments.
//! 4. The lines become `kind:name` keys ([`keys`]): sorted, deduplicated, a key the platform would refuse dropped, at
//!    most [`MAX_KEYS`]. When they equal the last list the platform accepted, nothing is sent.
//! 5. `PUT {platform}/v1/install-counts/additions` with `{"additions": [...]}`, the whole list (it replaces the
//!    person's previous one).

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::sender::Answer;

/// The owner's choice (cmux-platform `src/api/InstallCounts.ts`).
pub const CONSENT_PATH: &str = "/v1/install-counts/consent";
/// The owner's whole additions list.
pub const ADDITIONS_PATH: &str = "/v1/install-counts/additions";
/// The image's package names, written at finalize (`layers.ts` `IMAGE_PACKAGES_PATH`).
pub const IMAGE_PACKAGES: &str = "/etc/cmux/image-packages.txt";
/// The platform takes at most this many keys.
pub const MAX_KEYS: usize = 500;
/// The platform's key length bound.
pub const MAX_KEY_LEN: usize = 64;
/// Two runs are at least this far apart, so a machine that flaps between busy and idle reads its consent and its
/// packages at most four times an hour.
pub const MIN_GAP_MS: u64 = 15 * 60 * 1000;

/// The shell that prints the person's additions as `kind name` lines: `layers.ts` `userAdditionsCommand(home)`, with
/// the baseline at `baseline`.
pub fn collect_command(home: &str, baseline: &str) -> String {
    let now = [
        "dpkg-query -W -f='apt ${Package}\\n'".to_owned(),
        "npm ls -g --depth=0 --parseable 2>/dev/null | sed -n 's#.*/node_modules/#npm #p'"
            .to_owned(),
        format!("ls {home}/.bun/install/global/node_modules 2>/dev/null | sed 's#^#bun #'"),
        format!("ls {home}/.local/share/uv/tools 2>/dev/null | sed 's#^#uv #'"),
        format!("ls {home}/.local/pipx/venvs 2>/dev/null | sed 's#^#pipx #'"),
        format!("ls {home}/.cargo/bin 2>/dev/null | sed 's#^#cargo #'"),
    ];
    format!("{{ {}; }} | LC_ALL=C sort -u | LC_ALL=C comm -13 {baseline} -", now.join("; "))
}

/// Whether the platform takes `key`: `^[A-Za-z0-9._:/-]{1,64}$` with at most one `/`.
pub fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= MAX_KEY_LEN
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:/-".contains(&b))
        && key.bytes().filter(|b| *b == b'/').count() <= 1
}

/// `kind name` lines as `kind:name` keys: sorted, deduplicated, invalid ones dropped, at most [`MAX_KEYS`].
pub fn keys(lines: &str) -> Vec<String> {
    let set: BTreeSet<String> = lines
        .lines()
        .filter_map(|line| {
            let (kind, name) = line.trim().split_once(' ')?;
            Some(format!("{kind}:{}", name.trim()))
        })
        .filter(|key| valid_key(key))
        .collect();
    set.into_iter().take(MAX_KEYS).collect()
}

/// One idle period's single run: true the first time the machine reads idle in a period, unless the last run was
/// under [`MIN_GAP_MS`] ago (it then fires later in the same period, once the gap has passed).
#[derive(Debug, Default)]
pub struct IdleEdge {
    fired_this_period: bool,
    last_fired_at: Option<u64>,
}

impl IdleEdge {
    /// `idle` as the latest probe read it, at monotonic `now` ms.
    pub fn observe(&mut self, idle: bool, now: u64) -> bool {
        if !idle {
            self.fired_this_period = false;
            return false;
        }
        if self.fired_this_period || self.last_fired_at.is_some_and(|at| now < at + MIN_GAP_MS) {
            return false;
        }
        self.fired_this_period = true;
        self.last_fired_at = Some(now);
        true
    }
}

/// What one run did (logged; never a name from the list).
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Consent is not on, or the surface is off: nothing collected, nothing sent.
    NotShared,
    /// The consent read failed: nothing collected, nothing sent.
    ConsentUnread(String),
    /// No baseline, or the collection failed: nothing sent.
    NotCollected,
    /// The list equals the last one the platform accepted.
    Unchanged,
    /// The platform accepted a list of this many keys.
    Sent(usize),
    /// The platform did not accept it; the next idle period tries again.
    Refused(String),
}

/// The last list the platform accepted, for the unchanged check.
#[derive(Debug, Default)]
pub struct Sent(Option<Vec<String>>);

fn describe(answer: &Answer) -> String {
    match answer {
        Answer::Http { status, body } => {
            let code = body.get("code").and_then(Value::as_str).unwrap_or("");
            format!("HTTP {status} {code}").trim_end().to_owned()
        }
        Answer::Transport => "transport".to_owned(),
    }
}

/// One run: consent first, then `collect` (the `kind name` lines, or `None` without a baseline or on failure), then
/// at most one PUT.
pub fn run_once<H: Http>(
    client: &mut CloudClient<H>,
    collect: impl FnOnce() -> Option<String>,
    sent: &mut Sent,
    now_wall_ms: u64,
) -> Outcome {
    let consent = client.platform_answer("GET", CONSENT_PATH, None, now_wall_ms);
    match &consent {
        Answer::Http { status: 200, body } if body.get("share") == Some(&Value::Bool(true)) => {}
        Answer::Http { status: 200 | 403 | 404, .. } => return Outcome::NotShared,
        other => return Outcome::ConsentUnread(describe(other)),
    }
    let Some(lines) = collect() else { return Outcome::NotCollected };
    let list = keys(&lines);
    if sent.0.as_ref() == Some(&list) {
        return Outcome::Unchanged;
    }
    let body = json!({ "additions": list });
    match client.platform_answer("PUT", ADDITIONS_PATH, Some(&body), now_wall_ms) {
        Answer::Http { status: 200, .. } => {
            let n = list.len();
            sent.0 = Some(list);
            Outcome::Sent(n)
        }
        // Consent went off between the read and the send.
        Answer::Http { status: 403, body }
            if body.get("code").and_then(Value::as_str) == Some("install_counts.not_shared") =>
        {
            Outcome::NotShared
        }
        other => Outcome::Refused(describe(&other)),
    }
}

/// The collection on this machine: the shell under `sh`, at the lowest CPU priority, bounded by `timeout`.
#[cfg(unix)]
pub fn collect_on_machine(
    paths: &crate::config::Paths,
    home: &str,
    timeout: std::time::Duration,
) -> Option<String> {
    use cmux_process::{Command, Stdio};
    use std::io::Read as _;
    use std::os::fd::AsRawFd as _;
    let baseline = paths.at(IMAGE_PACKAGES);
    if !baseline.is_file() {
        return None;
    }
    let command = collect_command(home, baseline.to_str()?);
    // Its own process group: a timeout (or this thread ending) ends the shell and everything it started.
    let mut child = Command::new("nice")
        .args(["-n", "19", "sh", "-c", &command])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    // Read while it runs, without blocking, so a full pipe never stalls the shell.
    // SAFETY: fcntl on the pipe's own open descriptor.
    unsafe {
        let fd = stdout.as_raw_fd();
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return None;
        }
    }
    // At most 1 MiB: 500 keys of 64 bytes fit many times over.
    const MAX_OUT: usize = 1024 * 1024;
    let mut out = Vec::new();
    let mut buf = [0u8; 8192];
    let mut drain = |out: &mut Vec<u8>| loop {
        match stdout.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => out.extend_from_slice(
                buf.get(..n.min(MAX_OUT.saturating_sub(out.len()))).unwrap_or(&[]),
            ),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    };
    let deadline = std::time::Instant::now() + timeout;
    let status = loop {
        drain(&mut out);
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            _ => break None,
        }
    };
    drain(&mut out);
    // A shell past its deadline: the dropped `Child` ends its group and reaps it.
    if !status?.success() {
        return None;
    }
    String::from_utf8(out).ok()
}

/// The thread that runs [`run_once`] when the worker says the machine went idle. Dropping it ends the thread.
#[cfg(unix)]
pub struct Additions {
    idle: std::sync::mpsc::SyncSender<()>,
}

#[cfg(unix)]
impl Additions {
    pub fn spawn<H: Http + Send + 'static>(
        mut client: CloudClient<H>,
        paths: crate::config::Paths,
        home: &'static str,
        now_wall_ms: fn() -> u64,
        log: fn(&str),
    ) -> std::io::Result<Additions> {
        // One run waits at most: an idle period that starts while a run is in flight is dropped.
        let (tx, rx) = std::sync::mpsc::sync_channel::<()>(1);
        std::thread::Builder::new().name("cmux-host-additions".to_owned()).spawn(move || {
            let mut sent = Sent::default();
            while rx.recv().is_ok() {
                let collect =
                    || collect_on_machine(&paths, home, std::time::Duration::from_secs(120));
                match run_once(&mut client, collect, &mut sent, now_wall_ms()) {
                    // The default: no line for it, idle period after idle period.
                    Outcome::NotShared => {}
                    Outcome::Sent(n) => log(&format!("additions: sent {n} names (shared)")),
                    other => log(&format!("additions: {other:?}")),
                }
            }
        })?;
        Ok(Additions { idle: tx })
    }

    /// The machine went idle: one run, unless one is already waiting.
    pub fn idle(&self) {
        let _ = self.idle.try_send(());
    }
}
