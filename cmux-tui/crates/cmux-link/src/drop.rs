//! Pure planning for `terminal.drop` and `agent.attach` (finder.md 7.2
//! and 7.3).
//!
//! A drop on a terminal types a path that is valid on that terminal's host:
//! the item's own path when it lives there, otherwise the path of a copy
//! that a job first puts in `~/.cmux/drops/<job>/` on that host. An attach
//! to an agent hands out an `ent_…` handle whose rights are the dragger's
//! rights intersected with the agent's file grant. No I/O happens here; the
//! session host types the text through its input path and the link runs
//! the copies.

use serde::{Deserialize, Serialize};

use crate::fs::{Rights, check_name};
use crate::ids::random_id;

/// Most items one drop carries (finder.md 7.1).
pub const MAX_DROP_ITEMS: usize = 1000;
pub const ENT_PREFIX: &str = "ent_";

/// One dropped item, resolved by the shell from the dragger's handles.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DropItem {
    /// The machine the item lives on (`host_…`, or the `conn_…` of a plain
    /// SSH target).
    pub host: String,
    /// Absolute path on that machine. Never shown to the dragging app.
    pub path: String,
    pub dir: bool,
}

/// The terminal a drop lands on.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalTarget {
    pub host: String,
    /// The home directory on that host, for the drop folder.
    pub home: String,
}

/// One copy a drop needs before it can type paths.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlannedCopy {
    pub from_host: String,
    pub from_path: String,
    /// Absolute path on the terminal's host.
    pub to_path: String,
    pub dir: bool,
}

/// What a drop does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "plan", rename_all = "snake_case")]
pub enum DropPlan {
    /// Every item is on the terminal's host: type `text`.
    Insert { text: String },
    /// Run the copies into `folder` on the terminal's host, then type `text`.
    CopyThenInsert { folder: String, copies: Vec<PlannedCopy>, text: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "code")]
pub enum DropError {
    #[serde(rename = "drop.empty")]
    Empty,
    #[serde(rename = "drop.too_many")]
    TooMany,
    /// A path that is relative or holds a control character. Typing a line
    /// break into a terminal could run a command, so such paths are refused,
    /// never escaped.
    #[serde(rename = "drop.path_unsafe")]
    PathUnsafe,
    #[serde(rename = "agent.no_file_grant")]
    AgentHasNoFileGrant,
}

impl std::fmt::Display for DropError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Empty => "drop.empty",
            Self::TooMany => "drop.too_many",
            Self::PathUnsafe => "drop.path_unsafe",
            Self::AgentHasNoFileGrant => "agent.no_file_grant",
        })
    }
}

impl std::error::Error for DropError {}

/// Plans a drop of `items` on `terminal`. `job` names the drop folder.
pub fn plan_terminal_drop(
    terminal: &TerminalTarget,
    items: &[DropItem],
    job: &str,
) -> Result<DropPlan, DropError> {
    if items.is_empty() {
        return Err(DropError::Empty);
    }
    if items.len() > MAX_DROP_ITEMS {
        return Err(DropError::TooMany);
    }
    check_absolute(&terminal.home)?;
    check_name(job).map_err(|_| DropError::PathUnsafe)?;
    let folder = format!("{}/.cmux/drops/{job}", terminal.home.trim_end_matches('/'));
    let mut copies = Vec::new();
    let mut taken = Vec::<String>::new();
    let mut paths = Vec::with_capacity(items.len());
    for item in items {
        check_absolute(&item.path)?;
        if item.host == terminal.host {
            paths.push(item.path.clone());
            continue;
        }
        let name = base_name(&item.path).ok_or(DropError::PathUnsafe)?;
        let name = unique_name(name, &taken);
        let to_path = format!("{folder}/{name}");
        taken.push(name);
        copies.push(PlannedCopy {
            from_host: item.host.clone(),
            from_path: item.path.clone(),
            to_path: to_path.clone(),
            dir: item.dir,
        });
        paths.push(to_path);
    }
    let text = paths.iter().map(|path| posix_quote(path)).collect::<Vec<_>>().join(" ");
    Ok(if copies.is_empty() {
        DropPlan::Insert { text }
    } else {
        DropPlan::CopyThenInsert { folder, copies, text }
    })
}

