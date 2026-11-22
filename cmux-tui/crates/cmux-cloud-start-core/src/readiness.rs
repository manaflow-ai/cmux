//! What a failed Cloud start is missing, and the one repair that gets it
//! ready (competitor-teardown row 10; Leo: "select the thing and then start
//! the thing"). The app asks this when a composer's Cloud start fails
//! (`CloudStartChat.reply`), and the chat's start card shows the answer as a
//! short readiness summary over the person's kept draft: what is missing, its
//! repair, and Retry.
//!
//! Retry is always the same start: the page keeps the start's key, and the
//! platform binds the compose's machine reservation to that key
//! (cmux-platform `Leases.bindReservation`), so a retry after a repair
//! never makes a second machine. No repair here buys anything: each one opens
//! a place the person acts in (GitHub's install page, the environment
//! editor, Settings > Models). A paid resource still needs their own click.
//!
//! Pure: the app passes the failure's code and words; only this module reads
//! them. An unknown failure is `None`, which keeps the card as it was.

use serde::{Deserialize, Serialize};

/// What the start is missing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Need {
    /// The machine could not read the repository: the cmux GitHub App does not reach it.
    GitAccess,
    /// The environment needs a secret of the person's own that is not set.
    PersonalSecret,
    /// The environment's setup (installing dependencies) failed.
    Dependency,
    /// The environment's image is not one this start can run.
    UnsupportedImage,
}

/// The one repair the card offers for a need.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Repair {
    /// Opens the cmux GitHub App's install or settings (`github.connect`).
    ConnectGithub,
    /// Opens the environment editor on its Secrets section.
    EnvironmentSecrets,
    /// Opens the environment editor on its Setup script section.
    EnvironmentScript,
    /// Opens the environment editor on its Overview, where the image is picked.
    EnvironmentImage,
}

/// The readiness summary for one failed start.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Readiness {
    pub need: Need,
    pub repair: Repair,
    /// The missing secret's name, when the failure named one (`[A-Z_][A-Z0-9_]*`, at most 64).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secret: Option<String>,
}

/// The longest failure text read; the rest is never looked at.
const MAX_WORDS: usize = 4096;

/// The readiness summary for a start that failed with `code` and the host's `message`, or `None`
/// when neither says what is missing (the card keeps its own words and ways on).
pub fn classify(code: &str, message: Option<&str>) -> Option<Readiness> {
    let words = message.unwrap_or("");
    let words = match words.char_indices().nth(MAX_WORDS) {
        Some((cut, _)) => &words[..cut],
        None => words,
    };
    let lower = words.to_ascii_lowercase();
    let code = code.trim();
    let has = |needle: &str| lower.contains(needle);

    if code == "seed.needs_github"
        || has("seed.needs_github")
        || (has("github")
            && (has("not installed")
                || has("no access")
                || has("cannot read")
                || has("can't read")))
        || has("repository not found")
        || has("could not read username")
        || has("authentication failed for 'https://github.com")
    {
        return Some(Readiness {
            need: Need::GitAccess,
            repair: Repair::ConnectGithub,
            secret: None,
        });
    }
    if code.ends_with("image_unsupported")
        || has("image_unsupported")
        || has("unsupported image")
        || has("image is not supported")
        || has("image not supported")
        || (has("image") && has("not in the allowlist"))
    {
        return Some(Readiness {
            need: Need::UnsupportedImage,
            repair: Repair::EnvironmentImage,
            secret: None,
        });
    }
    if code.ends_with("secret_missing")
        || has("secret_missing")
        || has("missing secret")
        || (has("secret") && (has("not set") || has("is missing") || has("required")))
    {
        return Some(Readiness {
            need: Need::PersonalSecret,
            repair: Repair::EnvironmentSecrets,
            secret: secret_name(words),
        });
    }
    if code.ends_with("setup_failed")
        || has("setup_failed")
        || has("setup script failed")
        || has("maintenance script failed")
        || (has("setup") && has("exited with"))
        || has("npm err!")
        || has("could not find a version that satisfies")
        || has("no matching distribution found")
        || has("unable to locate package")
    {
        return Some(Readiness {
            need: Need::Dependency,
            repair: Repair::EnvironmentScript,
            secret: None,
        });
    }
    None
}

/// The first environment-variable-shaped word in `words` that reads as a secret's name: upper
/// case, digits and underscores, with an underscore or one of the usual secret words in it, so
/// words like `HTTP` or `OK` are not taken.
fn secret_name(words: &str) -> Option<String> {
    words
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .find(|word| {
            let starts = word.chars().next().is_some_and(|c| c.is_ascii_uppercase() || c == '_');
            starts
                && word.len() >= 3
                && word.len() <= 64
                && word.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
                && (word.contains('_')
                    || ["TOKEN", "KEY", "SECRET", "PASSWORD"].iter().any(|s| word.contains(s)))
        })
        .map(str::to_owned)
}

#[cfg(test)]
mod tests;
