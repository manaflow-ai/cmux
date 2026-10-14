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

/// The subcommands the vendor adapters read. Any other bare word may be a
/// prompt (`claude hello`), so it is removed.
const SUBCOMMANDS: &[&str] =
    &["app-server", "mcp-server", "mcp", "serve", "pid-update-loop", "exec", "e", "run", "acp"];

/// Arguments with every value removed: argv[0] becomes its basename when
/// that looks like a program name (a process can rewrite argv[0] into any
/// text), a long flag keeps its name (`--model=x` becomes
/// `--model=<redacted>`), a short flag stays only as one letter (`-p`; `-pX`
/// may hold a value), the adapters' leading subcommands (`app-server`,
/// `mcp serve`) stay, and anything else becomes `<redacted>`.
pub fn redact_args(args: &[String]) -> Vec<String> {
    let mut redacted = Vec::with_capacity(args.len());
    let mut args = args.iter();
    if let Some(program) = args.next() {
        let name = program.rsplit('/').next().unwrap_or(program);
        redacted.push(if is_program_name(name) { name.to_string() } else { REDACTED.to_string() });
    }
    let mut subcommand = true;
    for (index, arg) in args.enumerate() {
        subcommand &= index < MAX_SUBCOMMAND_WORDS && SUBCOMMANDS.contains(&arg.as_str());
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

fn is_program_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_WORD
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// `--name` of any word length, or `-x` of one letter.
fn is_flag_name(flag: &str) -> bool {
    let (dashes, name) = flag.split_at(flag.len() - flag.trim_start_matches('-').len());
    let valid = !name.is_empty()
        && name.len() <= MAX_WORD
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    valid && (dashes == "--" || (dashes == "-" && name.len() == 1))
}
