//! The dev-server ports a machine offers to open: the listeners of the
//! `machine-listening-tcp` table (`ss`, Linux `netstat`, `lsof` on a Mac, or a
//! Mac's `netstat -anp tcp`), cut to the ones a person runs.
//!
//! Every machine's daemon answers with them (`ports` beside the raw `stdout`),
//! so an own machine (joined by sign-in, or over ssh) shows a new dev server
//! the way a Cloud machine does, and the app only draws the offer ("Open
//! localhost:5173"). The rule lives here: which ports count, and each once.
//!
//! A port counts when it is outside the well-known range (below 1024) and the
//! ephemeral range (from [`EPHEMERAL_FROM`]), and no system service holds it
//! ([`SYSTEM_PROCESSES`]: AirPlay's 5000 and 7000 on a Mac, sshd, the resolver,
//! cmux's own daemons). A listener whose process the table does not name still
//! counts: an unprivileged `ss` names only the person's own processes.

use serde::Serialize;

/// The first port of the ephemeral range Linux and macOS hand out (Linux's
/// `ip_local_port_range` starts at 32768; macOS's at 49152).
pub(crate) const EPHEMERAL_FROM: u16 = 32768;
/// At most this many ports are offered.
pub(crate) const MAX_PORTS: usize = 32;

/// Listeners a system service holds, by the name the table prints (`lsof`
/// cuts a command to nine characters, `ss` to fifteen).
const SYSTEM_PROCESSES: &[&str] = &[
    "ControlCe",
    "ControlCenter",
    "rapportd",
    "sshd",
    "cupsd",
    "launchd",
    "mDNSRespo",
    "mDNSResponder",
    "systemd",
    "systemd-resolve",
    "systemd-r",
    "tailscaled",
    "cmux",
    "cmux-tui",
    "cmux-host",
    "acpmux",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Listener {
    pub port: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process: Option<String>,
}

/// The ports `table` offers, ascending, each once, at most [`MAX_PORTS`].
pub(crate) fn offered(table: &str) -> Vec<Listener> {
    let mut found: Vec<Listener> = Vec::new();
    for line in table.lines() {
        let Some(listener) = parse_line(line) else { continue };
        if !counts(&listener) {
            continue;
        }
        match found.iter_mut().find(|known| known.port == listener.port) {
            Some(known) => {
                if known.process.is_none() {
                    known.process = listener.process;
                }
            }
            None => found.push(listener),
        }
    }
    found.sort_by_key(|listener| listener.port);
    found.truncate(MAX_PORTS);
    found
}

fn counts(listener: &Listener) -> bool {
    (1024..EPHEMERAL_FROM).contains(&listener.port)
        && !listener.process.as_deref().is_some_and(|name| SYSTEM_PROCESSES.contains(&name))
}

/// One listener of one table line, or None for a header, a non-listening row
/// or a line the parser does not know.
fn parse_line(line: &str) -> Option<Listener> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    let first = *fields.first()?;
    // `lsof -nP -iTCP -sTCP:LISTEN`: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (LISTEN)
    if fields.last() == Some(&"(LISTEN)") && fields.len() >= 3 {
        let name = fields.iter().rev().nth(1)?;
        let port = port_after(name, ':')?;
        return Some(Listener { port, process: Some(unescape_lsof(first)) });
    }
    // `ss -H -ltnp`: LISTEN Recv-Q Send-Q Local:Port Peer:Port users:(("node",pid=1,fd=2))
    if first == "LISTEN" {
        let port = port_after(fields.get(3)?, ':')?;
        let process = fields.iter().find_map(|field| {
            let rest = field.strip_prefix("users:((\"")?;
            rest.split('"').next().filter(|name| !name.is_empty()).map(str::to_owned)
        });
        return Some(Listener { port, process });
    }
    // Linux `netstat -ltnp`: tcp Recv-Q Send-Q Local Foreign LISTEN PID/Program
    // A Mac's `netstat -anp tcp`: tcp4 Recv-Q Send-Q 127.0.0.1.5173 *.* LISTEN
    if first.starts_with("tcp") && fields.get(5) == Some(&"LISTEN") {
        let local = fields.get(3)?;
        let port = port_after(local, ':').or_else(|| port_after(local, '.'))?;
        let process = fields
            .get(6)
            .and_then(|owner| owner.split_once('/'))
            .map(|(_, name)| name.to_owned())
            .filter(|name| !name.is_empty());
        return Some(Listener { port, process });
    }
    None
}

fn port_after(address: &str, separator: char) -> Option<u16> {
    address.rsplit_once(separator)?.1.parse().ok().filter(|port| *port > 0)
}

/// `lsof` prints a space in a command as `\x20`.
fn unescape_lsof(command: &str) -> String {
    command.replace("\\x20", " ")
}

#[cfg(test)]
#[path = "machine_ports_tests.rs"]
mod tests;