fn check_absolute(path: &str) -> Result<(), DropError> {
    if !path.starts_with('/') || path.chars().any(is_unsafe_character) {
        return Err(DropError::PathUnsafe);
    }
    Ok(())
}

/// Control characters, the Unicode line and paragraph separators (Zl,
/// Zp) and format characters (Cf, such as bidirectional overrides and
/// zero-width characters): typed into a terminal they can break a line or
/// hide what the path really is.
fn is_unsafe_character(character: char) -> bool {
    const FORMAT: &[(u32, u32)] = &[
        (0x00AD, 0x00AD),
        (0x0600, 0x0605),
        (0x061C, 0x061C),
        (0x06DD, 0x06DD),
        (0x070F, 0x070F),
        (0x0890, 0x0891),
        (0x08E2, 0x08E2),
        (0x180E, 0x180E),
        (0x200B, 0x200F),
        (0x202A, 0x202E),
        (0x2060, 0x2064),
        (0x2066, 0x206F),
        (0xFEFF, 0xFEFF),
        (0xFFF9, 0xFFFB),
        (0x110BD, 0x110BD),
        (0x110CD, 0x110CD),
        (0x13430, 0x1343F),
        (0x1BCA0, 0x1BCA3),
        (0x1D173, 0x1D17A),
        (0xE0001, 0xE0001),
        (0xE0020, 0xE007F),
    ];
    let code = u32::from(character);
    character.is_control()
        || matches!(character, '\u{2028}' | '\u{2029}')
        || FORMAT.iter().any(|(start, end)| (*start..=*end).contains(&code))
}

fn base_name(path: &str) -> Option<&str> {
    let name = path.trim_end_matches('/').rsplit('/').next()?;
    check_name(name).ok().map(|()| name)
}

/// `name`, or `name 2.ext`, `name 3.ext`, … when an earlier item took it.
fn unique_name(name: &str, taken: &[String]) -> String {
    if !taken.iter().any(|existing| existing == name) {
        return name.to_owned();
    }
    let (stem, extension) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    (2..)
        .map(|number| format!("{stem} {number}{extension}"))
        .find(|candidate| !taken.contains(candidate))
        .expect("an unbounded counter finds a free name")
}

/// Quotes a path for a POSIX shell: plain when every character is safe,
/// else single-quoted with `'` written as `'\''`.
#[must_use]
pub fn posix_quote(path: &str) -> String {
    let safe = !path.is_empty()
        && path.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"/._-+,:@%=".contains(&byte));
    if safe {
        return path.to_owned();
    }
    format!("'{}'", path.replace('\'', "'\\''"))
}

/// An `ent_…` handle: one file or subtree given to an agent or another app
/// by drop or attach (finder.md 7.3). Owner: the app supervisor's grant
/// store; it expires with the agent session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntHandle {
    pub ent: String,
    pub conn: String,
    pub root: String,
    pub path: String,
    pub rights: Rights,
    pub expires_at: Option<u64>,
}

/// The rights an attached item gets: the dragger's root rights intersected
/// with the agent's file grant. An agent without a file grant gets nothing.
pub fn attach_rights(dragger: Rights, agent: Option<Rights>) -> Result<Rights, DropError> {
    match (dragger, agent.ok_or(DropError::AgentHasNoFileGrant)?) {
        (Rights::ReadWrite, Rights::ReadWrite) => Ok(Rights::ReadWrite),
        _ => Ok(Rights::Read),
    }
}

