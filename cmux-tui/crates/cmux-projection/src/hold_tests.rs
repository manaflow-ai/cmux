use super::*;

struct Table(HashMap<PathBuf, u64>);

impl Probe for Table {
    fn size(&self, path: &Path) -> Option<u64> {
        self.0.get(path).copied()
    }

    fn exists(&self, path: &Path) -> bool {
        self.0.contains_key(path)
    }
}

const DAY: Duration = Duration::from_secs(24 * 60 * 60);

#[test]
fn every_source_lands_with_its_reason_most_likely_first() {
    let now = SystemTime::now();
    let home = PathBuf::from("/home/me");
    let probe = Table(
        [
            ("/w/app", 500),
            ("/w/app/Cargo.toml", 1),
            ("/w/app/sub", 10),
            ("/w/old", 300),
            ("/w/web", 200),
            ("/w/web/package.json", 1),
            ("/home/me/.cargo/registry", 9000),
            ("/home/me/.npm/_cacache", 4000),
        ]
        .into_iter()
        .map(|(path, size)| (PathBuf::from(path), size))
        .collect(),
    );
    let inputs = Inputs {
        selected: vec!["/w/app".into()],
        recent: vec![
            Recent { path: "/w/web".into(), at: now - DAY, repo: true },
            Recent { path: "/w/old".into(), at: now - 9 * DAY, repo: false },
            Recent { path: "/w/app/sub".into(), at: now, repo: false },
        ],
        grant: vec![
            GrantRepo {
                name: "o/fresh".into(),
                pushed_at: now - 2 * DAY,
                size: 70,
                root_files: vec!["go.mod".into()],
            },
            GrantRepo {
                name: "o/stale".into(),
                pushed_at: now - 40 * DAY,
                size: 1,
                root_files: vec![],
            },
        ],
        home,
    };
    let rows = candidates(&inputs, now, &Tuning::default(), &probe);
    let got: Vec<(&str, Reason)> = rows.iter().map(|row| (row.path.as_str(), row.reason)).collect();
    assert_eq!(
        got,
        [
            ("/w/app", Reason::Selected),
            ("/home/me/.cargo/registry", Reason::Toolchain),
            ("/w/web", Reason::RecentRepo),
            ("/home/me/.npm/_cacache", Reason::Toolchain),
            ("github.com/o/fresh", Reason::GrantRepo),
            ("/w/old", Reason::RecentFolder),
        ]
    );
    assert!((rows[0].likelihood - 1.0).abs() < f32::EPSILON);
    assert_eq!(rows[0].size, 500);
    // Half-life three days: a day-old repo at 0.9 * 2^(-1/3).
    assert!((rows[2].likelihood - 0.714).abs() < 0.01, "{}", rows[2].likelihood);
    assert!(rows.windows(2).all(|w| w[0].likelihood >= w[1].likelihood));
}

#[test]
fn logical_bytes_count_a_shared_blob_once() {
    let dir = tempfile::tempdir().unwrap();
    let hash = "ab".repeat(32);
    let other = "cd".repeat(32);
    for (name, files) in [("p1", vec![&hash, &other]), ("p2", vec![&hash])] {
        let blobs = dir.path().join(name).join("content/blobs");
        fs::create_dir_all(&blobs).unwrap();
        for file in files {
            fs::write(blobs.join(file), [0u8; 100]).unwrap();
        }
    }
    let cold = dir.path().join("p2/content/cold");
    fs::create_dir_all(&cold).unwrap();
    fs::write(cold.join(format!("{}-5000.zst", "ef".repeat(32))), [0u8; 40]).unwrap();
    let held = held(dir.path());
    assert_eq!(held.logical_bytes, 100 + 100 + 5000);
    assert_eq!(held.duplicate_bytes, 100);
    assert_eq!(held.stored_bytes, 300 + 40);
    assert_eq!((held.blobs, held.cold_blobs, held.projections), (4, 1, 2));
}
