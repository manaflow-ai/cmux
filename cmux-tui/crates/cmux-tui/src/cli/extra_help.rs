//! Help and guidance for the commands that route before the resource grammar:
//! the app scopes (cli/app.rs), the app's browser pages, `notify`, and the
//! process commands `acp` and `link` that `main` runs before any cmux global
//! option is read.
//!
//! Without this, `cmux settings --help` printed the root help and
//! `cmux window --help` printed the screen help: `window` is a tmux shorthand
//! for `screen` only inside the resource grammar, while the `window` scope the
//! root help lists is the app's.

use super::UsageError;

#[cfg(unix)]
mod app_scopes;
#[cfg(unix)]
pub(super) use app_scopes::print;

/// `acp` and `link` parse their own options; `main` routes them only as the
/// first word. A cmux global option before them otherwise reached the
/// resource grammar as "unknown resource scope".
pub(super) fn own_options_scope(scope: &str) -> Option<UsageError> {
    matches!(scope, "acp" | "link" | "harness").then(|| {
        UsageError::new(format!(
            "`{scope}` takes its own options after the word {scope}: run `cmux {scope} …` \
             with no cmux global option before it (`cmux {scope} --help`)"
        ))
    })
}
