//! The session service: what `cmux server install` writes when it keeps one
//! cmux session daemon running instead of the full store-managed server
//! (no published server channel for this machine, or `--binary`). The unit
//! runs `<binary> daemon start --session <session> --terminal-reap-grace-seconds
//! 30`, the daemon that cmux clients reach over SSH, so its sessions outlive
//! logouts and reboots.

/// The session cmux clients open over SSH by default.
pub const DEFAULT_SESSION: &str = "main";

/// Where the service's binary lives, relative to the home directory: the
/// path every cmux client probes, installs and upgrades over SSH, so a
/// client's upgrade is the binary the service runs at its next start.
pub const SESSION_BINARY: &str = ".local/bin/cmux-tui";

/// `[A-Za-z0-9._-]{1,64}`, not starting with `.` or `-`: safe as a unit
/// argument, a plist string, a shell word and a socket file name.
pub fn valid_session_name(session: &str) -> bool {
    let bytes = session.as_bytes();
    (1..=64).contains(&bytes.len())
        && !matches!(bytes.first(), Some(b'.' | b'-'))
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// How long the service's daemon keeps a terminal whose last tab closed
/// (Reopen Closed attaches to it until then): the grace every owner that
/// `daemon ensure` starts gets (cmux-tui-core `DEFAULT_TERMINAL_REAP_GRACE`).
/// A direct `daemon start` owner reaps only when told to; without it a closed
/// workspace's shells ran until the service stopped, holding their PTYs and
/// keeping `daemon stop --if-idle` from ever stopping.
pub const SESSION_REAP_GRACE_SECONDS: &str = "30";

/// The arguments after the session in what the service runs.
const REAP_GRACE_ARGS: [&str; 2] = ["--terminal-reap-grace-seconds", SESSION_REAP_GRACE_SECONDS];

/// `<binary> daemon start --session <session> --terminal-reap-grace-seconds 30`.
pub fn session_argv(binary: &str, session: &str) -> Vec<String> {
    [binary, "daemon", "start", "--session", session]
        .into_iter()
        .chain(REAP_GRACE_ARGS)
        .map(str::to_owned)
        .collect()
}

/// A session service read back from its unit or plist text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionUnit {
    pub binary: String,
    pub session: String,
}

/// The binary and session of a unit or plist this module wrote; `None` for
/// any other text (a store-managed `host run` unit, a hand-written one).
pub fn parse_session_unit(text: &str) -> Option<SessionUnit> {
    if let Some(line) = text.lines().find_map(|l| l.strip_prefix("ExecStart=\"")) {
        let (binary, rest) = line.split_once('"')?;
        let rest = rest.strip_prefix(" daemon start --session ")?;
        // An earlier install wrote no reap grace; nothing else may follow.
        let grace = format!(" {}", REAP_GRACE_ARGS.join(" "));
        let session = rest.strip_suffix(grace.as_str()).unwrap_or(rest);
        return valid_session_name(session)
            .then(|| SessionUnit { binary: binary.to_owned(), session: session.to_owned() });
    }
    // The plist: ProgramArguments is the only array of five strings.
    let strings: Vec<&str> = text
        .lines()
        .filter_map(|l| l.trim().strip_prefix("<string>")?.strip_suffix("</string>"))
        .collect();
    let at = strings
        .windows(4)
        .position(|w| w.get(1..) == Some(&["daemon", "start", "--session"][..]))?;
    let session = strings.get(at + 4)?;
    let binary = *strings.get(at)?;
    (valid_session_name(session) && binary.starts_with('/') && !binary.contains('&'))
        .then(|| SessionUnit { binary: binary.to_owned(), session: (*session).to_owned() })
}
