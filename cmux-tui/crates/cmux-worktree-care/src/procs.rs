//! The folders processes on this machine work in, so a worktree some
//! program (an agent outside acpmux, a shell, a build, an editor) still
//! works in is never removed. The scan fails rather than answer partly:
//! a caller that cannot see the processes removes nothing.

use std::path::{Path, PathBuf};

/// A process and the folder it works in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Process {
    pub pid: u32,
    pub cwd: PathBuf,
}

/// Every process of this user whose working folder can be read.
#[cfg(target_os = "linux")]
pub fn working_folders() -> Result<Vec<Process>, String> {
    let entries = std::fs::read_dir("/proc").map_err(|error| format!("/proc: {error}"))?;
    let mut found = Vec::new();
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse::<u32>().ok()) else {
            continue;
        };
        // Another user's process is unreadable, and it cannot work in this
        // user's worktree without this user's permissions anyway.
        if let Ok(cwd) = std::fs::read_link(entry.path().join("cwd")) {
            found.push(Process { pid, cwd });
        }
    }
    if found.is_empty() {
        return Err("no process working folder is readable in /proc".to_string());
    }
    Ok(found)
}

/// Every process of this user whose working folder `lsof` reports.
#[cfg(not(target_os = "linux"))]
pub fn working_folders() -> Result<Vec<Process>, String> {
    let user = std::env::var("USER").unwrap_or_default();
    let mut args = vec!["-a", "-d", "cwd", "-F", "pn", "-w"];
    if !user.is_empty() {
        args.extend(["-u", user.as_str()]);
    }
    let mut command = std::process::Command::new("lsof");
    command
        .args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    // A hung lsof (a stale network mount) must not hold the pass forever.
    let output = crate::git::run_within(command, std::time::Duration::from_secs(60))
        .map_err(|error| format!("lsof: {error}"))?;
    let found = parse_lsof(&output.stdout);
    if found.is_empty() {
        return Err("lsof listed no process working folder".to_string());
    }
    Ok(found)
}

/// `lsof -F pn` output: a `p<pid>` line, then `n<path>` lines for it.
#[cfg_attr(target_os = "linux", allow(dead_code))]
fn parse_lsof(bytes: &[u8]) -> Vec<Process> {
    let mut found = Vec::new();
    let mut pid = None;
    for line in String::from_utf8_lossy(bytes).lines() {
        if let Some(value) = line.strip_prefix('p') {
            pid = value.parse::<u32>().ok();
        } else if let (Some(path), Some(pid)) = (line.strip_prefix('n'), pid) {
            found.push(Process { pid, cwd: PathBuf::from(path) });
        }
    }
    found
}

/// The first process working in `folder` or below it, other than this one.
/// The kernel reports real paths, so `folder` is compared as given and as
/// its real path (`/tmp` is `/private/tmp` on macOS).
pub fn inside<'a>(processes: &'a [Process], folder: &Path) -> Option<&'a Process> {
    let own = std::process::id();
    let real = std::fs::canonicalize(folder).ok();
    processes.iter().find(|process| {
        process.pid != own
            && (process.cwd.starts_with(folder)
                || real.as_deref().is_some_and(|real| process.cwd.starts_with(real)))
    })
}

#[cfg(test)]
mod care_tests {
    use super::*;

    #[test]
    fn lsof_output_names_each_process_folder() {
        let found = parse_lsof(b"p12\nfcwd\nn/Users/a/wt\np13\nfcwd\nn/tmp\n");
        assert_eq!(
            found,
            vec![
                Process { pid: 12, cwd: PathBuf::from("/Users/a/wt") },
                Process { pid: 13, cwd: PathBuf::from("/tmp") },
            ]
        );
    }

    #[test]
    fn a_process_in_a_subfolder_is_inside_but_a_sibling_prefix_is_not() {
        let processes = vec![
            Process { pid: 1, cwd: PathBuf::from("/w/a-2/src") },
            Process { pid: 2, cwd: PathBuf::from("/w/a/src") },
        ];
        assert_eq!(inside(&processes, Path::new("/w/a")).map(|p| p.pid), Some(2));
        assert_eq!(inside(&processes, Path::new("/w/b")), None);
    }

    #[test]
    fn this_machine_lists_its_processes() {
        let found = working_folders().unwrap();
        assert!(!found.is_empty());
    }
}
