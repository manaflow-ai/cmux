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

#[cfg(target_os = "macos")]
fn process_launch(pid: u32, env_keys: &[&str]) -> Option<JobLaunch> {
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
fn process_launch(pid: u32, env_keys: &[&str]) -> Option<JobLaunch> {
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let environ = std::fs::read(format!("/proc/{pid}/environ")).unwrap_or_default();
    let argv = nul_strings(&cmdline).map(str::to_string).collect::<Vec<_>>();
    (!argv.is_empty()).then(|| JobLaunch { argv, env: pick_env(nul_strings(&environ), env_keys) })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn process_launch(_pid: u32, _env_keys: &[&str]) -> Option<JobLaunch> {
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
mod tests {
    use super::*;

    fn procargs(exec: &str, argv: &[&str], env: &[&str]) -> Vec<u8> {
        let mut bytes = (argv.len() as i32).to_ne_bytes().to_vec();
        bytes.extend_from_slice(exec.as_bytes());
        bytes.extend_from_slice(&[0, 0, 0]);
        for part in argv.iter().chain(env) {
            bytes.extend_from_slice(part.as_bytes());
            bytes.push(0);
        }
        bytes.extend_from_slice(&[0, 0]);
        bytes.extend_from_slice(b"ptr_munge=1\0");
        bytes
    }

    #[test]
    fn procargs2_gives_argv_and_only_the_requested_keys() {
        let bytes = procargs(
            "/usr/local/bin/claude",
            &["claude", "--model", "opus", "--dangerously-skip-permissions"],
            &[
                "HOME=/Users/a",
                "ANTHROPIC_API_KEY=sk-secret",
                "CLAUDE_CONFIG_DIR=/Users/a/.claude-work",
            ],
        );
        let launch = parse_procargs2(&bytes, &["CLAUDE_CONFIG_DIR", "CODEX_HOME"]).unwrap();
        assert_eq!(launch.argv, ["claude", "--model", "opus", "--dangerously-skip-permissions"]);
        assert_eq!(
            launch.env,
            [("CLAUDE_CONFIG_DIR".to_string(), "/Users/a/.claude-work".to_string())]
        );
    }

    #[test]
    fn a_retitled_process_still_gives_its_environment() {
        // `process.title = "claude"`: the argument area is the title, then NULs
        // to its old end, before the untouched environment.
        let mut bytes = 3i32.to_ne_bytes().to_vec();
        bytes.extend_from_slice(b"/usr/local/bin/node\0\0\0");
        bytes.extend_from_slice(b"claude\0");
        bytes.extend_from_slice(&[0; 40]);
        bytes.extend_from_slice(
            b"HOME=/Users/a\0CLAUDE_CONFIG_DIR=/Users/a/.claude-2\0\0\0ptr_munge=1\0",
        );
        let launch = parse_procargs2(&bytes, &["CLAUDE_CONFIG_DIR"]).unwrap();
        assert_eq!(launch.argv.first().map(String::as_str), Some("claude"));
        assert_eq!(
            launch.env,
            [("CLAUDE_CONFIG_DIR".to_string(), "/Users/a/.claude-2".to_string())]
        );
    }

    #[test]
    fn a_truncated_buffer_is_refused() {
        let bytes = procargs("/bin/codex", &["codex", "-m", "gpt"], &[]);
        assert!(parse_procargs2(&bytes[..12], &[]).is_none());
        assert!(parse_procargs2(&[1, 0], &[]).is_none());
    }

    #[test]
    fn linux_strings_split_on_nul() {
        assert_eq!(
            nul_strings(b"codex\0resume\0abc\0").collect::<Vec<_>>(),
            ["codex", "resume", "abc"]
        );
        let env =
            pick_env(nul_strings(b"CODEX_HOME=/h\0CODEX_HOME=/later\0X=1\0"), &["CODEX_HOME"]);
        assert_eq!(env, [("CODEX_HOME".to_string(), "/h".to_string())]);
    }

    #[cfg(unix)]
    #[test]
    fn a_live_process_reads_its_own_launch() {
        // This test process: its argv[0] and a key it does have.
        let launch = process_launch(std::process::id(), &["PATH"]).expect("own launch");
        assert!(!launch.argv.is_empty());
        assert_eq!(launch.env.first().map(|(key, _)| key.as_str()), Some("PATH"));
    }
}
