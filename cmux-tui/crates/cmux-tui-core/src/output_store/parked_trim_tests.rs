use super::*;

const MIB: u64 = 1024 * 1024;

fn id(n: u8) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{n:032x}")).unwrap()
}

fn parked(n: u8, days_ago: u64, kept_lines: Option<usize>, bytes: u64) -> Parked {
    Parked { terminal_id: id(n), written_at_ms: NOW - days_ago * DAY_MS, kept_lines, bytes }
}

const NOW: u64 = 100 * DAY_MS;

#[test]
fn snapshots_keep_fewer_lines_as_they_age() {
    assert_eq!(Keep::for_age(0), Keep::All);
    assert_eq!(Keep::for_age(DAY_MS - 1), Keep::All);
    assert_eq!(Keep::for_age(DAY_MS), Keep::Lines(WEEK_LINES));
    assert_eq!(Keep::for_age(7 * DAY_MS), Keep::Lines(MONTH_LINES));
    assert_eq!(Keep::for_age(30 * DAY_MS), Keep::RecordOnly);
    let files = [
        parked(1, 0, None, MIB),
        parked(2, 3, None, MIB),
        parked(3, 10, None, MIB),
        parked(4, 40, None, MIB),
        // Trimmed to 500 lines already at 3 days: no rewrite until it reaches the next tier.
        parked(5, 5, Some(WEEK_LINES), MIB),
    ];
    assert_eq!(
        plan(&files, NOW, u64::MAX, false),
        [
            (id(4), Keep::RecordOnly),
            (id(3), Keep::Lines(MONTH_LINES)),
            (id(2), Keep::Lines(WEEK_LINES))
        ],
        "the oldest first; a fresh one and one already in its tier stay"
    );
}

#[test]
fn a_trim_never_raises_what_a_file_keeps() {
    // A file trimmed to 100 lines by the budget stays at 100 even while its age allows 500.
    assert!(plan(&[parked(1, 2, Some(MONTH_LINES), MIB)], NOW, u64::MAX, false).is_empty());
}

#[test]
fn over_the_budget_the_oldest_step_down_first() {
    let files = [
        parked(1, 0, None, 100 * MIB),
        parked(2, 0, None, 100 * MIB),
        parked(3, 0, None, 100 * MIB),
    ];
    // 300 MiB over a 256 MiB budget: the oldest (by written_at, then order) steps to 500 lines (counted as half).
    let mut older = files;
    older[2].written_at_ms -= 1;
    assert_eq!(plan(&older, NOW, 256 * MIB, false), [(id(3), Keep::Lines(WEEK_LINES))]);
    // A tight budget: every file steps down, then the oldest go.
    let tight = plan(&older, NOW, 10 * MIB, false);
    assert!(tight.iter().any(|(_, keep)| *keep == Keep::RecordOnly), "{tight:?}");
    assert!(tight.iter().all(|(_, keep)| *keep < Keep::All));
    assert_eq!(tight.len(), 3);
}

#[test]
fn a_low_disk_removes_and_never_rewrites() {
    let files = [parked(1, 3, None, MIB), parked(2, 0, None, MIB), parked(3, 40, None, MIB)];
    assert_eq!(
        plan(&files, NOW, u64::MAX, true),
        [(id(3), Keep::RecordOnly), (id(1), Keep::RecordOnly)],
        "a file due to trim goes instead; a fresh one stays as it is"
    );
    assert!(disk_low(4 * 1024 * MIB, 1_000_000 * MIB, 5 * 1024 * MIB), "under 5 GiB");
    assert!(disk_low(40 * 1024 * MIB, 1_000_000 * MIB, 5 * 1024 * MIB), "under 5% of a 1 TB disk");
    assert!(!disk_low(100 * 1024 * MIB, 1_000_000 * MIB, 5 * 1024 * MIB));
}

fn replay_with_lines(count: usize) -> Vec<u8> {
    let mut source =
        ghostty_vt::Terminal::new(40, 5, 64 * 1024 * 1024, Default::default()).unwrap();
    for line in 0..count {
        source.vt_write(format!("\x1b[1mline {line}\x1b[0m\r\n").as_bytes());
    }
    source.vt_replay_bounded(16 * 1024 * 1024).unwrap().into_self_contained_bytes()
}

fn rows_of(replay: &[u8]) -> (usize, String) {
    let mut terminal =
        ghostty_vt::Terminal::new(40, 5, 64 * 1024 * 1024, Default::default()).unwrap();
    terminal.vt_write(replay);
    (terminal.scrollback_rows(), terminal.plain_text().unwrap())
}

#[test]
fn a_trimmed_replay_keeps_the_newest_lines_and_the_screen() {
    let replay = replay_with_lines(2_000);
    let trimmed = trimmed_replay(&replay, 40, 5, 100).unwrap();
    let (history, text) = rows_of(&trimmed);
    assert!((90..=100).contains(&history), "kept {history} history rows");
    assert!(text.contains("line 1999"), "the newest line stays");
    assert!(!text.contains("line 1000\n"), "old lines go");
    assert!(trimmed.len() < replay.len() / 2);
    // Fewer lines than the tier: the replay is kept as it is.
    let short = replay_with_lines(20);
    assert_eq!(trimmed_replay(&short, 40, 5, 100).unwrap(), short);
}

