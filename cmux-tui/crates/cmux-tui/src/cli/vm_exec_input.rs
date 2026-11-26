//! `cmux vm exec NAME -- CMD ARGS…`: the command keeps its argv, and what is piped in reaches
//! its stdin.
//!
//! Argv: several words are joined with POSIX shell quoting, so `vm exec dev -- sh -c 'cat > f'`
//! runs `sh -c 'cat > f'` on the machine (before, the words were joined with bare spaces and the
//! machine's shell split `cat > f` again). One word is a shell line as typed: `vm exec dev --
//! 'ls | wc -l'` keeps its pipe.
//!
//! Stdin: the Cloud API's exec takes a command and no stdin, so the bytes go inside the command,
//! base64 encoded: `printf '%s' B64 | base64 -d | ( CMD )`. Input too large for one command (the
//! machine's shell takes one argument of at most 128 KiB) is staged first, chunk by chunk, into a
//! private scratch file on the machine, which `CMD` reads as its stdin and which is removed after.
//! So `cat f | cmux vm exec dev -- sh -c 'cat > f'` copies a file, binary included.
//!
//! When stdin is read: `--stdin` always (waits for its end); `--no-stdin` never; otherwise when
//! stdin is not a terminal and has data or its end within a second, so a caller whose stdin is a
//! pipe nobody writes to (an agent harness) never hangs here.

use std::io::{IsTerminal, Read};
use std::time::Duration;

use base64::Engine as _;

use super::cloud_start_chat::shell_quote;

/// Base64 bytes one command carries (a multiple of 4, so each chunk decodes on its own).
pub(super) const CHUNK_BASE64: usize = 96 * 1024;

/// The most stdin `vm exec` forwards: past it, copy the file another way (`cmux cloud prepare-scp`).
pub(super) const INPUT_MAX: usize = 16 * 1024 * 1024;

/// How long an unflagged run waits for a non-terminal stdin to show data or its end.
const PIPE_WAIT: Duration = Duration::from_secs(1);

/// Whether `vm exec` reads its stdin (`--stdin`, `--no-stdin`, or neither).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum StdinMode {
    #[default]
    Auto,
    On,
    Off,
}

/// The command line for the machine's shell from `vm exec`'s words: one word as typed (a shell
/// line), several each shell-quoted, so their argv survives.
pub(super) fn join_command(words: &[String]) -> String {
    match words {
        [line] => line.clone(),
        _ => words.iter().map(|word| shell_quote(word)).collect::<Vec<_>>().join(" "),
    }
}

/// What runs on the machine to give `command` the stdin `input`: the staging steps, run first
/// and in order (each must exit 0), the command itself, and the step that removes the scratch
/// file when a staging step fails.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct InputPlan {
    pub(super) stage: Vec<String>,
    pub(super) command: String,
    pub(super) cleanup: Option<String>,
}

/// The plan for `command` with stdin `input`: inline when its base64 fits one chunk of
/// `chunk` bytes, else staged into `scratch` (a path on the machine) chunk by chunk.
pub(super) fn plan(command: &str, input: &[u8], scratch: &str, chunk: usize) -> InputPlan {
    let chunk = (chunk - chunk % 4).max(4);
    let encoded = base64::engine::general_purpose::STANDARD.encode(input);
    // The command on lines of its own: a trailing `# comment` in it cannot swallow the `)`.
    if encoded.len() <= chunk {
        return InputPlan {
            stage: Vec::new(),
            command: format!("printf '%s' '{encoded}' | base64 -d | (\n{command}\n)"),
            cleanup: None,
        };
    }
    let path = shell_quote(scratch);
    let stage = encoded
        .as_bytes()
        .chunks(chunk)
        .enumerate()
        .map(|(index, part)| {
            // Base64 is ASCII: every chunk is text, and safe inside single quotes.
            let part = std::str::from_utf8(part).unwrap_or_default();
            let redirect = if index == 0 { ">" } else { ">>" };
            format!("umask 077; printf '%s' '{part}' | base64 -d {redirect} {path}")
        })
        .collect();
    InputPlan {
        stage,
        command: format!("(\n{command}\n) < {path}; status=$?; rm -f {path}; exit $status"),
        cleanup: Some(format!("rm -f {path}")),
    }
}

/// A scratch path on the machine for one run's staged stdin.
pub(super) fn scratch_path() -> Result<String, String> {
    super::command::random_prefixed("/tmp/cmux-stdin").map_err(|error| error.0)
}

