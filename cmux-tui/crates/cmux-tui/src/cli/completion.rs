//! `cmux completion zsh|bash|fish`: shell completion for every scope, verb and option, read from
//! the CLI's own help, so a command added to a help completes the day it lands (Leo, 2026-11-10:
//! "We need to keep cleaning up the cli commands so they're nice to type and intuitive and
//! ergonomic and go with best practices"). Before, `cmux completion zsh` was "unknown resource
//! scope" and every word was typed in full.
//!
//! The script asks this binary for the words at each Tab: `cmux __complete -- WORD... PARTIAL`
//! prints one candidate per line. The first word completes from the root help's scope rows, the
//! second from `cmux SCOPE --help` (its verb rows, its `cmux SCOPE VERB` usage lines and clap's
//! `Commands:` list), the rest from the options `cmux SCOPE VERB --help` shows. A help is read by
//! running this binary, so nothing is listed twice; a help that fails or is slow completes nothing.

use std::process::{Command, Stdio};

use super::OutputMode;

pub(super) const HELP: &str = "\
usage: cmux completion zsh|bash|fish

Prints the shell completion script for cmux. Every scope, verb and option completes,
read from cmux's own help at each Tab.

  zsh:   cmux completion zsh > \"${fpath[1]}/_cmux\"   (or: source <(cmux completion zsh))
  bash:  cmux completion bash > ~/.local/share/bash-completion/completions/cmux
  fish:  cmux completion fish > ~/.config/fish/completions/cmux.fish
";

const ZSH: &str = r#"#compdef cmux
# cmux completion for zsh: `cmux completion zsh`.
_cmux() {
  local -a candidates
  candidates=("${(@f)$(command cmux __complete -- "${(@)words[2,CURRENT]}" 2>/dev/null)}")
  compadd -Q -- "${(@)candidates:#}"
}
# Autoloaded from $fpath, this file's body is the first completion: run it.
if [[ "${funcstack[1]}" == _cmux ]]; then
  _cmux "$@"
elif (( $+functions[compdef] )); then
  compdef _cmux cmux
fi
"#;

