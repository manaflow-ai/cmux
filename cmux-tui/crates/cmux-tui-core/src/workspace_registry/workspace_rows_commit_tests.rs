//! The `workspaces` rows after a commit that removes workspaces.
//!
//! A commit that removes exactly one workspace and changes no other row but for its position
//! moves the later rows with a fixed number of statements (`move_later_rows_one_down`); every
//! other commit writes each changed row by itself (`write_changed_rows`). Both must store the
//! same rows: each live row at its place in the desired order, the revision of the commit on
//! each row it changed and on no other, the removed row tombstoned with no position.
//!
//! Each case runs the ledger commit ALONE, on a transaction with no resource batch. The whole
//! commit (`WorkspaceRegistry::commit`) also applies a resource batch, and its
//! `SetWorkspaceOrder` sets each position of the same table again: through it, a wrong position
//! of the ledger commit is repaired before a test can read it. A case checks three things:
//! 1. the path that the commit takes: `one_removed_row` gives the removed row or `None`;
//! 2. the stored rows, column by column, against the rows that `write_changed_rows` stores for
//!    the same commit in a second registry (the path before the move against the path with it);
//! 3. the stored rows against the rule above, which is a copy of neither path.

use serde_json::json;

use super::*;
use crate::resource_name::NameSource;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Row {
    key: String,
    numeric_id: i64,
    name: String,
    group_key: String,
    position: Option<i64>,
    tombstoned: i64,
    created_revision: i64,
    updated_revision: i64,
    deleted_revision: Option<i64>,
    name_source: String,
    name_revision: i64,
}

fn workspace(index: usize) -> RegistryWorkspace {
    let id = u64::try_from(index).unwrap() + 1;
    RegistryWorkspace {
        id,
        public_id: WorkspacePublicId::parse(format!("ws_{id:032x}")).unwrap(),
        key: format!("key-{index}"),
        name: format!("ws {index}"),
        name_source: NameSource::User,
        name_revision: 0,
        group_key: "default".into(),
    }
}

/// A registry with `count` workspaces, each one made by a whole commit of its own. Then
/// `stored_change` (one SQL statement, or "" for none) changes the stored `workspaces` rows to a
/// state that no commit of this fixture gives.
fn registry_with(count: usize, stored_change: &str) -> WorkspaceRegistry {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let all = (0..count).map(workspace).collect::<Vec<_>>();
    for live in 1..=count {
        let revision = registry.snapshot().unwrap().revision;
        let key = &all[live - 1].key;
        registry
            .commit(
                &WorkspaceMutation::daemon(format!("added-{key}"), "test").unwrap(),
                &json!({"op": "workspace-added", "key": key}),
                None,
                Some(revision),
                "workspace-added",
                key,
                &all[..live],
                &json!({"key": key}),
            )
            .unwrap();
    }
    if !stored_change.is_empty() {
        registry.connection.get().execute(stored_change, []).unwrap();
    }
    registry
}

