//! What runs on a port: the listening socket's inode from `/proc/net/tcp` and `tcp6`, the
//! process holding it from `/proc/<pid>/fd`, then that process's `cwd` and `cmdline`.

use std::fmt;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::io::Fs;

/// TCP state `LISTEN` in `/proc/net/tcp`.
const LISTEN: &str = "0A";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Inferred {
    pub pid: u32,
    pub dir: PathBuf,
    pub argv: Vec<String>,
    /// `argv` as one shell command.
    pub command: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InferError {
    /// No socket listens on the port.
    NoListener { port: u16 },
    /// A socket listens, but no process this user can read holds it.
    Unseen { port: u16 },
    /// The process was found but its `cwd` or `cmdline` can't be read.
    Unreadable { port: u16, pid: u32, what: &'static str },
}

impl fmt::Display for InferError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InferError::NoListener { port } => {
                write!(f, "nothing listens on port {port}; pass --cmd CMD and --dir DIR")
            }
            InferError::Unseen { port } => write!(
                f,
                "port {port} is held by a process this user can't see; pass --cmd CMD and --dir DIR"
            ),
            InferError::Unreadable { port, pid, what } => write!(
                f,
                "can't read the {what} of process {pid} on port {port}; pass --cmd CMD and --dir DIR"
            ),
        }
    }
}

/// The process listening on `port`, read under `proc_root` (`/proc` on a real machine).
pub fn infer(fs: &dyn Fs, proc_root: &Path, port: u16) -> Result<Inferred, InferError> {
    let mut inodes = vec![];
    for table in ["tcp", "tcp6"] {
        if let Ok(bytes) = fs.read(&proc_root.join("net").join(table)) {
            inodes.extend(listening_inodes(&String::from_utf8_lossy(&bytes), port));
        }
    }
    if inodes.is_empty() {
        return Err(InferError::NoListener { port });
    }
    let wanted: Vec<String> = inodes.iter().map(|inode| format!("socket:[{inode}]")).collect();
    let mut holders = vec![];
    let mut pids: Vec<u32> = fs
        .list(proc_root)
        .unwrap_or_default()
        .iter()
        .filter_map(|name| name.parse().ok())
        .collect();
    pids.sort_unstable();
    for pid in pids {
        let fd_dir = proc_root.join(pid.to_string()).join("fd");
        let Ok(fds) = fs.list(&fd_dir) else { continue };
        let holds = fds.iter().any(|fd| {
            fs.read_link(&fd_dir.join(fd))
                .is_ok_and(|target| wanted.iter().any(|w| target.as_os_str() == w.as_str()))
        });
        if holds {
            holders.push(pid);
        }
    }
    // Forked workers share the listening socket: the one whose parent isn't a holder too is
    // the server that was started.
    let pid = holders
        .iter()
        .copied()
        .find(|pid| parent(fs, proc_root, *pid).is_none_or(|ppid| !holders.contains(&ppid)))
        .ok_or(InferError::Unseen { port })?;
    let base = proc_root.join(pid.to_string());
    let dir = fs.read_link(&base.join("cwd")).map_err(|_| InferError::Unreadable {
        port,
        pid,
        what: "working directory",
    })?;
    let argv: Vec<String> = fs
        .read(&base.join("cmdline"))
        .map_err(|_| InferError::Unreadable { port, pid, what: "command line" })?
        .split(|b| *b == 0)
        .filter(|arg| !arg.is_empty())
        .map(|arg| String::from_utf8_lossy(arg).into_owned())
        .collect();
    if argv.is_empty() {
        return Err(InferError::Unreadable { port, pid, what: "command line" });
    }
    let command = shell_join(&argv);
    Ok(Inferred { pid, dir, argv, command })
}

/// The inodes of sockets in `table` (`/proc/net/tcp` or `tcp6` text) listening on `port`.
pub fn listening_inodes(table: &str, port: u16) -> Vec<u64> {
    table
        .lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let local = fields.get(1)?;
            let (_, hex_port) = local.rsplit_once(':')?;
            if u16::from_str_radix(hex_port, 16).ok()? != port || *fields.get(3)? != LISTEN {
                return None;
            }
            fields.get(9)?.parse().ok().filter(|inode| *inode != 0)
        })
        .collect()
}

/// The parent pid from `/proc/<pid>/stat` (the field after the `)` that ends the name).
fn parent(fs: &dyn Fs, proc_root: &Path, pid: u32) -> Option<u32> {
    let bytes = fs.read(&proc_root.join(pid.to_string()).join("stat")).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let (_, rest) = text.rsplit_once(')')?;
    rest.split_whitespace().nth(1)?.parse().ok()
}

/// `argv` quoted for `sh -c`, plain words left bare.
pub fn shell_join(argv: &[String]) -> String {
    argv.iter().map(|arg| shell_quote(arg)).collect::<Vec<_>>().join(" ")
}

fn shell_quote(arg: &str) -> String {
    let plain = !arg.is_empty()
        && arg.bytes().all(|b| b.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&b));
    if plain { arg.to_owned() } else { format!("'{}'", arg.replace('\'', r"'\''")) }
}
