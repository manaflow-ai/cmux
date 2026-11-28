use super::*;

fn args(list: &[&str]) -> Result<Args, String> {
    parse_args(list.iter().map(|s| (*s).to_owned()))
}

const MIB: u64 = 1024 * 1024;

#[test]
fn default_caps_are_160_mib_and_5_s() {
    let a = args(&[]).unwrap();
    assert_eq!(a.caps.max_bytes, 160 * MIB);
    assert_eq!(a.caps.max_wall, Duration::from_secs(5));
    assert!(!a.dry_run);
    assert_eq!(a.bundle, None);
}

#[test]
fn arguments_parse_and_caps_clamp_to_their_ceilings() {
    let a = args(&[
        "--dry-run",
        "--bundle",
        "/Applications/cmux NEXT.app",
        "--max-bytes",
        "1000",
        "--max-ms",
        "250",
    ])
    .unwrap();
    assert!(a.dry_run);
    assert_eq!(a.bundle.as_deref(), Some(Path::new("/Applications/cmux NEXT.app")));
    assert_eq!(a.caps, Caps { max_bytes: 1000, max_wall: Duration::from_millis(250) });
    let big = args(&["--max-bytes", "99999999999999", "--max-ms", "99999999"]).unwrap();
    assert_eq!(big.caps.max_bytes, MAX_BYTES_CEILING);
    assert_eq!(big.caps.max_wall, MAX_WALL_CEILING);
}

#[test]
fn bad_arguments_are_errors() {
    assert!(args(&["--max-bytes"]).is_err());
    assert!(args(&["--max-bytes", "-1"]).is_err());
    assert!(args(&["--max-ms", "1.5"]).is_err());
    assert!(args(&["--bundle"]).is_err());
    assert!(args(&["--fast"]).is_err());
}

#[test]
fn bundle_is_the_app_that_holds_the_reader() {
    let exe = Path::new("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-launch-preread");
    assert_eq!(bundle_of(exe).as_deref(), Some(Path::new("/Applications/cmux NEXT.app")));
    // The innermost app wins (a helper app inside the bundle would be its own).
    let nested = Path::new("/A.app/Contents/Helpers/B.app/Contents/MacOS/x");
    assert_eq!(bundle_of(nested).as_deref(), Some(Path::new("/A.app/Contents/Helpers/B.app")));
    // Outside a bundle, or an .app with no Contents above the reader: none.
    assert_eq!(bundle_of(Path::new("/usr/local/bin/cmux-launch-preread")), None);
    assert_eq!(bundle_of(Path::new("/tmp/x.app/bin/cmux-launch-preread")), None);
    assert_eq!(bundle_of(Path::new("/tmp/.app/Contents/x")), None);
}

#[test]
fn plan_reads_executables_in_name_order_then_the_frameworks() {
    let p = plan(&[
        "cmux".into(),
        "cmux-stub".into(),
        "Cmux".into(),
        String::new(),
        "a/b".into(),
        "cmux".into(),
    ]);
    assert_eq!(
        p,
        vec![
            "Contents/MacOS/Cmux".to_owned(),
            "Contents/MacOS/cmux".to_owned(),
            "Contents/MacOS/cmux-stub".to_owned(),
            FRAMEWORK_FILES[0].to_owned(),
            FRAMEWORK_FILES[1].to_owned(),
        ]
    );
    assert_eq!(plan(&[]), FRAMEWORK_FILES.iter().map(|f| (*f).to_owned()).collect::<Vec<_>>());
}

#[test]
fn budget_never_reads_past_the_byte_cap() {
    let mut b = Budget::new(Caps { max_bytes: 2 * MIB + 10, max_wall: Duration::from_secs(5) });
    let t = Duration::ZERO;
    assert_eq!(b.next_len(t, BUFFER_BYTES), Ok(BUFFER_BYTES));
    b.add(BUFFER_BYTES);
    b.add(BUFFER_BYTES);
    assert_eq!(b.next_len(t, BUFFER_BYTES), Ok(10));
    b.add(10);
    assert_eq!(b.next_len(t, BUFFER_BYTES), Err(Stop::ByteCap));
    assert_eq!(b.total(), 2 * MIB + 10);
    assert_eq!(
        Budget::new(Caps { max_bytes: 0, ..Caps::default() }).next_len(t, BUFFER_BYTES),
        Err(Stop::ByteCap)
    );
}

#[test]
fn budget_stops_at_the_wall_time_cap_first() {
    let b = Budget::new(Caps { max_bytes: 0, max_wall: Duration::from_secs(5) });
    assert_eq!(
        b.next_len(Duration::from_secs(5), BUFFER_BYTES),
        Err(Stop::TimeCap),
        "time wins a tie"
    );
    let b = Budget::new(Caps::default());
    assert_eq!(b.next_len(Duration::from_millis(4999), BUFFER_BYTES), Ok(BUFFER_BYTES));
    assert_eq!(b.next_len(Duration::from_secs(6), BUFFER_BYTES), Err(Stop::TimeCap));
}

#[test]
fn dry_plan_skips_missing_files_and_names_the_byte_cap() {
    let files = vec![
        ("Contents/MacOS/cmux".to_owned(), Some(30 * MIB)),
        (FRAMEWORK_FILES[0].to_owned(), None),
        (FRAMEWORK_FILES[1].to_owned(), Some(200 * MIB)),
    ];
    let (reports, stop) = dry_plan(&files, Caps::default());
    assert_eq!(stop, Stop::ByteCap);
    assert_eq!(
        reports.iter().map(|r| (r.bytes, r.status)).collect::<Vec<_>>(),
        vec![
            (30 * MIB, FileStatus::Planned),
            (0, FileStatus::Missing),
            (130 * MIB, FileStatus::Planned),
        ]
    );
    let (_, stop) = dry_plan(&files[..2], Caps::default());
    assert_eq!(stop, Stop::Done);
    let (reports, stop) = dry_plan(&files, Caps { max_bytes: 30 * MIB, ..Caps::default() });
    assert_eq!(stop, Stop::ByteCap);
    assert_eq!(reports[2].status, FileStatus::NotReached);
}

#[test]
fn report_is_one_json_line_with_escaped_paths() {
    let r = Report {
        bundle: Some("/Applications/cmux \"NEXT\".app".into()),
        caps: Caps::default(),
        files: vec![FileReport {
            file: "Contents/MacOS/cmux".into(),
            bytes: 5,
            wall_ms: 1,
            status: FileStatus::Read,
        }],
        total_bytes: 5,
        wall_ms: 2,
        stop: Stop::Done,
        error: Some("a\nb".into()),
    };
    let json = r.to_json();
    assert!(!json.contains('\n'));
    assert_eq!(
        json,
        "{\"event\":\"cmux-launch-preread\",\"bundle\":\"/Applications/cmux \\\"NEXT\\\".app\",\
             \"caps\":{\"max_bytes\":167772160,\"max_ms\":5000},\
             \"files\":[{\"file\":\"Contents/MacOS/cmux\",\"bytes\":5,\"wall_ms\":1,\"status\":\"read\"}],\
             \"total_bytes\":5,\"wall_ms\":2,\"stop\":\"done\",\"error\":\"a\\nb\"}"
    );
    let none = Report { bundle: None, files: vec![], error: None, stop: Stop::NoBundle, ..r };
    assert!(none.to_json().contains("\"bundle\":null"));
    assert!(none.to_json().ends_with("\"stop\":\"no_bundle\"}"));
}
