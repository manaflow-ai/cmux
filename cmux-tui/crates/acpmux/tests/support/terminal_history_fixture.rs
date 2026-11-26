//! A real (non-sparse) 600 MiB Claude JSONL. Each turn has a prompt, an answer and a folded
//! tool. Tool results dominate the older history as they do in long terminal sessions.

use serde_json::json;
use std::io::{BufWriter, Write};
use std::path::Path;

pub const BYTES: u64 = 600 * 1024 * 1024;

/// Returns the number in the newest prompt so a browser can assert that exact text is visible.
pub fn write_600mib(path: &Path, session: &str, cwd: &Path) -> usize {
    let mut out = BufWriter::new(std::fs::File::create(path).unwrap());
    let mut size = 0;
    let tool = json!({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"fixture.log"}}]}}).to_string();
    let result = json!({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"x".repeat(8192)}]}}).to_string();
    let mut n = 0;
    loop {
        let prompt = if n == 0 { "day one needle".to_owned() } else { format!("review turn {n}") };
        let timestamp = if n == 0 { "2026-11-12T07:00:00Z" } else { "2026-11-24T07:00:00Z" };
        let user = json!({"type":"user","sessionId":session,"cwd":cwd,"timestamp":timestamp,"message":{"role":"user","content":prompt}});
        let reply = if n % 24 == 0 { "Review **complete**." } else { "Review complete." };
        let answer = json!({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":reply}]}});
        let block = format!("{user}\n{tool}\n{result}\n{answer}\n");
        if size + block.len() as u64 + 1024 > BYTES {
            // Fill the final small gap with a valid, complete JSON record.
            let fixed = "{\"type\":\"progress\",\"padding\":\"\"}\n";
            let len = usize::try_from(BYTES - size).unwrap();
            writeln!(
                out,
                "{{\"type\":\"progress\",\"padding\":\"{}\"}}",
                "x".repeat(len - fixed.len())
            )
            .unwrap();
            break;
        }
        out.write_all(block.as_bytes()).unwrap();
        size += block.len() as u64;
        n += 1;
    }
    out.flush().unwrap();
    n - 1
}
