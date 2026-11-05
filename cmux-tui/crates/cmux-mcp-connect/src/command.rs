//! Local (stdio) servers: what argv may be, and the pin of the binary
//! (threat model T8).

use sha2::{Digest, Sha256};

use crate::Refusal;

/// A local server command that passed the rules.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandTarget {
    /// argv exactly as it will run (no shell).
    pub argv: Vec<String>,
    /// A launcher that downloads code at run time (`npx`, `uvx`, ...): the
    /// card says the package can change between runs.
    pub fetches_code: bool,
}

const LAUNCHERS: [&str; 6] = ["npx", "uvx", "bunx", "pnpx", "pipx", "dlx"];
const SHELLS: [&str; 6] = ["sh", "bash", "zsh", "fish", "dash", "ksh"];

/// Splits a command line the way a person writes it (spaces, simple
/// quotes), with no shell expansion.
pub fn split(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    let mut any = false;
    for c in line.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => cur.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                any = true;
            }
            (None, c) if c.is_whitespace() => {
                if any || !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                    any = false;
                }
            }
            (None, c) => cur.push(c),
        }
    }
    if any || !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Checks a stdio server's argv: a program and arguments, never a shell
/// line (`sh -c`), never shell operators that would only work in a shell.
pub fn check_command(argv: &[String]) -> Result<CommandTarget, Refusal> {
    let program = argv
        .first()
        .filter(|p| !p.trim().is_empty())
        .ok_or_else(|| Refusal::new("the command is empty"))?;
    let base = program.rsplit('/').next().unwrap_or(program);
    if SHELLS.contains(&base) {
        return Err(Refusal::new(
            "a shell is not an MCP server; give the server's own program and arguments",
        ));
    }
    for a in argv {
        if a.contains('\0') || a.contains('\n') {
            return Err(Refusal::new("an argument holds a NUL or a line break"));
        }
        if matches!(a.as_str(), "|" | "&&" | "||" | ";" | ">" | ">>" | "<" | "&")
            || a.starts_with("$(")
            || a.contains('`')
        {
            return Err(Refusal::new(format!(
                "`{a}` only works in a shell; MCP servers run without one"
            )));
        }
    }
    Ok(CommandTarget { argv: argv.to_vec(), fetches_code: LAUNCHERS.contains(&base) })
}

/// The lowercase hex SHA-256 of a binary's bytes: the pin the card shows and
/// each start compares (a different binary re-asks).
pub fn pin_binary(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}