/// Issues the `ent_…` handle for one attached item.
pub fn issue_ent(
    conn: &str,
    root: &str,
    path: &str,
    dragger: Rights,
    agent: Option<Rights>,
    expires_at: Option<u64>,
) -> Result<EntHandle, DropError> {
    let rights = attach_rights(dragger, agent)?;
    crate::fs::components(path).map_err(|_| DropError::PathUnsafe)?;
    Ok(EntHandle {
        ent: random_id(ENT_PREFIX),
        conn: conn.to_owned(),
        root: root.to_owned(),
        path: path.to_owned(),
        rights,
        expires_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(host: &str, path: &str) -> DropItem {
        DropItem { host: host.into(), path: path.into(), dir: false }
    }

    fn terminal() -> TerminalTarget {
        TerminalTarget { host: "host_mac".into(), home: "/Users/dev".into() }
    }

    #[test]
    fn same_host_items_are_typed_quoted_without_a_newline() {
        let plan = plan_terminal_drop(
            &terminal(),
            &[item("host_mac", "/Users/dev/a.txt"), item("host_mac", "/Users/dev/it's here.txt")],
            "job_1",
        )
        .unwrap();
        assert_eq!(
            plan,
            DropPlan::Insert { text: "/Users/dev/a.txt '/Users/dev/it'\\''s here.txt'".into() }
        );
    }

    #[test]
    fn items_on_another_host_are_copied_into_the_drop_folder_first() {
        let plan = plan_terminal_drop(
            &terminal(),
            &[
                item("host_mac", "/Users/dev/local.txt"),
                item("conn_vm", "/home/dev/report.pdf"),
                item("conn_vm2", "/srv/report.pdf"),
            ],
            "job_7",
        )
        .unwrap();
        let DropPlan::CopyThenInsert { folder, copies, text } = plan else { panic!("{plan:?}") };
        assert_eq!(folder, "/Users/dev/.cmux/drops/job_7");
        assert_eq!(copies.len(), 2);
        assert_eq!(copies[0].to_path, "/Users/dev/.cmux/drops/job_7/report.pdf");
        assert_eq!(copies[1].to_path, "/Users/dev/.cmux/drops/job_7/report 2.pdf");
        assert_eq!(
            text,
            "/Users/dev/local.txt /Users/dev/.cmux/drops/job_7/report.pdf '/Users/dev/.cmux/drops/job_7/report 2.pdf'"
        );
        assert!(!text.contains('\n'));
    }

    #[test]
    fn unsafe_paths_and_bad_drops_are_refused() {
        let terminal = terminal();
        assert_eq!(plan_terminal_drop(&terminal, &[], "j"), Err(DropError::Empty));
        for path in [
            "relative.txt",
            "/a\nrm -rf ~",
            "/a\rb",
            "/a\u{1b}[2J",
            "/a\u{2028}b",
            "/a\u{2029}b",
            "/report\u{202e}fdp.exe",
            "/a\u{200b}b",
            "/a\u{feff}",
        ] {
            assert_eq!(
                plan_terminal_drop(&terminal, &[item("host_mac", path)], "j"),
                Err(DropError::PathUnsafe),
                "{path:?}"
            );
        }
        assert_eq!(
            plan_terminal_drop(&terminal, &[item("conn_x", "/a")], "../j"),
            Err(DropError::PathUnsafe)
        );
        let many = vec![item("host_mac", "/a"); MAX_DROP_ITEMS + 1];
        assert_eq!(plan_terminal_drop(&terminal, &many, "j"), Err(DropError::TooMany));
    }

    #[test]
    fn attach_rights_are_the_intersection_and_need_a_file_grant() {
        assert_eq!(
            attach_rights(Rights::ReadWrite, Some(Rights::ReadWrite)),
            Ok(Rights::ReadWrite)
        );
        assert_eq!(attach_rights(Rights::ReadWrite, Some(Rights::Read)), Ok(Rights::Read));
        assert_eq!(attach_rights(Rights::Read, Some(Rights::ReadWrite)), Ok(Rights::Read));
        assert_eq!(attach_rights(Rights::ReadWrite, None), Err(DropError::AgentHasNoFileGrant));
        let ent = issue_ent(
            "conn_a",
            "root_a",
            "src/main.rs",
            Rights::Read,
            Some(Rights::ReadWrite),
            Some(9),
        )
        .unwrap();
        assert!(crate::ids::is_well_formed(&ent.ent, ENT_PREFIX));
        assert_eq!(ent.rights, Rights::Read);
        assert_eq!(
            issue_ent("conn_a", "root_a", "../etc", Rights::Read, Some(Rights::Read), None),
            Err(DropError::PathUnsafe)
        );
    }
}
