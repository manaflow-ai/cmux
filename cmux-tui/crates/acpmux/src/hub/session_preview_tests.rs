use super::*;

fn token() -> String {
    // Assembled at run time, as in `secret_scan_tests.rs`.
    let body: String = "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS".chars().cycle().take(36).collect();
    format!("gh{}_{}", "p", body)
}

/// The old fold: every word joined, then cut.
fn folded(s: &str, max: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= max {
        s
    } else {
        let mut out: String = s.chars().take(max).collect();
        out.push('…');
        out
    }
}

#[test]
fn short_text_reads_as_the_full_fold_did() {
    for s in ["", " ", "a", "ab cd", "  ab \n\t cd  ", "ééé ééé", "one two three four"] {
        for max in 0..12 {
            assert_eq!(short_text(s, max), folded(s, max), "{s:?} at {max}");
        }
    }
}

/// A Chief compactor prompt (about 3.1 MB): its preview reads the same as masking all of it,
/// a secret at its head is masked, and only a head is scanned.
#[test]
fn a_long_prompts_preview_masks_its_head_only() {
    let secret = token();
    let long = format!("Compaction: use {secret} now\n{}", "view line\n".repeat(320_000));
    assert!(long.len() > 3_000_000);
    let preview = masked_preview(&long, 200);
    assert_eq!(preview, short_text(&crate::secret_scan::mask(&long), 200));
    assert!(!preview.contains(&secret), "{preview}");
    assert!(preview_head(&long, 200).len() < 200 * 1024);
    let started = std::time::Instant::now();
    for _ in 0..10 {
        masked_preview(&long, 200);
    }
    let head = started.elapsed() / 10;
    let started = std::time::Instant::now();
    short_text(&crate::secret_scan::mask(&long), 200);
    let whole = started.elapsed();
    eprintln!("masked_preview of {} bytes: head {head:?}, whole {whole:?}", long.len());
}

/// Whitespace the preview folds away cannot hide a secret past the head: the whole text is
/// scanned then.
#[test]
fn a_head_of_whitespace_scans_the_whole_text() {
    let secret = token();
    let long = format!("a{}{secret} b", " ".repeat(400_000));
    assert_eq!(preview_head(&long, 200).len(), long.len());
    assert!(!masked_preview(&long, 200).contains(&secret));
}
