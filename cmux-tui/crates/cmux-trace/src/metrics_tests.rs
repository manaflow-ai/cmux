use super::*;

/// The catalog of the shared file golden: one histogram of each layout kind, with the names and layouts of
/// Swift's `HistogramID` cases (CmuxNextMetricsTests `MetricsFileGoldenTests` builds the same image).
const GOLDEN_CATALOG: &[HistogramSpec] = &[
    HistogramSpec {
        name: "daemon.request.topology",
        layout: Layout::LogLinear { maximum: 60_000_000 },
    },
    HistogramSpec {
        name: "daemon.dispatch.queue_us",
        layout: Layout::LogLinear { maximum: 60_000_000 },
    },
    HistogramSpec {
        name: "smoothness.dropped_pct.motion",
        layout: Layout::Linear { maximum: 100 },
    },
    HistogramSpec { name: "daemon.unresponsive", layout: Layout::Enumeration { values: 8 } },
];

/// (catalog position, sample) of the golden: a 0, a negative and an over-maximum sample for each kind.
const GOLDEN_SAMPLES: &[(usize, i64)] = &[
    (0, 0),
    (0, 3),
    (0, 1_500),
    (0, 70_000_000),
    (0, -5),
    (1, 250),
    (2, 0),
    (2, 42),
    (2, 150),
    (3, 2),
    (3, 9),
    (3, -1),
];

const GOLDEN: &str = include_str!("../tests/fixtures/metrics-file-golden.txt");

fn golden_header() -> Header {
    Header {
        role: Role::Daemon,
        pid: 4242,
        start_uptime_ns: 123_456_789,
        start_unix_ns: 1_790_000_000_000_000_000,
        profile: Profile {
            app_version: "1.2.3".into(),
            build_number: "45".into(),
            channel: "nightly".into(),
            os_version: "26.1.0".into(),
            hardware_class: "Mac16,10".into(),
            boot_session: std::array::from_fn(|index| index as u8),
            build_uuid: std::array::from_fn(|index| 16 + index as u8),
            build_day: 20261026,
        },
    }
}

fn golden_store() -> MetricsStore {
    let store = MetricsStore::new(GOLDEN_CATALOG, golden_header());
    for &(index, sample) in GOLDEN_SAMPLES {
        store.record(index, sample);
    }
    store
}

/// `bytes N`, then `<offset> <hex>` for each 16-byte row that is not all zero.
fn golden_text(bytes: &[u8]) -> String {
    let mut text = String::from(
        "# A metrics file (cmux-trace metrics.rs, CmuxNextMetrics MetricsStore): the daemon role, a fixed\n\
         # header and profile, the four histograms and twelve samples of metrics_tests.rs GOLDEN_CATALOG and\n\
         # GOLDEN_SAMPLES. Rows: byte offset, then 16 bytes in hex; rows of zeros are left out.\n",
    );
    text.push_str(&format!("bytes {}\n", bytes.len()));
    for (row, chunk) in bytes.chunks(16).enumerate() {
        if chunk.iter().any(|&byte| byte != 0) {
            let hex: String = chunk.iter().map(|byte| format!("{byte:02x}")).collect();
            text.push_str(&format!("{} {hex}\n", row * 16));
        }
    }
    text
}

fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-metrics-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn metrics_file_bytes_match_the_golden_shared_with_swift() {
    let text = golden_text(&golden_store().snapshot_bytes());
    if std::env::var_os("CMUX_UPDATE_METRICS_GOLDEN").is_some() {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/metrics-file-golden.txt");
        std::fs::write(path, &text).expect("writes the golden");
        return;
    }
    assert_eq!(
        text, GOLDEN,
        "the metrics file layout changed; Swift's MetricsStore must change with it"
    );
}

