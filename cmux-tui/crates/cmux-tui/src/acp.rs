//! `cmux acp …`: agent sessions through acpmux, which is linked into this
//! binary. The same program runs as `acpmux` when started through a symlink
//! of that name (see `main`).

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use acpmux::cli::entry::{self, Invocation};

/// `cmux acp <args>`.
pub(crate) fn run(args: Vec<OsString>) -> i32 {
    if args.first().is_some_and(|arg| arg == "open") {
        let words: Vec<String> =
            args[1..].iter().map(|arg| arg.to_string_lossy().into_owned()).collect();
        return open(&words);
    }
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let identity = crate::app_identity::AppIdentity::detect(
        |name| std::env::var(name).ok(),
        std::env::current_exe().ok().as_deref(),
    );
    let tag = acpmux_tag(std::env::var("CMUX_TAG").ok(), identity);
    finish(entry::main(
        args,
        Invocation {
            display_name: "cmux acp".into(),
            daemon_prefix: vec!["acp".into()],
            home: home.and_then(|home| tagged_home(tag.as_deref(), &home)),
        },
    ))
}

/// `cmux acp open NAME [--pane ID]`: show an agent session in a new tab of
/// a pane (the session's focused pane by default). The tab runs `cmux acp attach NAME`,
/// the acpmux TUI, so it works the same in the app and in the TUI.
fn open(args: &[String]) -> i32 {
    let exe = match std::env::current_exe() {
        Ok(exe) => exe.to_string_lossy().into_owned(),
        Err(error) => {
            eprintln!("cmux acp open: {error}");
            return 1;
        }
    };
    match open_command(args, &exe) {
        Ok(command) => crate::cli::run(&command, ""),
        Err(message) => {
            eprintln!("{message}");
            2
        }
    }
}

/// The `cmux pane <pane> run -- <exe> acp attach NAME` arguments.
fn open_command(args: &[String], exe: &str) -> Result<Vec<String>, String> {
    let messages = &crate::localization::catalog().app_control;
    let (session, pane) = match args {
        [session] => (session, "current"),
        [session, flag, pane] | [flag, pane, session] if flag == "--pane" => {
            (session, pane.as_str())
        }
        _ => return Err(messages.acp_open_usage.to_owned()),
    };
    Ok(["pane", pane, "run", "--", exe, "acp", "attach", session.as_str()]
        .into_iter()
        .map(str::to_owned)
        .collect())
}

/// The binary started as `acpmux`. Its daemon is started from
/// `current_exe`, which resolves an `acpmux` symlink to this binary under
/// its own name, so that start needs the `acp` prefix (`<cmux> acp daemon
/// run`). A copy named `acpmux` (as `host setup` installs) needs none.
pub(crate) fn run_standalone(args: Vec<OsString>) -> i32 {
    let renamed = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.file_name().map(|name| name != "acpmux"))
        .unwrap_or(false);
    let daemon_prefix: Vec<OsString> = if renamed { vec!["acp".into()] } else { Vec::new() };
    finish(entry::main(args, Invocation { daemon_prefix, ..Invocation::default() }))
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

/// The tag whose acpmux home `cmux acp` uses: `CMUX_TAG` (set in the
/// app's terminals), else the tag of the app bundle around this executable,
/// so a tagged build started from Finder or a script keeps its acpmux apart
/// from the user's, as its daemon session does (`AppIdentity`).
pub(crate) fn acpmux_tag(
    env_tag: Option<String>,
    identity: Option<crate::app_identity::AppIdentity>,
) -> Option<String> {
    env_tag.filter(|tag| !tag.trim().is_empty()).or_else(|| identity?.tag)
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
    fn open_runs_the_acpmux_tui_in_a_new_tab() {
        let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            open_command(&words(&["review"]), "/b/cmux").unwrap(),
            words(&["pane", "current", "run", "--", "/b/cmux", "acp", "attach", "review"])
        );
        assert_eq!(
            open_command(&words(&["--pane", "pane_01", "review"]), "/b/cmux").unwrap(),
            words(&["pane", "pane_01", "run", "--", "/b/cmux", "acp", "attach", "review"])
        );
        assert!(open_command(&words(&[]), "/b/cmux").is_err());
    }

    #[test]
    fn a_tagged_bundle_without_cmux_tag_uses_its_own_acpmux_home() {
        let bundle = crate::app_identity::AppIdentity {
            bundle_id: Some("com.cmuxterm.app.debug.acpx-v2".into()),
            tag: Some("acpx-v2".into()),
            socket_override: None,
        };
        assert_eq!(acpmux_tag(None, Some(bundle.clone())).as_deref(), Some("acpx-v2"));
        assert_eq!(acpmux_tag(Some(" ".into()), Some(bundle.clone())).as_deref(), Some("acpx-v2"));
        assert_eq!(acpmux_tag(Some("own".into()), Some(bundle)).as_deref(), Some("own"));
        let untagged = crate::app_identity::AppIdentity {
            bundle_id: Some("com.cmuxterm.app".into()),
            tag: None,
            socket_override: None,
        };
        assert_eq!(acpmux_tag(None, Some(untagged)), None);
        assert_eq!(acpmux_tag(None, None), None);
    }

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
