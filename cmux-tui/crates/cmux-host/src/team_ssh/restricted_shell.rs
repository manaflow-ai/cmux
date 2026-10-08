//! `cmux team restricted-shell`: the force-command of agent certificates
//! (team-vm-plan.md S5, decision D28). sshd runs it instead of whatever the
//! client asked for and passes the request in `SSH_ORIGINAL_COMMAND`.
//!
//! Rules (each has a test):
//! - No shell ever runs: the request is split into words here (single and
//!   double quotes, backslash escapes) and the result is executed directly,
//!   so `;`, `&&`, `$(…)`, globs and redirections are plain characters.
//! - Only `cmux team <verb> [args]` with a verb in [`ALLOWED`] and at most
//!   its number of arguments runs; the program word must be `cmux`, the
//!   image's [`CMUX_BIN`] or this executable. Everything else (an empty
//!   request, which would be an interactive shell, `systemd-run`, `at`,
//!   `crontab`, other `cmux` nouns, `restricted-shell` itself) is refused
//!   with a message on stderr that starts `restricted-shell:`.
//! - The verb runs as this program with a fixed environment: PATH is
//!   `/usr/bin:/bin`, and only HOME, USER, LOGNAME and LANG pass through.
//!   "This program" is the absolute argv[0] sshd ran (the force-command's
//!   path, `/opt/cmux/current/bin/cmux`, whose name keeps the `cmux`
//!   surface), else the resolved executable.

/// The image's `cmux` (web/scripts/cmux-vm-image/lock.ts `CURRENT_BIN`).
pub const CMUX_BIN: &str = "/opt/cmux/current/bin/cmux";
/// Upper bound on `SSH_ORIGINAL_COMMAND`.
pub const MAX_COMMAND_BYTES: usize = 16 * 1024;
/// `cmux team` verbs an ordinary agent may run, with their most arguments.
pub const ALLOWED: &[(&str, usize)] = &[("whoami", 0)];
/// Environment variables passed to the verb.
const KEEP_ENV: &[&str] = &["HOME", "USER", "LOGNAME", "LANG"];

/// Splits `line` into words the way a POSIX shell quotes them, with no
/// expansion of any kind. Control characters are refused.
pub fn words(line: &str) -> Result<Vec<String>, String> {
    if line.len() > MAX_COMMAND_BYTES {
        return Err(format!("the command is longer than {MAX_COMMAND_BYTES} bytes"));
    }
    if line.chars().any(|c| (c.is_control() && c != '\t' && c != ' ') || c == '\u{7f}') {
        return Err("the command holds a control character".into());
    }
    let mut out = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' => {
                if in_word {
                    out.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            '\'' => {
                in_word = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some(c) => word.push(c),
                        None => return Err("an unterminated single quote".into()),
                    }
                }
            }
            '"' => {
                in_word = true;
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some('\\') => match chars.next() {
                            Some(c @ ('"' | '\\' | '$' | '`')) => word.push(c),
                            Some(c) => {
                                word.push('\\');
                                word.push(c);
                            }
                            None => return Err("an unterminated double quote".into()),
                        },
                        Some(c) => word.push(c),
                        None => return Err("an unterminated double quote".into()),
                    }
                }
            }
            '\\' => {
                in_word = true;
                match chars.next() {
                    Some(c) => word.push(c),
                    None => return Err("a trailing backslash".into()),
                }
            }
            c => {
                in_word = true;
                word.push(c);
            }
        }
    }
    if in_word {
        out.push(word);
    }
    Ok(out)
}

/// The arguments to run this program with (`team <verb> …`), or why the
/// request is refused. `self_exe` is this program's path.
pub fn plan(original: Option<&str>, self_exe: Option<&str>) -> Result<Vec<String>, String> {
    let line = original.unwrap_or("");
    if line.trim().is_empty() {
        return Err("no shell: this certificate runs only `cmux team <command>`".into());
    }
    let w = words(line)?;
    let program_ok =
        w.first().is_some_and(|p| p == "cmux" || p == CMUX_BIN || Some(p.as_str()) == self_exe);
    if !program_ok || w.get(1).map(String::as_str) != Some("team") {
        return Err(format!(
            "only `cmux team <command>` may run, not {:?}",
            w.first().map_or("", String::as_str)
        ));
    }
    let verb = w.get(2).map(String::as_str).unwrap_or("");
    let Some((_, max_args)) = ALLOWED.iter().find(|(name, _)| *name == verb) else {
        let allowed: Vec<&str> = ALLOWED.iter().map(|(n, _)| *n).collect();
        return Err(format!("`cmux team {verb}` is not allowed; allowed: {}", allowed.join(", ")));
    };
    if w.len() - 3 > *max_args {
        return Err(format!("`cmux team {verb}` takes at most {max_args} argument(s)"));
    }
    Ok(w[1..].to_vec())
}

/// Entry for `cmux team restricted-shell`: replaces this process with the
/// planned verb, or refuses (exit 1).
#[cfg(unix)]
pub fn run() -> u8 {
    use std::os::unix::process::CommandExt;

    let argv0 =
        std::env::args_os().next().map(std::path::PathBuf::from).filter(|p| p.is_absolute());
    let Some(program) = argv0.or_else(|| std::env::current_exe().ok()) else {
        eprintln!("restricted-shell: cannot find this program");
        return 1;
    };
    let original = std::env::var("SSH_ORIGINAL_COMMAND").ok();
    let args = match plan(original.as_deref(), program.to_str()) {
        Ok(args) => args,
        Err(e) => {
            eprintln!("restricted-shell: {e}");
            return 1;
        }
    };
    let mut cmd = std::process::Command::new(program);
    cmd.args(&args).env_clear().env("PATH", "/usr/bin:/bin");
    for key in KEEP_ENV {
        if let Ok(value) = std::env::var(key) {
            cmd.env(key, value);
        }
    }
    let err = cmd.exec();
    eprintln!("restricted-shell: {err}");
    1
}

#[cfg(not(unix))]
pub fn run() -> u8 {
    eprintln!("restricted-shell: Unix only");
    1
}
