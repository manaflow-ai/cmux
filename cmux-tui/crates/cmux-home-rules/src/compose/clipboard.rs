//! The + menu's clipboard history rules (`HomeClipboardLog`, `HomeClipboardAccess` in
//! `CmuxNextHome/NativeTranscript/`): which copies the log keeps after a new one, and when an
//! activation may read the pasteboard. The pasteboard reads, the bytes and the thumbnails stay Swift.

use serde::{Deserialize, Serialize};

/// A copy already in the log, newest first: its size and whether it is the new copy again.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub bytes: u64,
    #[serde(default)]
    pub same: bool,
}

/// `clipboard.record`: the log's rows, the new copy's size and the log's caps.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordRequest {
    #[serde(default)]
    pub rows: Vec<Row>,
    pub bytes: u64,
    pub capacity: usize,
    pub max_total_bytes: u64,
}

/// The old rows that stay behind the new copy, by index, newest first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Kept {
    pub keep: Vec<usize>,
}

/// The new copy goes first and a copy it repeats leaves; then at most `capacity` entries, and the
/// oldest go until all fit `max_total_bytes`, the newest copy always staying (a picture over the
/// budget is the only entry). Caps under 1 count as 1.
pub fn record(r: &RecordRequest) -> Kept {
    let mut kept: Vec<(usize, u64)> = r
        .rows
        .iter()
        .enumerate()
        .filter(|(_, row)| !row.same)
        .map(|(i, row)| (i, row.bytes))
        .take(r.capacity.max(1).saturating_sub(1))
        .collect();
    let budget = r.max_total_bytes.max(1);
    let mut total = kept.iter().fold(r.bytes, |sum, &(_, bytes)| sum.saturating_add(bytes));
    while total > budget {
        let Some((_, bytes)) = kept.pop() else { break };
        total = total.saturating_sub(bytes);
    }
    Kept { keep: kept.into_iter().map(|(i, _)| i).collect() }
}

/// The pasteboard privacy behavior (`NSPasteboard.accessBehavior`; `noPrivacy` before macOS 15.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Access {
    NoPrivacy,
    AlwaysAllow,
    Default,
    AlwaysDeny,
}

/// `clipboard.readsWithoutAsking`.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessRequest {
    pub access: Access,
    #[serde(default)]
    pub default_reads: bool,
}

/// Whether an activation reads with no system prompt: always without privacy or when the person
/// allowed cmux, at `default` only when the Debug tunable lets it, never when denied.
pub fn reads_without_asking(r: AccessRequest) -> bool {
    match r.access {
        Access::NoPrivacy | Access::AlwaysAllow => true,
        Access::Default => r.default_reads,
        Access::AlwaysDeny => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rec(rows: &[(u64, bool)], bytes: u64, capacity: usize, max: u64) -> Vec<usize> {
        let rows = rows.iter().map(|&(bytes, same)| Row { bytes, same }).collect();
        record(&RecordRequest { rows, bytes, capacity, max_total_bytes: max }).keep
    }

    #[test]
    fn a_repeat_moves_to_the_front() {
        assert_eq!(rec(&[(1, false), (1, true), (1, false)], 1, 20, 100), vec![0, 2]);
    }

    #[test]
    fn capacity_drops_the_oldest() {
        assert_eq!(rec(&[(1, false), (1, false), (1, false)], 1, 3, 100), vec![0, 1]);
        assert_eq!(rec(&[(1, false)], 1, 1, 100), Vec::<usize>::new());
        assert_eq!(rec(&[(1, false)], 1, 0, 100), Vec::<usize>::new(), "a cap under 1 is 1");
    }

    #[test]
    fn the_byte_budget_keeps_the_newest() {
        assert_eq!(rec(&[(4, false), (4, false)], 4, 20, 10), vec![0]);
        assert_eq!(
            rec(&[(4, false)], 50, 20, 10),
            Vec::<usize>::new(),
            "a copy over the budget stays alone"
        );
        assert_eq!(
            rec(&[(2, true), (4, false)], 4, 20, 8),
            vec![1],
            "the repeat's bytes leave with it"
        );
    }

    #[test]
    fn access_cases() {
        for (access, default_reads, want) in [
            (Access::NoPrivacy, false, true),
            (Access::AlwaysAllow, false, true),
            (Access::Default, false, false),
            (Access::Default, true, true),
            (Access::AlwaysDeny, true, false),
        ] {
            assert_eq!(
                reads_without_asking(AccessRequest { access, default_reads }),
                want,
                "{access:?}"
            );
        }
    }

    #[test]
    fn ops_wire() {
        let out = crate::call(
            "compose.clipboard.record",
            &json!({"rows": [{"bytes": 3}, {"bytes": 1, "same": true}], "bytes": 1, "capacity": 20, "maxTotalBytes": 100}),
        );
        assert_eq!(out.unwrap(), json!({"keep": [0]}));
        let out = crate::call(
            "compose.clipboard.readsWithoutAsking",
            &json!({"access": "default", "defaultReads": true}),
        );
        assert_eq!(out.unwrap(), json!(true));
    }
}
