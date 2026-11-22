use super::*;

pub(crate) fn read_saved_tab_groups(
    connection: &Connection,
) -> anyhow::Result<Vec<SavedTabGroupRecord>> {
    let mut statement = connection.prepare(
        "SELECT saved_id, profile_id, name, color, members_json, updated_at_ms
         FROM personal_saved_tab_groups
         ORDER BY position ASC, saved_id ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, i64>(5)?,
        ))
    })?;
    let mut saved = Vec::new();
    for row in rows {
        let (id, room, name, color, members, updated_at_ms) = row?;
        saved.push(SavedTabGroupRecord {
            id,
            room,
            name,
            color,
            members: serde_json::from_str(&members)
                .context("saved tab group members are invalid")?,
            updated_at_ms: u64::try_from(updated_at_ms)?,
        });
    }
    Ok(saved)
}

/// Create or replace a saved tab group in the caller's transaction, keeping
/// its bar position and room (new records go last, in `record.room`).
pub(crate) fn put_saved_tab_group_in(
    transaction: &Transaction<'_>,
    record: &SavedTabGroupRecord,
) -> anyhow::Result<()> {
    validate_workspace_group_id(&record.id)?;
    validate_workspace_group_id(&record.room)?;
    validate_tab_group_name(&record.name)?;
    validate_tab_group_color(&record.color)?;
    let position = match transaction
        .query_row(
            "SELECT position FROM personal_saved_tab_groups WHERE saved_id = ?1",
            [&record.id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
    {
        Some(position) => position,
        None => transaction.query_row(
            "SELECT COALESCE(MAX(position) + 1, 0) FROM personal_saved_tab_groups",
            [],
            |row| row.get::<_, i64>(0),
        )?,
    };
    transaction.execute(
        "INSERT INTO personal_saved_tab_groups(
           saved_id, profile_id, name, color, members_json, position, updated_at_ms
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(saved_id) DO UPDATE SET
           profile_id = excluded.profile_id,
           name = excluded.name,
           color = excluded.color,
           members_json = excluded.members_json,
           updated_at_ms = excluded.updated_at_ms",
        params![
            record.id,
            record.room,
            record.name,
            record.color,
            serde_json::to_string(&record.members)?,
            position,
            i64::try_from(record.updated_at_ms)?
        ],
    )?;
    append_presentation_record(
        transaction,
        "tab.saved_group.updated",
        vec![JournalSubject { kind: "saved_tab_group".into(), id: record.id.clone() }],
        &json!({"saved_group": record}),
    )
}

/// Delete a saved tab group in the caller's transaction and unlink live
/// groups from it. Returns whether it existed.
pub(crate) fn delete_saved_tab_group_in(
    transaction: &Transaction<'_>,
    saved_id: &str,
) -> anyhow::Result<bool> {
    let removed = transaction
        .execute("DELETE FROM personal_saved_tab_groups WHERE saved_id = ?1", [saved_id])?
        > 0;
    if removed {
        transaction
            .execute("UPDATE tab_groups SET saved_id = NULL WHERE saved_id = ?1", [saved_id])?;
        append_presentation_record(
            transaction,
            "tab.saved_group.deleted",
            vec![JournalSubject { kind: "saved_tab_group".into(), id: saved_id.to_string() }],
            &json!({"saved_id": saved_id}),
        )?;
    }
    Ok(removed)
}