fn directory(name: &str) -> std::path::PathBuf {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let directory = std::env::temp_dir()
        .join(format!("cmux-parked-trim-{name}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&directory).unwrap();
    directory
}

/// The snapshot file of terminal `n`: its stream ends at offset `n`.
fn write_snapshot(directory: &Path, n: u8, days_ago: u64, replay: &[u8]) {
    let header = serde_json::json!({
        "generation": "g", "stream_end": n, "cols": 40, "rows": 5, "written_at_ms": NOW - days_ago * DAY_MS,
    });
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(replay).unwrap();
    let mut file = fs::File::create(super::super::snapshot::path(directory, &id(n))).unwrap();
    file.write_all(super::super::snapshot::MAGIC).unwrap();
    serde_json::to_writer(&mut file, &header).unwrap();
    file.write_all(b"\n").unwrap();
    file.write_all(&encoder.finish().unwrap()).unwrap();
}

/// The pass as the writer runs it, with a disk that is not low: over a scan of the snapshots of `parked`.
fn pass_over(directory: &Path, parked: &HashSet<TerminalPublicId>) -> Pass {
    let (_, snapshots) =
        super::super::snapshot::scan(directory, |terminal| parked.contains(terminal));
    run_with(directory, &snapshots, parked, NOW, u64::MAX, false)
}

#[test]
fn the_pass_trims_parked_files_and_leaves_running_ones() {
    let directory = directory("run");
    let replay = replay_with_lines(2_000);
    write_snapshot(&directory, 1, 3, &replay);
    write_snapshot(&directory, 2, 3, &replay);
    write_snapshot(&directory, 3, 40, &replay);
    let parked: HashSet<_> = [id(1), id(3)].into();
    pass_over(&directory, &parked);
    let (trimmed, _, _) = super::super::snapshot::read(&directory, &id(1)).unwrap();
    assert!(rows_of(&trimmed.bytes).0 <= WEEK_LINES);
    let header =
        super::super::snapshot::read_header(&super::super::snapshot::path(&directory, &id(1)))
            .unwrap();
    assert_eq!(header["kept_lines"], WEEK_LINES);
    assert_eq!(header["written_at_ms"], NOW - 3 * DAY_MS, "a trim keeps the age");
    let (untouched, _, _) = super::super::snapshot::read(&directory, &id(2)).unwrap();
    assert_eq!(
        untouched.bytes, replay,
        "a running (or not yet placed) terminal's snapshot is never trimmed"
    );
    assert!(
        !super::super::snapshot::path(&directory, &id(3)).exists(),
        "past 30 days the record alone stays"
    );
    // A second pass in the same tier rewrites nothing.
    let before =
        fs::metadata(super::super::snapshot::path(&directory, &id(1))).unwrap().modified().unwrap();
    pass_over(&directory, &parked);
    let after =
        fs::metadata(super::super::snapshot::path(&directory, &id(1))).unwrap().modified().unwrap();
    assert_eq!(before, after);
    let _ = fs::remove_dir_all(&directory);
}

/// What `pass` read from the store's directory on this thread: (lists of the directory, reads of a snapshot
/// header).
fn disk_reads_of<T>(pass: impl FnOnce() -> T) -> ((usize, usize), T) {
    use super::super::snapshot::DISK_READS;
    let before = DISK_READS.with(std::cell::Cell::get);
    let out = pass();
    let after = DISK_READS.with(std::cell::Cell::get);
    ((after.0 - before.0, after.1 - before.1), out)
}

/// The stream end that [`write_snapshot`] gave terminal `n`.
fn end_of(n: u8) -> (TerminalPublicId, (String, u64)) {
    (id(n), ("g".to_owned(), u64::from(n)))
}

/// The start of the store reads the snapshot files for 2 things: the parked trim (the age and the size of each
/// parked snapshot) and where each terminal's stream ends. One list of the directory and one read of each header
/// give both, at any number of parked terminals. Counts only: no time is compared.
#[test]
fn the_start_reads_each_snapshot_header_one_time() {
    let replay = replay_with_lines(20);
    for (parked, running) in [(8_u8, 3_u8), (32, 5)] {
        let directory = directory(&format!("start-reads-{parked}"));
        for n in 0..parked + running {
            write_snapshot(&directory, n, 0, &replay);
        }
        let parked_ids: HashSet<_> = (0..parked).map(id).collect();
        let ((lists, headers), reads) = disk_reads_of(|| {
            super::super::start::trim_parked_and_read_ends(
                &directory,
                &parked_ids,
                NOW,
                u64::MAX,
                false,
            )
        });
        assert_eq!(reads.trim.rewrites, 0, "a fresh snapshot is not trimmed");
        assert_eq!(
            reads.stream_ends,
            (0..parked + running).map(end_of).collect::<std::collections::HashMap<_, _>>(),
            "each snapshot gives its stream end"
        );
        assert_eq!(
            (lists, headers),
            (1, usize::from(parked + running)),
            "(lists of the directory, header reads) for {parked} parked and {running} other snapshots: one list, \
             and each header one time"
        );
        let _ = fs::remove_dir_all(&directory);
    }
}

/// The start's reads say how many entries the store's directory has (the scan's one list gives them: each file and
/// folder, of each kind) and how many terminals are parked: the start log gets the 2 numbers, so a slow start says
/// how much it had to go over. Counts only: no time is compared.
#[test]
fn the_start_counts_the_directory_entries_and_the_parked_terminals() {
    let directory = directory("start-counts");
    let replay = replay_with_lines(20);
    for n in 0..5 {
        write_snapshot(&directory, n, 0, &replay);
    }
    // 2 entries that are no snapshot file: the list gives them and the scan reads no header of them.
    fs::write(directory.join("other.tail"), b"x").unwrap();
    fs::create_dir(directory.join("folder")).unwrap();
    // A parked terminal with no snapshot file is counted too: the count is of the terminals.
    let parked: HashSet<_> = [id(0), id(1), id(9)].into();
    let ((lists, headers), reads) = disk_reads_of(|| {
        super::super::start::trim_parked_and_read_ends(&directory, &parked, NOW, u64::MAX, false)
    });
    assert_eq!((lists, headers), (1, 5), "the count of the entries is of the scan's one list");
    assert_eq!(
        (reads.scan.entries, reads.scan.headers, reads.parked),
        (7, 5, 3),
        "(entries of the directory, headers read, parked terminals)"
    );
    let _ = fs::remove_dir_all(&directory);
}

/// The trim runs before the stream ends are known. A snapshot that the pass removes gives no stream end (the
/// stream of its terminal starts again), a trimmed one keeps its end, and one that is not parked is not touched.
#[test]
fn a_removed_snapshot_gives_no_stream_end_and_a_trimmed_one_keeps_its_end() {
    let directory = directory("ends");
    let replay = replay_with_lines(2_000);
    // Parked, past 30 days: the file goes.
    write_snapshot(&directory, 1, 40, &replay);
    // Parked, 3 days: trimmed.
    write_snapshot(&directory, 2, 3, &replay);
    // Not parked: it stays as it is, whatever its age.
    write_snapshot(&directory, 3, 40, &replay);
    // Parked and fresh: it stays whole.
    write_snapshot(&directory, 4, 0, &replay);
    let parked: HashSet<_> = [id(1), id(2), id(4)].into();
    let reads =
        super::super::start::trim_parked_and_read_ends(&directory, &parked, NOW, u64::MAX, false);
    assert_eq!(reads.trim.rewrites, 1, "the pass rewrites the 3-day snapshot");
    assert!(
        !super::super::snapshot::path(&directory, &id(1)).exists(),
        "past 30 days the file goes"
    );
    let header =
        super::super::snapshot::read_header(&super::super::snapshot::path(&directory, &id(2)))
            .unwrap();
    assert_eq!(header["kept_lines"], WEEK_LINES, "the 3-day snapshot is trimmed");
    // The scanned header gives the end of the trimmed file: the new file must record the same stream.
    assert_eq!(header["stream_end"], 2, "the trimmed file keeps its stream end");
    assert_eq!(header["generation"], "g", "the trimmed file keeps its generation");
    assert_eq!(
        reads.stream_ends,
        std::collections::HashMap::from([2, 3, 4].map(end_of)),
        "the removed snapshot has no stream end; each other one has its own"
    );
    let _ = fs::remove_dir_all(&directory);
}

/// With no parked terminal (also when the read of the parked terminals failed, `Mux::parked_terminal_ids`), the
/// pass changes no snapshot, whatever its age, the budget and the free disk, and each snapshot gives its stream
/// end.
#[test]
fn with_no_parked_terminal_the_pass_changes_no_snapshot() {
    let directory = directory("none-parked");
    let replay = replay_with_lines(2_000);
    // Past 30 days: a parked one would go.
    write_snapshot(&directory, 1, 40, &replay);
    // 3 days: a parked one would be trimmed.
    write_snapshot(&directory, 2, 3, &replay);
    let files = || [1, 2].map(|n| fs::read(super::super::snapshot::path(&directory, &id(n))).ok());
    let before = files();
    assert!(before.iter().all(Option::is_some), "setup: the 2 snapshot files are on disk");
    // No budget and a low disk: the pass that removes the most.
    let reads =
        super::super::start::trim_parked_and_read_ends(&directory, &HashSet::new(), NOW, 0, true);
    assert_eq!(reads.trim.rewrites, 0, "no rewrite");
    assert!(files() == before, "a snapshot file changed or went with no parked terminal");
    assert_eq!(
        reads.stream_ends,
        std::collections::HashMap::from([1, 2].map(end_of)),
        "each snapshot has its stream end"
    );
    let _ = fs::remove_dir_all(&directory);
}