#[test]
fn metrics_header_fields_sit_at_their_offsets() {
    let bytes = golden_store().snapshot_bytes();
    assert_eq!(&bytes[..8], b"CMXMETRC");
    assert_eq!(read_u32(&bytes, 8), 1);
    assert_eq!(read_u32(&bytes, 12), 1024);
    assert_eq!(read_u32(&bytes, 16), 4);
    assert_eq!(read_u16(&bytes, 20), Role::Daemon as u16);
    assert_eq!(read_u16(&bytes, 22), 2);
    assert_eq!(read_u32(&bytes, 24), 4242);
    assert_eq!(read_u32(&bytes, 28), 88);
    assert_eq!(read_u64(&bytes, 48), bytes.len() as u64);
    assert_eq!(bytes.len() % 4096, 0);
    assert_eq!(read_u64(&bytes, 56) % 64, 0);
    assert_eq!(read_u32(&bytes, 96), 20261026);
    assert_eq!(&bytes[104..109], b"1.2.3");
    assert_eq!(&bytes[360..368], b"Mac16,10");
    let (header, entries) = validate(&bytes).expect("a valid image");
    assert_eq!(header, golden_header());
    let names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(names, GOLDEN_CATALOG.iter().map(|spec| spec.name).collect::<Vec<_>>());
}

#[test]
fn metrics_log_linear_buckets_match_the_shared_golden() {
    let golden = include_str!("../tests/fixtures/metrics-log-linear-golden.txt");
    let mut checked = 0;
    for line in golden.lines().filter(|line| !line.starts_with('#') && !line.is_empty()) {
        let fields: Vec<u64> =
            line.split(' ').map(|field| field.parse().expect("a number")).collect();
        let [value, index, upper] = fields[..] else { panic!("golden line {line:?}") };
        assert_eq!(log_linear_index(value), index as usize, "value {value}");
        assert_eq!(log_linear_upper_bound(index as usize), upper, "index {index}");
        checked += 1;
    }
    assert_eq!(checked, 1000);
}

#[test]
fn metrics_layouts_place_samples_like_swift() {
    let log = Layout::LogLinear { maximum: 60_000_000 };
    assert_eq!(log.bucket_count(), 105);
    assert_eq!(log.bucket_index(-5), 0);
    assert_eq!(log.bucket_index(4), 8);
    assert_eq!(log.bucket_index(60_000_001), 104);
    assert_eq!(log.bucket_upper_bound(103), Some(60_000_000));
    assert_eq!(log.bucket_upper_bound(104), None);
    let linear = Layout::Linear { maximum: 100 };
    assert_eq!(
        (linear.bucket_count(), linear.bucket_index(100), linear.bucket_index(101)),
        (102, 100, 101)
    );
    let enumeration = Layout::Enumeration { values: 8 };
    assert_eq!(enumeration.bucket_count(), 9);
    assert_eq!((enumeration.bucket_index(7), enumeration.bucket_index(8)), (7, 8));
    assert_eq!(enumeration.bucket_index(-1), 8);
}

#[test]
fn metrics_store_reads_what_it_recorded() {
    let store = golden_store();
    let topology = store.read(0).expect("in the catalog");
    assert_eq!((topology.count, topology.sum), (5, 3 + 1_500 + 70_000_000));
    assert_eq!(topology.buckets[0], 2, "0 and -5");
    assert_eq!(topology.buckets[104], 1, "the overflow bucket");
    assert_eq!(store.read(4), None);
    store.record(99, 1);
    assert_eq!(store.index_of("daemon.unresponsive"), Some(3));
    assert_eq!(store.layout(2), Some(Layout::Linear { maximum: 100 }));
}

