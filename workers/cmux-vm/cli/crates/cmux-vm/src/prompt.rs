//! Confirmation for destructive verbs. A person at a terminal types the id of
//! what they are about to destroy; anything else (an agent, a script, CI) must
//! say `--yes` explicitly.

use std::io::{BufRead, IsTerminal, Write};

/// Where the CLI asks for confirmation.
pub trait Prompt {
    /// Whether a person can answer, that is, stdin is a terminal.
    fn is_interactive(&self) -> bool;
    /// Shows `question` and returns the line typed in reply.
    fn ask(&mut self, question: &str) -> std::io::Result<String>;
}

/// The process's stdin, with the question on stderr so stdout stays clean.
pub struct StdinPrompt;

impl Prompt for StdinPrompt {
    fn is_interactive(&self) -> bool {
        std::io::stdin().is_terminal()
    }

    fn ask(&mut self, question: &str) -> std::io::Result<String> {
        let mut stderr = std::io::stderr().lock();
        stderr.write_all(question.as_bytes())?;
        stderr.flush()?;
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line)?;
        Ok(line)
    }
}

/// Never interactive: destructive verbs need `--yes`.
pub struct NoPrompt;

impl Prompt for NoPrompt {
    fn is_interactive(&self) -> bool {
        false
    }

    fn ask(&mut self, _question: &str) -> std::io::Result<String> {
        Err(std::io::Error::other("no terminal to ask"))
    }
}
