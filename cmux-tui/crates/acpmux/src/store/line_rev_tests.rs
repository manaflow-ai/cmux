//! `for_each_line_rev` over a real file (`store/log_line.rs`).

use super::*;
use std::os::unix::fs::PermissionsExt;

/// Lines come newest first, whole, whatever blocks they span; blank lines are skipped.
#[test]
fn lines_across_blocks_come_back_whole_newest_first() {
    let path = std::env::temp_dir().join(format!(
        "acpmux-line-rev-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let lines =
        ["a".to_owned(), "x".repeat(200_000), String::new(), "b".repeat(65_535), "c".into()];
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut seen = Vec::new();
    for_each_line_rev(&path, &mut |line| {
        seen.push(String::from_utf8(line.to_vec()).unwrap());
        true
    })
    .unwrap();
    let _ = std::fs::remove_file(&path);
    let want: Vec<String> = lines.iter().rev().filter(|l| !l.is_empty()).cloned().collect();
    assert_eq!(seen.len(), want.len());
    assert!(seen == want, "lines came back changed or out of order");
}

/// `start_of_seq` gives a line start before which every record is older than `from`, close to the
/// first that is not, over lines longer than its probe; a head it cannot read ends its search at
/// a line it knows is older, never past a wanted one.
#[test]
fn start_of_seq_rounds_down_to_a_line_start() {
    let path = std::env::temp_dir().join(format!(
        "acpmux-start-of-seq-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let mut body = String::new();
    let mut starts = Vec::new();
    for seq in 1..=600u64 {
        starts.push((body.len() as u64, seq));
        let pad = if seq % 50 == 0 { 70_000 } else { 900 };
        if seq == 450 {
            // An older field order: no seq head to read.
            body.push_str(&format!("{{\"at\":1,\"seq\":{seq},\"pad\":\"{}\"}}\n", "y".repeat(pad)));
        } else {
            body.push_str(&format!("{{\"seq\":{seq},\"at\":1,\"pad\":\"{}\"}}\n", "y".repeat(pad)));
        }
    }
    std::fs::write(&path, &body).unwrap();
    let mut file = std::fs::File::open(&path).unwrap();
    for from in [0, 1, 2, 49, 50, 51, 200, 449, 450, 451, 599, 600, 601, 10_000] {
        let off = start_of_seq(&mut file, from).unwrap();
        let line = starts.iter().find(|(start, _)| *start == off);
        assert!(off == 0 || line.is_some(), "from {from}: {off} is not a line start");
        let seq_there = line.map_or(1, |(_, seq)| *seq);
        assert!(
            seq_there <= from.max(1),
            "from {from}: the read starts past it, at seq {seq_there}"
        );
        // Close below `from` away from the unreadable head: at most a probe and a long line.
        if from > 1 && from < 440 {
            let (want, _) = starts[(from - 1) as usize];
            assert!(
                want - off <= 16 * 1024 + 72_000,
                "from {from}: {} bytes before it",
                want - off
            );
        }
    }
    let _ = std::fs::remove_file(&path);
}
