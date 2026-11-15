//! The command line and a few named environment values of the job a terminal
//! runs in the foreground: what an agent CLI was started with, so a terminal
//! respawned after its host died (a reboot) can start the same agent again
//! with the same flags and account (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
//!
//! The leader is resolved as in [`super::foreground_cwd`]: the process group
//! that owns the terminal's PTY. Only the requested environment keys are
//! returned, never the whole environment. macOS reads `KERN_PROCARGS2` (the
//! same user's processes only), Linux `/proc/<pid>/cmdline` and `environ`.

/// What a foreground job was started with.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct JobLaunch {
    /// The job's argv, program first.
    pub argv: Vec<String>,
    /// The values of the requested keys the job has, in request order.
    pub env: Vec<(String, String)>,
}

/// The launch of the foreground job of the terminal whose PTY child is `pid`,
/// with the values of `env_keys` it has. `None` when the child has no
/// controlling terminal, the leader is gone, or the platform refuses.
pub fn foreground_job_launch(pid: u32, env_keys: &[&str]) -> Option<JobLaunch> {
    process_launch(super::foreground_process_group(pid)?, env_keys)
}

/// What process `pid` was started with: its argv and the values of
/// `env_keys` it has. `None` when the process is gone, belongs to another
/// user, or the platform refuses. One process, never an enumeration.
#[cfg(target_os = "macos")]
pub fn process_launch(pid: u32, env_keys: &[&str]) -> Option<JobLaunch> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut argmax: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: sysctl writes at most `size` bytes into `argmax`.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            (&mut argmax as *mut libc::c_int).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    let argmax = usize::try_from(argmax).ok().filter(|max| result == 0 && *max > 0)?;
    // An agent's argv and environment fit easily; a longer one is cut and refused.
    let mut buffer = vec![0u8; argmax.min(256 * 1024)];
    let mut size = buffer.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: sysctl writes at most `size` bytes into `buffer`.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 {
        return None;
    }
    parse_procargs2(&buffer[..size.min(buffer.len())], env_keys)
}

#[cfg(target_os = "linux")]
pub fn process_launch(pid: u32, env_keys: &[&str]) -> Option<JobLaunch> {
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let environ = std::fs::read(format!("/proc/{pid}/environ")).unwrap_or_default();
    let argv = nul_strings(&cmdline).map(str::to_string).collect::<Vec<_>>();
    (!argv.is_empty()).then(|| JobLaunch { argv, env: pick_env(nul_strings(&environ), env_keys) })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn process_launch(_pid: u32, _env_keys: &[&str]) -> Option<JobLaunch> {
    None
}

/// Parses a `KERN_PROCARGS2` buffer: argc (native `i32`), the executable path,
/// NUL padding, `argc` arguments, then the environment, each NUL-terminated.
/// A process that set its title (Node's `process.title`) rewrote its
/// argument area to the title and NULs: the run of NULs before the
/// environment is skipped, and an empty entry does not end it (Apple's
/// `key=value` strings after it are never requested keys).
#[cfg(any(target_os = "macos", test))]
pub(crate) fn parse_procargs2(bytes: &[u8], env_keys: &[&str]) -> Option<JobLaunch> {
    let argc = usize::try_from(i32::from_ne_bytes(bytes.get(..4)?.try_into().ok()?)).ok()?;
    let mut cursor = 4;
    cursor += bytes.get(cursor..)?.iter().position(|byte| *byte == 0)? + 1;
    while bytes.get(cursor) == Some(&0) {
        cursor += 1;
    }
    let mut argv = Vec::with_capacity(argc.min(bytes.len()));
    for _ in 0..argc {
        let rest = bytes.get(cursor..)?;
        let end = rest.iter().position(|byte| *byte == 0)?;
        argv.push(std::str::from_utf8(&rest[..end]).ok()?.to_string());
        cursor += end + 1;
    }
    if argv.is_empty() {
        return None;
    }
    let environment = bytes.get(cursor..).unwrap_or_default();
    let entries = environment.split(|byte| *byte == 0);
    let entries = entries
        .filter(|entry| !entry.is_empty())
        .filter_map(|entry| std::str::from_utf8(entry).ok());
    Some(JobLaunch { argv, env: pick_env(entries, env_keys) })
}

#[cfg(any(target_os = "linux", test))]
fn nul_strings(bytes: &[u8]) -> impl Iterator<Item = &str> {
    bytes
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
        .filter_map(|part| std::str::from_utf8(part).ok())
}

fn pick_env<'a>(entries: impl Iterator<Item = &'a str>, keys: &[&str]) -> Vec<(String, String)> {
    let mut found = vec![None; keys.len()];
    for entry in entries {
        let Some((key, value)) = entry.split_once('=') else { continue };
        if let Some(index) = keys.iter().position(|wanted| *wanted == key) {
            found[index].get_or_insert_with(|| value.to_string());
        }
    }
    keys.iter()
        .zip(found)
        .filter_map(|(key, value)| value.map(|value| (key.to_string(), value)))
        .collect()
}

#[cfg(test)]
mod tests;