#[cfg(unix)]
#[test]
fn metrics_adoption_moves_the_heap_counts_into_the_file() {
    let dir = scratch_dir("adopt");
    let store = Arc::new(golden_store());
    let before = store.snapshot_bytes();
    let path = store.open_in_background(dir.clone()).wait().expect("adopts");
    assert_eq!(path, dir.join("metrics-daemon-4242.bin"));
    assert!(store.is_file_backed());
    assert_eq!(store.file_path(), Some(path.as_path()));
    assert_eq!(std::fs::read(&path).expect("reads"), before, "the file holds the heap's counters");
    store.record(1, 250);
    assert_eq!(store.read(1).expect("in the catalog").count, 2);
    let on_disk = std::fs::read(&path).expect("reads");
    assert_eq!(on_disk, store.snapshot_bytes(), "a record after adoption goes into the file");
    let again = store.adopt_file(&dir).expect_err("one-shot");
    assert_eq!(again.kind(), io::ErrorKind::AlreadyExists);
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn metrics_a_failed_adoption_keeps_the_counters_on_the_heap() {
    let dir = scratch_dir("blocked");
    std::fs::write(&dir, b"a file where the directory should be").expect("writes");
    let store = golden_store();
    assert!(store.adopt_file(&dir).is_err());
    assert!(!store.is_file_backed());
    store.record(1, 7);
    assert_eq!(store.read(1).expect("in the catalog").count, 2);
    let _ = std::fs::remove_file(&dir);
}

#[cfg(unix)]
#[test]
fn metrics_a_file_folds_each_sample_once() {
    let dir = scratch_dir("fold");
    let store = golden_store();
    let path = store.adopt_file(&dir).expect("adopts");
    let file = MetricsFile::open(&path).expect("maps");
    assert_eq!(file.header(), &golden_header());
    assert_eq!(file.names().count(), 4);
    let first = file.fold();
    let topology = first.histogram("daemon.request.topology").expect("has samples");
    assert_eq!((topology.count, topology.sum), (5, 70_001_503));
    assert_eq!(topology.buckets, vec![(0, 2), (3, 1), (log_linear_index(1_500), 1), (104, 1)]);
    assert_eq!(
        first.histogram("daemon.unresponsive").expect("has samples").buckets,
        vec![(2, 1), (8, 2)]
    );
    assert!(file.fold().is_empty(), "a second fold reads nothing");
    store.record(1, 3);
    let second = MetricsFile::open(&path).expect("maps again").fold();
    assert_eq!(second.histograms.len(), 1, "only the new sample: the shadow is in the file");
    assert_eq!(second.histograms[0].buckets, vec![(3, 1)]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn metrics_a_delta_of_another_file_marks_nothing() {
    let dir = scratch_dir("other");
    let store = golden_store();
    let path = store.adopt_file(&dir).expect("adopts");
    let file = MetricsFile::open(&path).expect("maps");
    let mut foreign = file.delta();
    for histogram in &mut foreign.histograms {
        histogram.name.push_str(".other");
    }
    file.mark_logged(&foreign);
    assert_eq!(file.delta().histograms.len(), 4);
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn metrics_a_torn_or_foreign_file_is_refused() {
    let dir = scratch_dir("torn");
    std::fs::create_dir_all(&dir).expect("creates");
    let bytes = golden_store().snapshot_bytes();
    let cases: [(&str, Vec<u8>); 4] = [
        ("short", bytes[..512].to_vec()),
        ("zero", vec![0; bytes.len()]),
        ("cut", bytes[..bytes.len() - 4096].to_vec()),
        ("magic", [b"NOTMETRC".as_slice(), &bytes[8..]].concat()),
    ];
    for (name, contents) in cases {
        let path = dir.join(name);
        std::fs::write(&path, contents).expect("writes");
        assert!(
            matches!(MetricsFile::open(&path), Err(MetricsFileError::Invalid)),
            "{name} was accepted"
        );
    }
    assert!(matches!(MetricsFile::open(&dir.join("missing")), Err(MetricsFileError::Io(_))));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn metrics_file_names_follow_the_ring_stems() {
    assert_eq!(file_name(Role::Daemon, 7), "metrics-daemon-7.bin");
    assert_eq!(file_name(Role::Acpmux, 9), "metrics-acpmux-9.bin");
}

#[test]
fn metrics_a_long_profile_text_is_cut_on_a_character_boundary() {
    let mut header = golden_header();
    header.profile.channel = "é".repeat(40);
    let store = MetricsStore::new(GOLDEN_CATALOG, header);
    let (read, _) = validate(&store.snapshot_bytes()).expect("a valid image");
    assert_eq!(read.profile.channel, "é".repeat(31));
}

#[test]
fn metrics_add_merges_counts_kept_elsewhere() {
    let store = MetricsStore::new(GOLDEN_CATALOG, golden_header());
    store.add(0, 1_500, 3, 4_600);
    store.add(0, 80_000_000, 1, 80_000_000);
    store.add(9, 1, 1, 1);
    let topology = store.read(0).expect("in the catalog");
    assert_eq!((topology.count, topology.sum), (4, 80_004_600));
    assert_eq!(topology.buckets[log_linear_index(1_500)], 3);
    assert_eq!(topology.buckets[104], 1);
}
