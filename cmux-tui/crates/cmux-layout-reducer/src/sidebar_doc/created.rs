//! When a workspace joined the sidebar document (plans/cmux-next/remote-groups-per-machine-DESIGN.md
//! R3): the one-list sidebar lists every computer's workspaces by this time. The reducer keeps no
//! clock, so the daemon stamps the time on each adopted reference before it applies the ops.
//! The document finds an item by session and workspace id only, so the stamp changes no lookup.

use super::model::{Op, WorkspaceRef};
use serde_json::Value;

/// The key of a workspace reference's creation time, in milliseconds since 1970 (`extra.created_ms`).
pub const CREATED_MS_KEY: &str = "created_ms";

/// Stamps `now_ms` on every reference an `adopt` in `ops` places that has no creation time yet.
/// A reference that already carries one (a reopened workspace, a replayed op) keeps it.
pub fn stamp_created(ops: &mut [Op], now_ms: u64) {
    for op in ops {
        let Op::Adopt { refs, .. } = op else { continue };
        for reference in refs {
            reference.extra.entry(CREATED_MS_KEY).or_insert_with(|| Value::from(now_ms));
        }
    }
}

/// Now, in milliseconds since 1970 (0 when the clock reads before 1970): the daemon's stamp.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

/// The creation time `reference` carries, if any.
pub fn created_ms(reference: &WorkspaceRef) -> Option<u64> {
    reference.extra.get(CREATED_MS_KEY).and_then(Value::as_u64)
}

#[cfg(test)]
mod tests {
    use super::super::reduce::apply_in_place;
    use super::super::*;
    use super::*;

    fn adopt(workspace: &str) -> Op {
        Op::Adopt { refs: vec![WorkspaceRef::new("mini", workspace)], to: None }
    }

    #[test]
    fn adopt_stamps_created_ms_on_new_refs_only() {
        let mut kept = WorkspaceRef::new("mini", "ws_old");
        kept.extra.insert(CREATED_MS_KEY.into(), Value::from(5u64));
        let mut ops = vec![adopt("ws_new"), Op::Adopt { refs: vec![kept], to: None }];
        stamp_created(&mut ops, 1_700_000_000_000);
        let Op::Adopt { refs, .. } = &ops[0] else { panic!("adopt") };
        assert_eq!(created_ms(&refs[0]), Some(1_700_000_000_000));
        let Op::Adopt { refs, .. } = &ops[1] else { panic!("adopt") };
        assert_eq!(created_ms(&refs[0]), Some(5), "an existing time is kept");
    }

    #[test]
    fn the_stamped_time_lives_on_the_item_and_changes_no_lookup() {
        let mut doc = Doc::from_parts(1, vec![Section::machine("mini")], vec![]);
        let mut ops = vec![adopt("ws_new")];
        stamp_created(&mut ops, 42);
        apply_in_place(&mut doc, &ops, &mut || "itm_x".to_string()).unwrap();
        let item = doc
            .workspace_item(&WorkspaceRef::new("mini", "ws_new"))
            .expect("found without the stamp");
        let Body::Workspace { reference } = &item.body else { panic!("workspace body") };
        assert_eq!(created_ms(reference), Some(42));
    }
}
