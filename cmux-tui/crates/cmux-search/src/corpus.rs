//! A deterministic synthetic corpus shaped like what cmux indexes: build
//! logs, compiler errors, structured logs, JSON, paths and chat prose, with
//! a long tail of rare tokens (ids), for tests and the ripgrep bench.

use crate::{Doc, Kind};

const WORDS: &[&str] = &[
    "the",
    "error",
    "warning",
    "build",
    "test",
    "request",
    "response",
    "server",
    "client",
    "session",
    "terminal",
    "workspace",
    "agent",
    "chief",
    "cargo",
    "swift",
    "compile",
    "linker",
    "failed",
    "passed",
    "running",
    "finished",
    "migration",
    "database",
    "query",
    "index",
    "search",
    "scrollback",
    "render",
    "frame",
    "window",
    "pane",
    "tab",
    "sidebar",
    "palette",
    "socket",
    "daemon",
    "network",
    "timeout",
    "retry",
    "deploy",
    "staging",
    "production",
    "branch",
    "commit",
    "rebase",
    "merge",
    "review",
    "please",
    "could",
    "would",
    "should",
    "because",
    "about",
    "after",
    "before",
    "where",
    "which",
    "there",
    "their",
    "files",
    "folder",
    "memory",
    "latency",
    "benchmark",
    "faster",
    "slower",
    "screen",
    "cursor",
    "keyboard",
    "shortcut",
    "focus",
    "update",
    "install",
    "version",
    "release",
    "nightly",
    "fleet",
    "mini",
    "token",
    "stream",
    "message",
    "reply",
    "thread",
    "channel",
    "layout",
    "split",
    "zoom",
];

const MODULES: &[&str] = &[
    "src/engine",
    "src/server",
    "Sources/App",
    "Packages/Core",
    "crates/mux",
    "web/app/api",
    "cmux-tui/src",
    "daemon/remote",
    "plans/cmux-next",
    "tests/e2e",
];

/// An endless, seeded stream of docs; stop it with [`Iterator::take`] or
/// [`SyntheticCorpus::with_bytes`].
pub struct SyntheticCorpus {
    state: u64,
    produced: usize,
    limit: usize,
    at_ms: i64,
    line: i64,
}

impl SyntheticCorpus {
    /// A stream that ends after about `bytes` of text.
    pub fn with_bytes(seed: u64, bytes: usize) -> Self {
        Self { state: seed.max(1), produced: 0, limit: bytes, at_ms: 1_760_000_000_000, line: 0 }
    }

    fn next_u64(&mut self) -> u64 {
        // xorshift64*
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.next_u64() % bound as u64) as usize
    }

    /// A word, Zipf-ish: low indexes much more often.
    fn word(&mut self) -> &'static str {
        let a = self.below(WORDS.len());
        let b = self.below(WORDS.len());
        WORDS[a.min(b)]
    }

    fn hex(&mut self, digits: usize) -> String {
        let value = self.next_u64();
        format!("{value:016x}")[..digits.min(16)].to_owned()
    }

    fn line_text(&mut self) -> String {
        match self.below(10) {
            0 => format!(
                "error[E{:04}]: mismatched types in {} --> {}/{}.rs:{}:{}",
                self.below(800),
                self.word(),
                MODULES[self.below(MODULES.len())],
                self.word(),
                self.below(2000),
                self.below(120)
            ),
            1 => format!(
                "2026-10-{:02}T{:02}:{:02}:{:02}Z INFO {} request id={}-{} took {}ms",
                1 + self.below(28),
                self.below(24),
                self.below(60),
                self.below(60),
                self.word(),
                self.hex(8),
                self.hex(4),
                self.below(5000)
            ),
            2 => format!(
                "{{\"id\":\"{}\",\"name\":\"{} {}\",\"count\":{},\"ok\":{}}}",
                self.hex(16),
                self.word(),
                self.word(),
                self.below(100_000),
                self.below(2) == 0
            ),
            3 => format!(
                "   Compiling {}-{} v0.{}.{} ({}/{})",
                self.word(),
                self.word(),
                self.below(40),
                self.below(20),
                MODULES[self.below(MODULES.len())],
                self.word()
            ),
            4 => format!(
                "test {}::{}_{} ... {}",
                self.word(),
                self.word(),
                self.word(),
                if self.below(20) == 0 { "FAILED" } else { "ok" }
            ),
            _ => {
                let count = 6 + self.below(14);
                let mut sentence = String::new();
                for index in 0..count {
                    if index > 0 {
                        sentence.push(' ');
                    }
                    sentence.push_str(self.word());
                }
                sentence
            }
        }
    }
}

impl Iterator for SyntheticCorpus {
    type Item = Doc;

    fn next(&mut self) -> Option<Doc> {
        if self.produced >= self.limit {
            return None;
        }
        let roll = self.below(100);
        let (kind, lines) = match roll {
            0..70 => (Kind::Scrollback, 8 + self.below(40)),
            70..90 => (Kind::Chat, 1 + self.below(6)),
            90..95 => (Kind::Chief, 1 + self.below(3)),
            _ => (Kind::Command, 1),
        };
        let mut text = String::new();
        for index in 0..lines {
            if index > 0 {
                text.push('\n');
            }
            text.push_str(&self.line_text());
        }
        self.produced += text.len() + 1;
        self.at_ms += 1 + self.below(2000) as i64;
        let first_line = self.line;
        self.line += lines as i64;
        let terminal = self.below(24);
        let (source, target, title) = match kind {
            Kind::Chat => {
                let session = self.below(200);
                (format!("acp:{session}"), format!("acp:{session}"), format!("chat {session}"))
            }
            Kind::Chief => ("chief:main".to_owned(), "chief:main".to_owned(), "Chief".to_owned()),
            _ => {
                (format!("term:{terminal}"), format!("term:{terminal}"), format!("zsh {terminal}"))
            }
        };
        Some(Doc {
            kind,
            source,
            target,
            position: Some(first_line),
            title,
            text,
            at_ms: self.at_ms,
            key: None,
        })
    }
}
