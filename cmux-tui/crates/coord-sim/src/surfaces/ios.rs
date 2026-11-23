//! `coord-sim surface --target ios --out DIR`: one coordinator's records as the iOS list rig's replay fixture.
//!
//! DIR/coord-sim-chat.ndjson holds chat 0's history then its live records, one acpmux record a line; a live record's
//! `at` is the last history record's `at` plus its offset (ms, after the rate), so the rig paces them as they came.
//! DIR/coord-sim-chat.json says where the history ends ({"history": N, "live": M, "rate": X}): the rig hands the
//! first N to the chat view as one attach page and streams the rest
//! (cmux-next-ios ListStressRig, CMUX_MOBILE_LIST_EVENTS; scripts/ci/cmux-next-ios-sim.sh listperf case coord-sim).

use super::records::{self, Plan};
use crate::shape::Shape;
use serde_json::json;

pub fn run(args: &[String]) -> Result<(), String> {
    let shape = Shape::load(crate::flag(args, "--shape"))?;
    let mut plan = Plan::from_args(args)?;
    plan.coordinators = 1;
    let out = crate::flag(args, "--out").ok_or("--out DIR")?;
    std::fs::create_dir_all(out).map_err(|e| format!("{out}: {e}"))?;
    let chat = records::chats(&shape, &plan).into_iter().next().ok_or("no chat")?;
    let base = chat.history.last().and_then(|r| r["at"].as_u64()).unwrap_or(0);
    let mut text = String::new();
    for r in &chat.history {
        text.push_str(&r.to_string());
        text.push('\n');
    }
    for (offset, r) in &chat.live {
        let mut r = r.clone();
        if let Some(o) = r.as_object_mut() {
            o.insert("at".into(), json!(base + offset));
        }
        text.push_str(&r.to_string());
        text.push('\n');
    }
    let path = format!("{out}/coord-sim-chat.ndjson");
    std::fs::write(&path, &text).map_err(|e| format!("{path}: {e}"))?;
    let meta = json!({ "history": chat.history.len(), "live": chat.live.len(), "rate": plan.rate, "bytes": text.len(), "seed": plan.seed });
    let path = format!("{out}/coord-sim-chat.json");
    std::fs::write(&path, meta.to_string()).map_err(|e| format!("{path}: {e}"))?;
    println!("{meta}");
    Ok(())
}
