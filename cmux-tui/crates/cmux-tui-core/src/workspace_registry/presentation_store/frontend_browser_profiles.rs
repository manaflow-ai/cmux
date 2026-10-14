//! Frontend browser tabs of a deleted browser profile (cx-d0d.89): the
//! delete moves them to the default profile in its own transaction, so no
//! record names a profile that no longer exists, whichever client deleted it.

use super::*;

/// Clears `profile_id` from every frontend browser tab that names it, each
/// with its `browser.frontend.updated` fact, and returns their browser ids.
pub(crate) fn clear_frontend_browser_profile(
    transaction: &Transaction<'_>,
    profile_id: &str,
) -> anyhow::Result<Vec<String>> {
    let browser_ids = transaction
        .prepare(
            "SELECT browser_id FROM frontend_browser_tabs WHERE profile_id = ?1
             ORDER BY browser_id ASC",
        )?
        .query_map([profile_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    transaction.execute(
        "UPDATE frontend_browser_tabs SET profile_id = NULL WHERE profile_id = ?1",
        [profile_id],
    )?;
    for browser_id in &browser_ids {
        let record = read_frontend_browser(transaction, browser_id)?;
        append_presentation_record(
            transaction,
            "browser.frontend.updated",
            vec![browser_subject(browser_id)],
            &json!({"browser_id": browser_id, "browser": record}),
        )?;
    }
    Ok(browser_ids)
}
