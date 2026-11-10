//! The `workspaces` rows after a commit that removes workspaces.
//!
//! A commit that removes exactly one workspace and changes no other row but for its position
//! can move the later rows with a fixed number of statements; every other commit writes each
//! changed row by itself. Both must store the same rows: each live row at its place in the
//! desired order, the revision of the commit on each row it changed and on no other, the removed
//! row tombstoned with no position. The expected rows here are that rule, not a copy of either
//! path.

use serde_json::json;

use super::*;
use crate::resource_name::NameSource;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Row {
    key: String,
    name: String,
    name_revision: i64,
    position: Option<i64>,
    tombstoned: i64,
    updated_revision: i64,
    deleted_revision: Option<i64>,
}

fn workspace(index: u64) -> RegistryWorkspace {
    RegistryWorkspace {
        id: index + 1,
        public_id: WorkspacePublicId::parse(format!("ws_{:032x}", index + 1)).unwrap(),
        key: format!("key-{index}"),
        name: format!("ws {index}"),
        name_source: NameSource::User,
        name_revision: 0,
        group_key: "default".into(),
    }
}

/// Commits `workspaces` as the live registry and returns the registry revision of the commit.
fn commit(
    registry: &mut WorkspaceRegistry,
    kind: &str,
    about: &str,
    workspaces: &[RegistryWorkspace],
) -> i64 {
    let revision = registry.snapshot().unwrap().revision;
    registry
        .commit(
            &WorkspaceMutation::daemon(format!("{kind}-{about}-{revision}"), "test").unwrap(),
            &json!({"op": kind, "key": about, "at": revision}),
            None,
            Some(revision),
            kind,
            about,
            workspaces,
            &json!({"key": about}),
        )
        .unwrap();
    let snapshot = registry.snapshot().unwrap();
    // The resource batch of a commit writes its own revision on a row it makes; the expected
    // rows name one revision for both.
    assert_eq!(snapshot.revision, snapshot.resource_revision, "the fixture's two revisions");
    i64::try_from(snapshot.revision).unwrap()
}

/// Every `workspaces` row, in the order the workspaces were made.
fn rows(registry: &WorkspaceRegistry) -> Vec<Row> {
    let connection = registry.connection.get();
    let mut statement = connection
        .prepare(
            "SELECT workspace_key, name, name_revision, position, tombstoned, updated_revision,
                    deleted_revision
             FROM workspaces ORDER BY numeric_id",
        )
        .unwrap();
    statement
        .query_map([], |row| {
            Ok(Row {
                key: row.get(0)?,
                name: row.get(1)?,
                name_revision: row.get(2)?,
                position: row.get(3)?,
                tombstoned: row.get(4)?,
                updated_revision: row.get(5)?,
                deleted_revision: row.get(6)?,
            })
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

/// Makes `count` workspaces one after the other, then commits `desired` (their indexes, in the
/// new order; `renamed` gets a new name in the same commit) and compares every stored row with
/// the rule in the module comment.
fn check_rows_after(count: u64, desired: &[u64], renamed: Option<u64>, what: &str) {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let all = (0..count).map(workspace).collect::<Vec<_>>();
    for live in 1..=all.len() {
        commit(&mut registry, "workspace-added", &all[live - 1].key, &all[..live]);
    }
    let before = rows(&registry);
    assert_eq!(
        before.iter().map(|row| row.position).collect::<Vec<_>>(),
        (0..count).map(|position| i64::try_from(position).ok()).collect::<Vec<_>>(),
        "{what}: the fixture's positions"
    );

    let remaining = desired
        .iter()
        .map(|index| {
            let mut workspace = workspace(*index);
            if renamed == Some(*index) {
                workspace.name = "renamed".into();
                workspace.name_revision = 1;
            }
            workspace
        })
        .collect::<Vec<_>>();
    let removed = (0..count).find(|index| !desired.contains(index)).unwrap();
    let revision = commit(&mut registry, "workspace-closed", &format!("key-{removed}"), &remaining);

    let expected = before
        .iter()
        .zip(0..count)
        .map(|(row, index)| match desired.iter().position(|live| *live == index) {
            None => Row {
                position: None,
                tombstoned: 1,
                updated_revision: revision,
                deleted_revision: Some(revision),
                ..row.clone()
            },
            Some(position) => {
                let position = i64::try_from(position).ok();
                let is_renamed = renamed == Some(index);
                let changed = position != row.position || is_renamed;
                Row {
                    name: if is_renamed { "renamed".into() } else { row.name.clone() },
                    name_revision: i64::from(is_renamed),
                    position,
                    updated_revision: if changed { revision } else { row.updated_revision },
                    ..row.clone()
                }
            }
        })
        .collect::<Vec<_>>();
    assert_eq!(rows(&registry), expected, "{what}");
}

/// One workspace removed and nothing else changed: the commit that a move of the later rows can
/// take. A middle one, the first one (every row moves), the last one (no row moves), the one
/// before the last (one row moves) and the only one.
#[test]
fn a_removed_workspace_moves_each_later_row_one_position_down() {
    check_rows_after(7, &[0, 1, 2, 4, 5, 6], None, "a middle workspace");
    check_rows_after(7, &[1, 2, 3, 4, 5, 6], None, "the first workspace");
    check_rows_after(7, &[0, 1, 2, 3, 4, 5], None, "the last workspace");
    check_rows_after(7, &[0, 1, 2, 3, 4, 6], None, "the workspace before the last one");
    check_rows_after(1, &[], None, "the only workspace");
}

/// A commit that removes one workspace and also changes another row is not a plain move one
/// position down: each changed row is written by itself, and the stored rows obey the same rule.
#[test]
fn a_removal_with_another_change_writes_each_changed_row() {
    check_rows_after(7, &[0, 1, 2, 4, 5, 6], Some(5), "a later workspace renamed");
    check_rows_after(7, &[0, 1, 2, 4, 5, 6], Some(1), "an earlier workspace renamed");
    check_rows_after(7, &[0, 1, 2, 5, 4, 6], None, "two later workspaces change places");
    check_rows_after(7, &[1, 0, 2, 4, 5, 6], None, "two earlier workspaces change places");
    check_rows_after(7, &[0, 1, 2, 5, 6], None, "two workspaces removed");
    check_rows_after(7, &[0, 2, 4, 6], None, "three workspaces removed");
}
