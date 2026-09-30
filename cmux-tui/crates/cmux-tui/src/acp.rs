//! `cmux acp …`: agent sessions through acpmux, which is linked into this
//! binary. The same program runs as `acpmux` when started through a symlink
//! of that name (see `main`).

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use acpmux::cli::entry::{self, Invocation};

/// `cmux acp <args>`.
pub(crate) fn run(args: Vec<OsString>) -> i32 {
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let tag = std::env::var("CMUX_TAG").ok();
    finish(entry::main(
        args,
        Invocation {
            display_name: "cmux acp".into(),
            daemon_prefix: vec!["acp".into()],
            home: home.and_then(|home| tagged_home(tag.as_deref(), &home)),
        },
    ))
}

/// The binary started as `acpmux`.
pub(crate) fn run_standalone(args: Vec<OsString>) -> i32 {
    finish(entry::main(args, Invocation::default()))
}

fn finish(result: anyhow::Result<()>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("cmux acp: {error:#}");
            1
        }
    }
}

/// A tagged dev build keeps its own acpmux daemon and sessions, so it never
/// shares state with the user's cmux or with another tag. Untagged builds use
/// the acpmux default (`~/.acpmux`), shared with a standalone `acpmux`.
pub(crate) fn tagged_home(tag: Option<&str>, home: &Path) -> Option<PathBuf> {
    let slug = sanitize_tag(tag?)?;
    Some(home.join(".acpmux").join("tags").join(slug))
}

/// Same rule as the app's `ControlSocketPath.sanitize`: lowercase, runs of
/// anything outside `[a-z0-9]` become `-`, no leading or trailing `-`.
fn sanitize_tag(raw: &str) -> Option<String> {
    let mut slug = String::with_capacity(raw.len());
    for character in raw.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            slug.push(character);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    (!slug.is_empty()).then(|| slug.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tagged_builds_get_their_own_acpmux_home() {
        let home = Path::new("/Users/a");
        assert_eq!(
            tagged_home(Some("Feat_ACP.2"), home),
            Some(PathBuf::from("/Users/a/.acpmux/tags/feat-acp-2"))
        );
        assert_eq!(tagged_home(Some("--"), home), None);
        assert_eq!(tagged_home(Some(""), home), None);
        assert_eq!(tagged_home(None, home), None);
    }
}
