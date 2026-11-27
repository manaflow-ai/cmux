//! Cold-tier aging of an overlay's content store ([`content::Content::age`]): bytes no chat read
//! for [`content::COLD_AFTER`] go cold (compressed), and are deleted [`content::DELETE_AFTER`]
//! after their last read unless a pin covers them. The reaper runs it on its timer, so the store
//! holds what chats read lately, not everything they ever read.

use std::time::SystemTime;

use super::*;
use content::{AgeReport, Aging};

impl Overlay {
    /// One aging pass over this overlay's content store at `now`; `None` without a store. Every
    /// blob of a pinned file is kept as it is.
    pub fn age(&self, now: SystemTime, aging: &Aging) -> Option<AgeReport> {
        let content = self.content.as_ref()?;
        let (files, _) = self.pinned_files();
        let pinned: HashSet<content::Name> = files
            .iter()
            .filter_map(|file| Some((*file, self.manifest.entry(*file)?.size)))
            .flat_map(|(file, size)| Self::keys_of(file, size))
            .filter_map(|key| self.content_name(key))
            .collect();
        Some(content.age(now, aging, &pinned))
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::content::{Content, Name};
    use super::*;
    use crate::overlay::WHOLE;

    const DAY: Duration = Duration::from_secs(24 * 60 * 60);

    fn name(path: &str, size: usize) -> Name {
        Name { path: path.into(), size: size as u64, mtime_ns: 1, part: WHOLE }
    }

    fn store(dir: &Path) -> Content {
        let content = Content::open(dir).unwrap();
        content.set_floor(0);
        content
    }

    #[test]
    fn unread_bytes_go_cold_then_are_deleted_unless_pinned() {
        let dir = tempfile::tempdir().unwrap();
        let content = store(dir.path());
        let now = SystemTime::now();
        let text = "fn main() { println!(\"hello\"); }\n".repeat(200);
        let bytes = |tag: &str| format!("{tag}{text}").into_bytes();
        let fresh = name("a", bytes("a").len());
        let stale = name("b", bytes("b").len());
        let kept = name("c", bytes("c").len());
        content.put(fresh.clone(), &bytes("a")).unwrap();
        content.put(stale.clone(), &bytes("b")).unwrap();
        content.put(kept.clone(), &bytes("c")).unwrap();
        content.set_read_at(&stale, now - 5 * DAY);
        content.set_read_at(&kept, now - 30 * DAY);
        let pinned: HashSet<Name> = [kept.clone()].into();

        let first = content.age(now, &Aging::default(), &pinned);
        assert_eq!((first.went_cold_blobs, first.kept_pinned), (1, 1));
        assert_eq!(first.went_cold_bytes, stale.size);
        assert!(first.went_cold_saved_bytes > stale.size / 2, "text compresses: {first:?}");
        assert_eq!((first.hot_blobs, first.cold_blobs), (2, 1));
        assert!(content.has(&stale), "a cold blob is still held");

        // Read again: it thaws, checked against its hash, and is hot.
        assert_eq!(content.get(&stale).unwrap().1, bytes("b"));
        let thawed = content.age(now, &Aging::default(), &pinned);
        assert_eq!((thawed.hot_blobs, thawed.cold_blobs), (3, 0));

        // Unread past the delete window: gone, unless pinned.
        content.set_read_at(&stale, now - 20 * DAY);
        content.age(now, &Aging::default(), &pinned);
        let last = content.age(now, &Aging::default(), &pinned);
        assert_eq!(last.deleted_blobs, 1);
        assert!(!content.has(&stale));
        assert!(content.has(&kept) && content.has(&fresh));
        assert!(last.kept_pinned >= 1);
    }

    #[test]
    fn ages_outlive_the_daemon() {
        let dir = tempfile::tempdir().unwrap();
        let now = SystemTime::now();
        let old = name("old.txt", 4096);
        {
            let content = store(dir.path());
            content.put(old.clone(), &[7u8; 4096]).unwrap();
            content.set_read_at(&old, now - 5 * DAY);
            assert_eq!(content.age(now, &Aging::default(), &HashSet::new()).went_cold_blobs, 1);
        }
        // A new daemon finds the cold blob with its last read, and deletes it on time.
        let content = store(dir.path());
        assert!(content.has(&old));
        let report = content.age(now + 10 * DAY, &Aging::default(), &HashSet::new());
        assert_eq!((report.cold_blobs, report.deleted_blobs), (0, 1));
        assert!(!content.has(&old));
    }

    #[test]
    fn a_blob_the_cache_links_stays_hot() {
        let dir = tempfile::tempdir().unwrap();
        let content = store(dir.path());
        let now = SystemTime::now();
        let used = name("used.txt", 100);
        let hash = content.put(used.clone(), &[1u8; 100]).unwrap();
        assert!(content.link(&hash, &dir.path().join("link")));
        content.set_read_at(&used, now - 5 * DAY);
        let report = content.age(now, &Aging::default(), &HashSet::new());
        assert_eq!((report.kept_linked, report.went_cold_blobs), (1, 0));
    }

    /// The before/after numbers for the PR: a store of real source files (this repo's crates)
    /// with reads spread over the last month, held as today (no aging) and after two passes.
    /// `cargo test -p cmux-projection hold_harness -- --ignored --nocapture`.
    #[test]
    #[ignore = "harness: prints numbers"]
    fn hold_harness() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let mut files = Vec::new();
        let mut stack = vec![root];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).into_iter().flatten().filter_map(Result::ok) {
                let path = entry.path();
                let Ok(kind) = entry.file_type() else { continue };
                if kind.is_dir() && entry.file_name() != "target" {
                    stack.push(path);
                } else if kind.is_file() {
                    files.push(path);
                }
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let content = store(dir.path());
        let now = SystemTime::now();
        let mut pinned = HashSet::new();
        for path in &files {
            let Ok(bytes) = fs::read(path) else { continue };
            let key = name(&path.display().to_string(), bytes.len());
            let Some(hash) = content.put(key.clone(), &bytes) else { continue };
            // Reads: 30% in the last day, 30% a week ago, 40% a month ago; 5% pinned.
            let ago = match hash[0] % 10 {
                0..=2 => DAY / 2,
                3..=5 => 7 * DAY,
                _ => 30 * DAY,
            };
            content.set_read_at(&key, now - ago);
            if hash[1] % 20 == 0 {
                pinned.insert(key);
            }
        }
        let before = content.age(now, &Aging { max_cold: 0, ..Aging::default() }, &HashSet::new());
        let started = std::time::Instant::now();
        let first = content.age(now, &Aging::default(), &pinned);
        let first_ms = started.elapsed().as_millis();
        let started = std::time::Instant::now();
        let second = content.age(now, &Aging::default(), &pinned);
        let second_ms = started.elapsed().as_millis();
        println!(
            "hold_harness files={} before_held={} before_hot={} after_held={} after_hot={} \
             after_cold_stored={} went_cold={} went_cold_saved={} deleted={} deleted_stored={} \
             aged_out={} kept_pinned={} pass1_ms={first_ms} pass2_ms={second_ms}",
            files.len(),
            before.held_bytes(),
            before.hot_bytes,
            second.held_bytes(),
            second.hot_bytes,
            second.cold_stored_bytes,
            first.went_cold_bytes,
            first.went_cold_saved_bytes,
            second.deleted_bytes,
            second.deleted_stored_bytes,
            first.aged_out_bytes() + second.aged_out_bytes(),
            second.kept_pinned,
        );
        assert!(second.held_bytes() < before.held_bytes());
    }

    /// Duress: one pass over 100,000 blobs, all old enough to age, bounded by
    /// [`content::MAX_COLD_PER_PASS`] compressions.
    #[test]
    #[ignore = "harness: prints numbers"]
    fn hold_duress() {
        let dir = tempfile::tempdir().unwrap();
        let content = store(dir.path());
        let now = SystemTime::now();
        for at in 0..100_000u32 {
            let bytes = format!("blob {at} {}", "x".repeat(200)).into_bytes();
            let key = name(&format!("f/{at}"), bytes.len());
            content.put(key.clone(), &bytes).unwrap();
            content.set_read_at(&key, now - 20 * DAY);
        }
        let started = std::time::Instant::now();
        let report = content.age(now, &Aging::default(), &HashSet::new());
        println!(
            "hold_duress blobs=100000 pass_ms={} went_cold={} deferred={}",
            started.elapsed().as_millis(),
            report.went_cold_blobs,
            report.deferred
        );
        assert_eq!(report.went_cold_blobs as usize, content::MAX_COLD_PER_PASS);
    }
}
