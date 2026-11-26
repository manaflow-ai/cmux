//! Plain copy: CmuxToastDetailCopy (a reason's error code in plain words) and PlainErrorText (a
//! system error as one sentence a person reads).

use serde::{Deserialize, Serialize};

// MARK: Detail copy

/// CmuxToastDetailCopy: a toast detail as plain words, with the code it read them from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailCopy {
    pub text: String,
    pub code: Option<String>,
}

/// The line an unknown `fs.` code reads as.
pub const FILE_FAILED: &str = "The machine couldn't finish the file operation.";

/// Every code with words of its own.
pub const MAPPED_CODES: [&str; 11] = [
    "fs.no_space",
    "disk_full",
    "fs.read_only",
    "fs.permission_denied",
    "fs.permission",
    "fs.too_large",
    "fs.not_found",
    "fs.exists",
    "fs.not_a_directory",
    "fs.io",
    "fs.revision_mismatch",
];

impl DetailCopy {
    pub fn raw(text: &str) -> Self {
        Self { text: text.into(), code: None }
    }

    /// The first known code in `detail` in words; an unknown `fs.` code as [`FILE_FAILED`]; else
    /// the detail as is. A detail of several lines is kept whole.
    pub fn plain(detail: &str) -> Self {
        if detail.chars().any(is_newline) {
            return Self::raw(detail);
        }
        let found = codes(detail);
        if let Some((code, words)) = found.iter().find_map(|c| Self::words(c).map(|w| (c, w))) {
            return Self { text: words.into(), code: Some(code.clone()) };
        }
        if let Some(code) = found.iter().find(|c| c.starts_with("fs.") && c.chars().count() > 3) {
            return Self { text: FILE_FAILED.into(), code: Some(code.clone()) };
        }
        Self::raw(detail)
    }

    pub fn words(code: &str) -> Option<&'static str> {
        Some(match code {
            "fs.no_space" | "disk_full" => "The machine is out of disk space.",
            "fs.read_only" => "The machine's disk is read-only.",
            "fs.permission_denied" | "fs.permission" => {
                "The machine didn't allow access to that location."
            }
            "fs.too_large" => "The file is too large for the machine.",
            "fs.not_found" => "That file or folder isn't on the machine anymore.",
            "fs.exists" => "An item with that name already exists on the machine.",
            "fs.not_a_directory" => "That path is a file, not a folder.",
            "fs.io" => "The machine couldn't read or write the file.",
            "fs.revision_mismatch" => {
                "The file changed on the machine after it was opened. Reload it, then try again."
            }
            _ => return None,
        })
    }

    /// "Error code: CODE".
    pub fn code_line(code: &str) -> String {
        format!("Error code: {code}")
    }
}

/// Swift's `Character.isNewline`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Runs of `[a-z0-9_.]`, dots trimmed at both ends, empties dropped.
pub fn codes(detail: &str) -> Vec<String> {
    detail
        .split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '.'))
        .map(|run| run.trim_matches('.').to_string())
        .filter(|run| !run.is_empty())
        .collect()
}

// MARK: Plain error text

/// PlainErrorText.Kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PlainErrorKind {
    Offline,
    TimedOut,
    Unreachable,
    SecureConnection,
    NoSpace,
    ReadOnly,
    Permission,
    NotFound,
    Exists,
}

/// An NSError as the app sees it: domain, code, the error it wraps (NSUnderlyingErrorKey) and its
/// LocalizedError description, if any.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorChain {
    pub domain: String,
    pub code: i64,
    #[serde(default)]
    pub underlying: Option<Box<ErrorChain>>,
    #[serde(default)]
    pub description: Option<String>,
}

impl ErrorChain {
    pub fn new(domain: &str, code: i64) -> Self {
        Self { domain: domain.into(), code, underlying: None, description: None }
    }
}

pub const URL_DOMAIN: &str = "NSURLErrorDomain";
pub const COCOA_DOMAIN: &str = "NSCocoaErrorDomain";
pub const POSIX_DOMAIN: &str = "NSPOSIXErrorDomain";
pub const OSSTATUS_DOMAIN: &str = "NSOSStatusErrorDomain";
pub const MACH_DOMAIN: &str = "NSMachErrorDomain";

/// The line for an error with no words of its own.
pub const GENERIC: &str = "Something went wrong. Try again.";

pub struct PlainErrorText;

impl PlainErrorText {
    /// The words for the error, or the generic line.
    pub fn text(error: &ErrorChain) -> String {
        Self::kind(error).map_or(GENERIC, Self::words_for).to_string()
    }

    /// Words; else an app error's own description; else the generic line.
    pub fn personal(error: &ErrorChain) -> String {
        if let Some(kind) = Self::kind(error) {
            return Self::words_for(kind).into();
        }
        if !Self::is_system(error)
            && let Some(text) = &error.description
        {
            return text.clone();
        }
        GENERIC.into()
    }

    /// The kind of the error or one it wraps, four deep at most.
    pub fn kind(error: &ErrorChain) -> Option<PlainErrorKind> {
        let mut current = Some(error);
        let mut depth = 0;
        while let Some(ns) = current {
            if depth >= 4 {
                break;
            }
            if let Some(kind) = Self::kind_of(&ns.domain, ns.code) {
                return Some(kind);
            }
            current = ns.underlying.as_deref();
            depth += 1;
        }
        None
    }

    pub fn is_system(error: &ErrorChain) -> bool {
        [URL_DOMAIN, COCOA_DOMAIN, POSIX_DOMAIN, OSSTATUS_DOMAIN, MACH_DOMAIN]
            .contains(&error.domain.as_str())
    }

    pub fn kind_of(domain: &str, code: i64) -> Option<PlainErrorKind> {
        use PlainErrorKind::*;
        match domain {
            URL_DOMAIN => match code {
                -1009 | -1005 | -1020 | -1018 => Some(Offline),
                -1001 => Some(TimedOut),
                -1004 | -1003 | -1006 | -2000 => Some(Unreachable),
                -1204..=-1200 => Some(SecureConnection),
                _ => None,
            },
            COCOA_DOMAIN => match code {
                640 => Some(NoSpace),
                642 => Some(ReadOnly),
                257 | 513 => Some(Permission),
                4 | 260 => Some(NotFound),
                516 => Some(Exists),
                _ => None,
            },
            // Darwin errno values; Swift truncates the code to Int32.
            POSIX_DOMAIN => match code as i32 {
                28 | 69 => Some(NoSpace),
                30 => Some(ReadOnly),
                13 | 1 => Some(Permission),
                2 => Some(NotFound),
                17 => Some(Exists),
                60 => Some(TimedOut),
                50 | 51 => Some(Offline),
                61 | 65 | 64 => Some(Unreachable),
                _ => None,
            },
            _ => None,
        }
    }

    /// `words(kind)`; none for none (the generic line is the caller's).
    pub fn words(kind: Option<PlainErrorKind>) -> Option<&'static str> {
        kind.map(Self::words_for)
    }

    pub fn words_for(kind: PlainErrorKind) -> &'static str {
        use PlainErrorKind::*;
        match kind {
            Offline => "You're offline. Check your network, then try again.",
            TimedOut => "The connection timed out. Check your network, then try again.",
            Unreachable => "cmux couldn't reach the server. Check your network, then try again.",
            SecureConnection => "cmux couldn't make a secure connection. Try again later.",
            NoSpace => "The disk is full. Free some space, then try again.",
            ReadOnly => "The disk is read-only.",
            Permission => "cmux doesn't have permission to do that.",
            NotFound => "The file or folder isn't there anymore.",
            Exists => "An item with that name already exists.",
        }
    }
}