const BASH: &str = r#"# cmux completion for bash: `cmux completion bash`.
_cmux() {
  local IFS=$'\n'
  COMPREPLY=($(command cmux __complete -- "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null))
}
complete -o default -F _cmux cmux
"#;

const FISH: &str = r#"# cmux completion for fish: `cmux completion fish`.
complete -c cmux -f -a '(command cmux __complete -- (commandline -opc)[2..-1] (commandline -ct) 2>/dev/null)'
"#;

/// Global options that take the next word as their value (the root help's GLOBAL OPTIONS).
const GLOBAL_VALUED: &[&str] =
    &["--socket", "--session", "--machine", "--app-socket", "--idempotency-key"];

/// Words the root help names outside its scope rows.
const EXTRA_SCOPES: &[&str] = &["attach", "completion", "help", "logout", "whoami"];

/// Set on the process that reads a help for a Tab: it prints a help or exits.
const HELP_READER_ENV: &str = "CMUX_COMPLETE_HELP";

/// In a help reader, `Some(2)` for anything but a help: a launcher (which runs a checkout's
/// script before it reads `--help`) or words that do not end in `--help` never run.
pub(crate) fn refuse_in_help_reader() -> Option<i32> {
    // The environment first: outside a help reader no argument is read (or decoded) here.
    std::env::var_os(HELP_READER_ENV)?;
    let args: Vec<String> =
        std::env::args_os().skip(1).map(|arg| arg.to_string_lossy().into_owned()).collect();
    let Some(words) = args.strip_suffix(&["--help".to_owned()][..]) else { return Some(2) };
    #[cfg(unix)]
    if super::dev::is_requested(words) {
        return Some(2);
    }
    (words.len() > 2 || words.iter().any(|word| word.starts_with('-'))).then_some(2)
}

/// `Some(exit code)` for `cmux completion …` and `cmux __complete …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    if let Some(("__complete", rest)) =
        args.split_first().map(|(first, rest)| (first.as_str(), rest))
    {
        let words = rest.strip_prefix(&["--".to_owned()][..]).unwrap_or(rest);
        for candidate in candidates(words, &read_help) {
            println!("{candidate}");
        }
        return Some(0);
    }
    let (global, command) = super::parse_globals(args).ok()?;
    let (scope, rest) = command.split_first()?;
    (scope == "completion").then(|| script(rest, global.output))
}

fn script(rest: &[String], output: OutputMode) -> i32 {
    let words: Vec<&str> =
        rest.iter().map(String::as_str).filter(|word| *word != "--json").collect();
    let output = if rest.iter().any(|word| word == "--json") { OutputMode::Json } else { output };
    let text = match words.as_slice() {
        ["-h" | "--help", ..] => {
            print!("{HELP}");
            return 0;
        }
        ["zsh"] => ZSH,
        ["bash"] => BASH,
        ["fish"] => FISH,
        [] => {
            let message =
                "cmux: completion needs a shell: zsh, bash or fish; run `cmux completion --help`";
            return usage_error(message, output);
        }
        [other, ..] => {
            let message = format!(
                "cmux: completion takes zsh, bash or fish, not {other:?}; run `cmux completion --help`"
            );
            return usage_error(&message, output);
        }
    };
    print!("{text}");
    0
}

/// A usage error in the CLI's error shape. `cli/app.rs` has this too, but it is unix-only and
/// this module builds on every target.
fn usage_error(message: &str, output: OutputMode) -> i32 {
    let error = serde_json::json!({
        "code": "usage.invalid", "message": message, "details": {}, "retryable": false,
    });
    super::wire::print_local_error(&error, output, 2)
}

/// The completions of the last word of `words` (the word being typed, maybe empty), with `help`
/// reading `cmux ARGS --help`.
pub(super) fn candidates(
    words: &[String],
    help: &dyn Fn(&[&str]) -> Option<String>,
) -> Vec<String> {
    // Bash splits `--session=dev` at `=` into three words: join them back.
    let mut joined: Vec<String> = Vec::new();
    for word in words {
        match joined.last_mut() {
            Some(last) if word == "=" && last.starts_with("--") && !last.contains('=') => {
                last.push('=');
            }
            Some(last)
                if last.ends_with('=')
                    && last.starts_with("--")
                    && last.matches('=').count() == 1
                    && !word.starts_with('-') =>
            {
                last.push_str(word);
            }
            _ => joined.push(word.clone()),
        }
    }
    let words = joined.as_slice();
    let Some((partial, before)) = words.split_last() else { return Vec::new() };
    // Global options before the scope, and their values, are not command words.
    let mut command: Vec<&str> = Vec::new();
    let mut value_next = false;
    for word in before {
        if value_next {
            value_next = false;
        } else if command.is_empty() && word.starts_with('-') {
            value_next = GLOBAL_VALUED.contains(&word.as_str()) && !word.contains('=');
        } else {
            command.push(word);
        }
    }
    let mut found: Vec<String> = match command.as_slice() {
        [] if partial.starts_with('-') => help(&[]).map(|text| options(&text)).unwrap_or_default(),
        [] => {
            let mut scopes = help(&[]).map(|text| rows(&text)).unwrap_or_default();
            scopes.extend(EXTRA_SCOPES.iter().map(|word| (*word).to_owned()));
            scopes
        }
        ["completion"] => ["zsh", "bash", "fish"].map(str::to_owned).to_vec(),
        // Only a help the root help lists is read, and only a verb that help lists: a Tab
        // never runs words it has not seen in a help.
        [scope, ..]
            if !help(&[]).is_some_and(|root| rows(&root).iter().any(|row| row == scope)) =>
        {
            Vec::new()
        }
        [scope, verb, ..]
            if !help(&[scope])
                .is_some_and(|text| verbs(scope, &text).iter().any(|v| v == verb)) =>
        {
            help(&[scope]).map(|text| options(&text)).unwrap_or_default()
        }
        [scope] if !partial.starts_with('-') => {
            help(&[scope]).map(|text| verbs(scope, &text)).unwrap_or_default()
        }
        [scope] => help(&[scope]).map(|text| options(&text)).unwrap_or_default(),
        [scope, verb, ..] => {
            let text = help(&[scope, verb]).or_else(|| help(&[scope]));
            text.map(|text| options(&text)).unwrap_or_default()
        }
    };
    found.retain(|word| word.starts_with(partial.as_str()));
    found.sort();
    found.dedup();
    found
}

/// `cmux ARGS --help`'s stdout, by running this binary, or `None` when it fails or prints
/// nothing.
fn read_help(args: &[&str]) -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    // The name it was run as picks its help (`cmux` or `cmux-tui`), so the help is read under
    // that name, not the file's.
    let mut command = Command::new(exe);
    #[cfg(unix)]
    if let Some(name) = std::env::args_os().next() {
        std::os::unix::process::CommandExt::arg0(&mut command, name);
    }
    let out = command
        .args(args)
        .arg("--help")
        .env("CMUX_CLI_STEP", "1")
        .env(HELP_READER_ENV, "1")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    (out.status.success() && !text.trim().is_empty()).then_some(text)
}