/// The stdin `vm exec` forwards under `mode`: `None` for none (a terminal, `--no-stdin`, an empty
/// one, or an idle pipe on an unflagged run), an error past [`INPUT_MAX`].
pub(super) fn read_input(mode: StdinMode) -> Result<Option<Vec<u8>>, String> {
    let stdin = std::io::stdin();
    match mode {
        StdinMode::Off => return Ok(None),
        StdinMode::Auto if stdin.is_terminal() || !ready(PIPE_WAIT) => return Ok(None),
        StdinMode::Auto | StdinMode::On => {}
    }
    let mut bytes = Vec::new();
    if stdin.lock().take(INPUT_MAX as u64 + 1).read_to_end(&mut bytes).is_err() {
        // A closed or unreadable stdin is no stdin.
        return Ok(None);
    }
    if bytes.len() > INPUT_MAX {
        return Err(format!(
            "stdin is over {} MiB; copy the file with scp (`cmux cloud prepare-scp --help`)",
            INPUT_MAX / (1024 * 1024)
        ));
    }
    Ok((!bytes.is_empty()).then_some(bytes))
}

/// Whether stdin has data or its end within `wait` (a closed descriptor has neither).
fn ready(wait: Duration) -> bool {
    let mut poll = libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
    let millis = libc::c_int::try_from(wait.as_millis()).unwrap_or(libc::c_int::MAX);
    // SAFETY: one pollfd, owned here, for the length of the call.
    let ready = unsafe { libc::poll(&mut poll, 1, millis) };
    ready > 0 && poll.revents & libc::POLLNVAL == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};

    fn words(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    /// The machine's side, here: each staging step, then the command, in `sh -c`, as the Cloud
    /// API's exec runs them. The command's stdout.
    fn run_plan(plan: &InputPlan) -> Vec<u8> {
        for step in &plan.stage {
            let status = Command::new("sh").arg("-c").arg(step).status().expect("sh");
            assert!(status.success(), "staging step failed: {step}");
        }
        let out = Command::new("sh")
            .arg("-c")
            .arg(&plan.command)
            .stdin(Stdio::null())
            .output()
            .expect("sh");
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        out.stdout
    }

    #[test]
    fn several_words_keep_their_argv_one_word_is_a_shell_line() {
        assert_eq!(join_command(&words(&["uname", "-a"])), "uname -a");
        assert_eq!(join_command(&words(&["sh", "-c", "cat > f"])), "sh -c 'cat > f'");
        assert_eq!(join_command(&words(&["echo", "it's", "$HOME"])), r#"echo 'it'\''s' '$HOME'"#);
        assert_eq!(join_command(&words(&["printf", "%s\n", ""])), "printf '%s\n' ''");
        assert_eq!(join_command(&words(&["ls | wc -l"])), "ls | wc -l");
        // The machine's shell gets back the words as typed.
        let typed = words(&["printf", "[%s]", "a b", "it's", "$HOME", "", "*"]);
        let out = Command::new("sh").arg("-c").arg(join_command(&typed)).output().unwrap();
        assert_eq!(String::from_utf8(out.stdout).unwrap(), "[a b][it's][$HOME][][*]");
    }

    #[test]
    fn small_stdin_rides_in_the_command() {
        let input = b"line one\n'quoted' \"double\" $HOME `tick`\n\0binary\xff";
        let plan = plan("cat", input, "/unused", CHUNK_BASE64);
        assert!(plan.stage.is_empty() && plan.cleanup.is_none(), "{plan:?}");
        assert_eq!(run_plan(&plan), input);
        // A trailing comment in the command does not eat the closing paren.
        let commented = super::plan("cat # the rest", b"ok", "/unused", CHUNK_BASE64);
        assert_eq!(run_plan(&commented), b"ok");
    }

    #[test]
    fn large_stdin_is_staged_in_chunks_and_removed() {
        let dir = std::env::temp_dir().join(format!("vm-exec-input-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let scratch = dir.join("stage file").display().to_string();
        let input: Vec<u8> = (0..10_000u32).map(|n| (n * 7 % 256) as u8).collect();
        // A tiny chunk (not a multiple of 4 either), so the input takes many steps.
        let plan = plan("wc -c; exit 3", &input, &scratch, 1001);
        assert!(plan.stage.len() > 10, "{}", plan.stage.len());
        for step in &plan.stage {
            Command::new("sh").arg("-c").arg(step).status().unwrap();
        }
        let out = Command::new("sh").arg("-c").arg(&plan.command).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "10000");
        assert_eq!(out.status.code(), Some(3), "the command's own exit code");
        assert!(!std::path::Path::new(&scratch).exists(), "the scratch file is removed");

        let copy = dir.join("copy").display().to_string();
        let cat = super::plan(
            &join_command(&words(&["sh", "-c", &format!("cat > '{copy}'")])),
            &input,
            &scratch,
            1001,
        );
        run_plan(&cat);
        assert_eq!(std::fs::read(&copy).unwrap(), input, "the bytes arrive as sent");
        assert_eq!(cat.cleanup, Some(format!("rm -f {}", shell_quote(&scratch))));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