/// Every column of every `workspaces` row, in the order the workspaces were made.
fn rows(registry: &WorkspaceRegistry) -> Vec<Row> {
    let connection = registry.connection.get();
    let mut statement = connection
        .prepare(
            "SELECT workspace_key, numeric_id, name, group_key, position, tombstoned,
                    created_revision, updated_revision, deleted_revision, name_source,
                    name_revision
             FROM workspaces ORDER BY numeric_id",
        )
        .unwrap();
    statement
        .query_map([], |row| {
            Ok(Row {
                key: row.get(0)?,
                numeric_id: row.get(1)?,
                name: row.get(2)?,
                group_key: row.get(3)?,
                position: row.get(4)?,
                tombstoned: row.get(5)?,
                created_revision: row.get(6)?,
                updated_revision: row.get(7)?,
                deleted_revision: row.get(8)?,
                name_source: row.get(9)?,
                name_revision: row.get(10)?,
            })
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

/// What a commit changes on one remaining workspace (its index), besides the removal.
#[derive(Debug, Clone, Copy)]
enum Change {
    None,
    /// A new name, with the next name revision.
    Renamed(usize),
    /// Another group, and nothing else.
    Regrouped(usize),
    /// Another numeric id at the same key, and nothing else.
    Renumbered(usize),
}

/// The numeric id of [`Change::Renumbered`]: no workspace of a fixture has it.
const OTHER_NUMERIC_ID: u64 = 100;

/// [`check_rows_after_change`] with a rename, or with no other change.
fn check_rows_after(
    count: usize,
    stored_change: &str,
    desired: &[usize],
    renamed: Option<usize>,
    moved: Option<usize>,
    what: &str,
) {
    let change = renamed.map_or(Change::None, Change::Renamed);
    check_rows_after_change(count, stored_change, desired, change, moved, what);
}

/// One commit on a registry of `count` workspaces (see [`registry_with`] for `stored_change`):
/// `desired` are the indexes of the workspaces that stay, in the new order (an index from `count`
/// up is a workspace that the commit adds), and `change` is what the same commit changes on one
/// of them. `moved` is the path that the commit must take: `Some(n)` when it is a plain removal
/// with `n` rows after the removed one (the two-statement move), `None` when each changed row is
/// written by itself.
fn check_rows_after_change(
    count: usize,
    stored_change: &str,
    desired: &[usize],
    change: Change,
    moved: Option<usize>,
    what: &str,
) {
    let with_the_move = registry_with(count, stored_change);
    let each_row = registry_with(count, stored_change);
    let before = rows(&with_the_move);
    assert_eq!(before, rows(&each_row), "{what}: the two fixtures");
    if stored_change.is_empty() {
        assert_eq!(
            before.iter().map(|row| row.position).collect::<Vec<_>>(),
            (0..count).map(|position| i64::try_from(position).ok()).collect::<Vec<_>>(),
            "{what}: the fixture's positions"
        );
    }

    let remaining = desired
        .iter()
        .map(|index| {
            let mut workspace = workspace(*index);
            match change {
                Change::Renamed(at) if at == *index => {
                    workspace.name = "renamed".into();
                    workspace.name_revision = 1;
                }
                Change::Regrouped(at) if at == *index => workspace.group_key = "other".into(),
                Change::Renumbered(at) if at == *index => workspace.id = OTHER_NUMERIC_ID,
                _ => {}
            }
            workspace
        })
        .collect::<Vec<_>>();
    let removed = (0..count).find(|index| !desired.contains(index)).unwrap();
    let removed_key = format!("key-{removed}");
    let current = with_the_move.snapshot().unwrap().revision;
    let revision = i64::try_from(current).unwrap() + 1;

    // The commit under test: the ledger rows alone, no resource batch after them.
    let written = {
        let connection = with_the_move.connection.get();
        let transaction = connection.unchecked_transaction().unwrap();
        let stored = live_rows(&transaction).unwrap();
        let found = one_removed_row(&stored, &desired_rows(&remaining), &remaining).unwrap();
        assert_eq!(
            found.map(|found| (found.key.to_string(), Some(found.position), found.later)),
            moved.map(|later| (removed_key.clone(), before[removed].position, later)),
            "{what}: the plain removal that the commit finds (key, stored position, rows after it)"
        );
        let (committed, _, written) = commit_workspace_rows_in_transaction(
            &transaction,
            &WorkspaceMutation::daemon("the-commit-under-test", "test").unwrap(),
            "fingerprint",
            Some(current),
            "workspace-closed",
            &removed_key,
            &remaining,
            "{}",
        )
        .unwrap();
        assert_eq!(committed, current + 1, "{what}: the revision of the commit");
        transaction.commit().unwrap();
        written
    };
    // The same commit's rows in the second registry, each changed row written by itself.
    let written_each_row = {
        let connection = each_row.connection.get();
        let transaction = connection.unchecked_transaction().unwrap();
        let stored = live_rows(&transaction).unwrap();
        let desired = desired_rows(&remaining);
        let written =
            write_changed_rows(&transaction, &stored, &desired, &remaining, revision).unwrap();
        transaction.commit().unwrap();
        written
    };
    let after = rows(&with_the_move);
    assert_eq!(after, rows(&each_row), "{what}: the commit's rows, then `write_changed_rows`'s");
    assert_eq!(written, written_each_row, "{what}: the keys whose row the commit wrote");

    // A workspace that the commit adds: a new live row at its place, made by this commit.
    let added = desired.iter().enumerate().filter(|(_, index)| **index >= count).map(
        |(position, index)| {
            let workspace = workspace(*index);
            Row {
                key: workspace.key,
                numeric_id: i64::try_from(workspace.id).unwrap(),
                name: workspace.name,
                group_key: workspace.group_key,
                position: i64::try_from(position).ok(),
                tombstoned: 0,
                created_revision: revision,
                updated_revision: revision,
                deleted_revision: None,
                name_source: "user".into(),
                name_revision: 0,
            }
        },
    );
    let mut expected = before
        .iter()
        .enumerate()
        .map(|(index, row)| match desired.iter().position(|live| *live == index) {
            None => Row {
                position: None,
                tombstoned: 1,
                updated_revision: revision,
                deleted_revision: Some(revision),
                ..row.clone()
            },
            Some(position) => {
                let position = i64::try_from(position).ok();
                let is_renamed = matches!(change, Change::Renamed(at) if at == index);
                let is_regrouped = matches!(change, Change::Regrouped(at) if at == index);
                let is_renumbered = matches!(change, Change::Renumbered(at) if at == index);
                let changed =
                    position != row.position || is_renamed || is_regrouped || is_renumbered;
                Row {
                    numeric_id: if is_renumbered {
                        i64::try_from(OTHER_NUMERIC_ID).unwrap()
                    } else {
                        row.numeric_id
                    },
                    name: if is_renamed { "renamed".into() } else { row.name.clone() },
                    group_key: if is_regrouped { "other".into() } else { row.group_key.clone() },
                    name_revision: i64::from(is_renamed),
                    position,
                    updated_revision: if changed { revision } else { row.updated_revision },
                    ..row.clone()
                }
            }
        })
        .chain(added)
        .collect::<Vec<_>>();
    // `rows` reads in the order of the numeric id, which `Change::Renumbered` changes.
    expected.sort_by_key(|row| row.numeric_id);
    assert_eq!(after, expected, "{what}: the commit's rows, then the rule's");
}

/// One workspace removed and nothing else changed: the commit that the move of the later rows
/// takes. A middle one, the first one (every row moves), the last one (no row moves), the one
/// before the last (one row moves) and the only one.
#[test]
fn a_removed_workspace_moves_each_later_row_one_position_down() {
    check_rows_after(7, "", &[0, 1, 2, 4, 5, 6], None, Some(3), "a middle workspace");
    check_rows_after(7, "", &[1, 2, 3, 4, 5, 6], None, Some(6), "the first workspace");
    check_rows_after(7, "", &[0, 1, 2, 3, 4, 5], None, Some(0), "the last workspace");
    check_rows_after(7, "", &[0, 1, 2, 3, 4, 6], None, Some(1), "the one before the last");
    check_rows_after(1, "", &[], None, Some(0), "the only workspace");
}

/// A commit that removes one workspace and also changes another row is not a plain move one
/// position down: each changed row is written by itself, and the stored rows obey the same rule.
#[test]
fn a_removal_with_another_change_writes_each_changed_row() {
    check_rows_after(7, "", &[0, 1, 2, 4, 5, 6], Some(5), None, "a later workspace renamed");
    check_rows_after(7, "", &[0, 1, 2, 4, 5, 6], Some(1), None, "an earlier workspace renamed");
    check_rows_after(7, "", &[0, 1, 2, 5, 4, 6], None, None, "two later ones change places");
    check_rows_after(7, "", &[1, 0, 2, 4, 5, 6], None, None, "two earlier ones change places");
    check_rows_after(7, "", &[0, 1, 2, 5, 6], None, None, "two workspaces removed");
    check_rows_after(7, "", &[0, 2, 4, 6], None, None, "three workspaces removed");
}

/// Stored live positions that are not `0..n` (no commit of today stores such rows; a database of
/// an older build or a damaged one can have them). The move is not taken: it needs each later row
/// exactly one position above its desired one. Each row is written by itself, which also puts the
/// rows back at `0..n`. The one exception is correct too: when only the removed LAST row is out
/// of place, no other row has to change.
#[test]
fn a_removal_from_stored_positions_with_a_gap_or_below_zero_writes_each_row() {
    let all = "UPDATE workspaces SET position = position + 100 WHERE tombstoned = 0";
    let last_two = "UPDATE workspaces SET position = position + 100 WHERE position > 4";
    let last_one = "UPDATE workspaces SET position = position + 100 WHERE position > 5";
    let below_zero = "UPDATE workspaces SET position = -position - 100 WHERE tombstoned = 0";
    check_rows_after(7, all, &[0, 1, 2, 4, 5, 6], None, None, "every position 100 too high");
    check_rows_after(7, last_two, &[0, 1, 2, 4, 5, 6], None, None, "a gap in the later rows");
    check_rows_after(7, last_two, &[0, 1, 2, 3, 4, 5], None, None, "the last one, after a gap");
    check_rows_after(7, last_one, &[0, 1, 2, 3, 4, 5], None, Some(0), "only the last one moved");
    check_rows_after(7, below_zero, &[0, 1, 2, 4, 5, 6], None, None, "every position below zero");
}

/// A stored live row with no position (as above: no commit of today stores one). The move needs
/// the stored position of the removed row and of each remaining one, so it is not taken when the
/// removed row has none, or when a row after it has none.
#[test]
fn a_removal_from_a_stored_row_with_no_position_writes_each_row() {
    let removed = "UPDATE workspaces SET position = NULL WHERE position = 3";
    let later = "UPDATE workspaces SET position = NULL WHERE position = 5";
    check_rows_after(7, removed, &[0, 1, 2, 4, 5, 6], None, None, "the removed row, no position");
    check_rows_after(7, later, &[0, 1, 2, 4, 5, 6], None, None, "a later row, no position");
}

/// As many stored rows as the desired workspaces and one more, but two rows removed and one
/// added (index 7): the count is that of a plain removal, the rows are not.
#[test]
fn two_removals_and_one_added_workspace_write_each_changed_row() {
    check_rows_after(7, "", &[0, 1, 2, 4, 5, 7], None, None, "two removed, one added");
    check_rows_after(7, "", &[7, 0, 1, 2, 4, 5], None, None, "two removed, one added first");
}

/// One column of one remaining workspace changed, with no new name: the group alone, the numeric
/// id alone (no commit of today gives a key another numeric id; the move must not hide such a
/// write). On a workspace after the removed one and on a workspace before it, which keeps its
/// position.
#[test]
fn a_removal_with_another_group_or_numeric_id_writes_each_changed_row() {
    let desired = [0, 1, 2, 4, 5, 6];
    for at in [5, 1] {
        let (group, id) = (Change::Regrouped(at), Change::Renumbered(at));
        check_rows_after_change(7, "", &desired, group, None, &format!("{at} in another group"));
        check_rows_after_change(7, "", &desired, id, None, &format!("{at}, another numeric id"));
    }
}

/// The name's source alone (the automatic namer takes a user's name, at the stored name
/// revision): not a plain removal, so the row is written by itself, and that write's fence of the
/// stored name refuses the commit (`workspace_name_store::fence_stored_name`). The move has no
/// fence: it is safe only because `one_removed_row` gives no row when a name's provenance differs.
#[test]
fn a_removal_with_another_name_source_is_not_a_plain_removal_and_is_refused() {
    let registry = registry_with(7, "");
    let mut remaining = [0, 1, 2, 4, 5, 6].into_iter().map(workspace).collect::<Vec<_>>();
    remaining[4].name_source = NameSource::Auto;
    let current = registry.snapshot().unwrap().revision;
    let connection = registry.connection.get();
    let transaction = connection.unchecked_transaction().unwrap();
    let stored = live_rows(&transaction).unwrap();
    let found = one_removed_row(&stored, &desired_rows(&remaining), &remaining).unwrap();
    assert!(found.is_none(), "another name source: the commit finds a plain removal");
    let Err(refused) = commit_workspace_rows_in_transaction(
        &transaction,
        &WorkspaceMutation::daemon("the-commit-under-test", "test").unwrap(),
        "fingerprint",
        Some(current),
        "workspace-closed",
        "key-3",
        &remaining,
        "{}",
    ) else {
        panic!("another name source at the stored name revision: the commit is not refused");
    };
    let conflict = refused.downcast_ref::<crate::resource::ResourceError>();
    assert_eq!(
        conflict.map(|error| error.code.as_str()),
        Some("revision.conflict"),
        "the refusal: {refused:#}"
    );
}
