//! What the runtime inventory may show of a process's arguments and path.
//! Arguments can carry tokens, prompts and file contents, so only their
//! shape survives: the program name, flag names and short subcommand words.
//! The environment is never read.

/// Shown in place of a removed argument or flag value.
const REDACTED: &str = "<redacted>";

/// Longest bare word kept as a subcommand.
const MAX_WORD: usize = 24;

/// Most leading bare words kept as a subcommand path (`mcp serve`).
const MAX_SUBCOMMAND_WORDS: usize = 2;

/// Arguments with every value removed: argv[0] becomes its basename, a flag
/// keeps its name (`--model=x` becomes `--model=<redacted>`), the leading
/// subcommand words (`app-server`, `mcp serve`) stay, and anything else
/// becomes `<redacted>`. A word after a flag or past the subcommand can be a
/// flag value or part of a prompt, so it is removed.
pub fn redact_args(args: &[String]) -> Vec<String> {
    let mut redacted = Vec::with_capacity(args.len());
    let mut args = args.iter();
    if let Some(program) = args.next() {
        redacted.push(program.rsplit('/').next().unwrap_or(program).to_string());
    }
    let mut subcommand = true;
    for (index, arg) in args.enumerate() {
        subcommand &= index < MAX_SUBCOMMAND_WORDS && is_word(arg);
        redacted.push(if arg.starts_with('-') {
            match arg.split_once('=') {
                Some((flag, _)) if is_flag_name(flag) => format!("{flag}={REDACTED}"),
                None if is_flag_name(arg) => arg.clone(),
                _ => REDACTED.to_string(),
            }
        } else if subcommand {
            arg.clone()
        } else {
            REDACTED.to_string()
        });
    }
    redacted
}

/// A path with the home directory shown as `~`, so a user name is not part
/// of the output.
pub fn redact_path(path: &str, home: Option<&str>) -> String {
    let Some(home) = home.map(|home| home.trim_end_matches('/')).filter(|home| !home.is_empty())
    else {
        return path.to_string();
    };
    match path.strip_prefix(home) {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("~{rest}"),
        _ => path.to_string(),
    }
}

fn is_flag_name(flag: &str) -> bool {
    let name = flag.trim_start_matches('-');
    !name.is_empty()
        && name.len() <= MAX_WORD
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn is_word(arg: &str) -> bool {
    arg.len() <= MAX_WORD
        && arg.starts_with(|c: char| c.is_ascii_lowercase())
        && arg.chars().all(|c| c.is_ascii_lowercase() || c == '-')
}