fn is_word(word: &str) -> bool {
    word.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && word.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// A help's rows (`  word   what it does`): two spaces, a lowercase word, two or more spaces.
pub(super) fn rows(help: &str) -> Vec<String> {
    help.lines()
        .filter_map(|line| {
            let rest = line.strip_prefix("  ")?;
            if rest.starts_with(' ') {
                return None;
            }
            let (word, after) = rest.split_once("  ")?;
            (is_word(word) && word != "cmux" && !after.trim().is_empty()).then(|| word.to_owned())
        })
        .collect()
}

/// `scope`'s verbs: its help's rows and the verb of each `cmux SCOPE VERB` usage line.
pub(super) fn verbs(scope: &str, help: &str) -> Vec<String> {
    let mut found = rows(help);
    let prefix = format!("cmux {scope} ");
    for line in help.lines() {
        let Some((_, after)) = line.split_once(prefix.as_str()) else { continue };
        // `cmux vm ls | status | pause [NAME]` names three verbs: words joined by `|`.
        let mut joined = true;
        for token in after.split_whitespace() {
            if token == "|" {
                joined = true;
                continue;
            }
            if !joined {
                break;
            }
            joined = token.ends_with('|');
            let words: Vec<&str> = token.split('|').filter(|word| !word.is_empty()).collect();
            if !words.iter().all(|word| is_word(word)) {
                break;
            }
            found.extend(words.iter().map(|word| (*word).to_owned()));
        }
    }
    found.retain(|word| word != "help");
    found
}

/// Every `--option` a help shows.
pub(super) fn options(help: &str) -> Vec<String> {
    let mut found = Vec::new();
    for token in help.split(|c: char| c.is_whitespace() || "[]()|,=`'\"<>".contains(c)) {
        if let Some(name) = token.strip_prefix("--")
            && name.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            && !name.ends_with('-')
        {
            found.push(token.to_owned());
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::{candidates, options, rows, verbs};

    const ROOT: &str = "USAGE\n  cmux attach\n\nYOU\n  chat          Start a chat\n  vm            Your VMs\n  --json        Print JSON\n";
    const VM: &str = "QUICK START\n  cmux vm ls | status | pause [NAME]\n  cmux vm exec dev -- uname -a\nMACHINES\n  list-machines   List them\n";

    fn help(args: &[&str]) -> Option<String> {
        match args {
            [] => Some(ROOT.to_owned()),
            ["vm"] => Some(VM.to_owned()),
            ["vm", "exec"] => Some("usage: cmux vm exec [--json] [--timeout-ms MS]".to_owned()),
            _ => None,
        }
    }

    fn complete(words: &[&str]) -> Vec<String> {
        let words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
        candidates(&words, &help)
    }

    #[test]
    fn scopes_verbs_and_options_complete_from_the_help() {
        assert_eq!(complete(&["v"]), ["vm"]);
        assert!(complete(&[""]).contains(&"chat".to_owned()));
        assert!(complete(&[""]).contains(&"completion".to_owned()));
        assert_eq!(complete(&["vm", "l"]), ["list-machines", "ls"]);
        assert_eq!(complete(&["vm", "ex"]), ["exec"]);
        assert_eq!(complete(&["vm", "exec", "--t"]), ["--timeout-ms"]);
        assert_eq!(complete(&["--socket", "/tmp/s", "vm", "p"]), ["pause"]);
        assert_eq!(complete(&["completion", ""]), ["bash", "fish", "zsh"]);
        // Bash's words for `cmux --session=dev vm p`.
        assert_eq!(complete(&["--session", "=", "dev", "vm", "p"]), ["pause"]);
        assert_eq!(complete(&["--session=dev", "vm", "p"]), ["pause"]);
        assert!(complete(&["nope", ""]).is_empty());
    }

    #[test]
    fn the_readers_take_rows_usage_lines_and_options() {
        assert_eq!(rows(ROOT), ["chat", "vm"]);
        assert!(verbs("vm", VM).contains(&"pause".to_owned()));
        assert_eq!(
            options("[--json] --timeout-ms MS, --Bad x--y --a-"),
            ["--json", "--timeout-ms"]
        );
    }
}
