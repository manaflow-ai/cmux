use super::*;

fn ctx() -> Ctx {
    let mut c = Ctx::new("claude", "s-1".into(), "a-1".into(), "coord".into());
    c.tool_kinds = vec![("execute".into(), 3), ("read".into(), 1)];
    c
}

fn whole(l: &Line) -> String {
    format!("{}{}{}\n", l.head(), crate::event::filler(1, l.fill as usize), l.tail())
}

#[test]
fn every_line_is_json_of_its_size() {
    let keys = [
        ("in:agent_message_chunk", true),
        ("in:tool_call", true),
        ("in:tool_call.replay", true),
        ("in:tool_call_update", true),
        ("in:usage_update", true),
        ("in:session_info_update", true),
        ("in:claude.assistant", false),
        ("in:claude.system.init", false),
        ("in:claude.result.success", false),
        ("in:codex.response", false),
        ("in:codex.turn/diff/updated", false),
        ("in:response", false),
        ("in:other", false),
        ("out:session/prompt", false),
        ("out:response", false),
        ("out:claude.stdin", false),
        ("mux:user_message", false),
        ("mux:status", false),
        ("mux:turn_end", false),
        ("mux:other", false),
        ("mux:git", false),
    ];
    let mut c = ctx();
    for (k, upd) in keys {
        for target in [10u64, 400, 5000] {
            let l = render(k, 7, 1_790_000_000_000, target, upd, &mut c);
            let s = whole(&l);
            let v: serde_json::Value =
                serde_json::from_str(s.trim_end()).unwrap_or_else(|e| panic!("{k}: {e}: {s}"));
            let (dir, kind) = record_kind(k);
            assert_eq!(v["dir"], dir);
            assert_eq!(v["kind"], kind);
            assert_eq!(v["seq"], 7);
            if upd {
                assert_eq!(v["msg"]["method"], "session/update");
                assert!(v["msg"]["params"]["update"]["sessionUpdate"].is_string());
            }
            if target == 5000 {
                assert_eq!(s.len() as u64, 5000, "{k}");
            }
            assert_eq!(s.len() as u64, l.len());
        }
    }
}
