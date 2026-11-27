//! Ported from Packages/macOS/CmuxNext/Tests/CmuxNextHangReportsTests: realistic MetricKit
//! payloads and watchdog samples with planted private data, the wire golden, the leak scanner,
//! image ownership, the collector's rules and the service's limits.

use serde_json::{Value, json};

use crate::aggregate::{StallAggregate, note_hang, note_stall};
use crate::build::{
    Address, Builder, Context, MetricKitCpuException, MetricKitHang, MetricKitInput,
    SIGNPOST_CATEGORIES, Signpost, address_frames, hardware, intervals, signpost_allowed,
};
use crate::classify::{Classifier, LoadedImage, Owner, is_uuid};
use crate::ops;
use crate::report::{
    App, CoarseCounts, Frame, HangReport, HangSample, HardwareClass, HistogramBucket, Kind,
    Metrics, Os, Source, bucket,
};
use crate::scan::{LeakKind, Scanner};
use crate::service::{
    self, Ask, ComposeStatus, OutboxEntry, SendLog, ask, install_id_valid, outbox_plan,
    take_send_slot,
};
use crate::tree;

const APP_BUNDLE: &str = "/Applications/cmux NEXT Nightly.app";
const APP_UUID: &str = "3F0C9E43-7A61-3C8E-9C1A-2B7F5D0E9A11";
const APPKIT_UUID: &str = "8B1E5C0A-1D4F-3B2E-A6C7-9F8E7D6C5B4A";
const FOUNDATION_UUID: &str = "1A2B3C4D-5E6F-3A7B-8C9D-0E1F2A3B4C5D";
const IME_UUID: &str = "DEADBEEF-1111-3222-8333-444455556666";
const PLUGIN_UUID: &str = "CAFEBABE-AAAA-3BBB-8CCC-DDDDEEEEFFFF";
const GHOSTTY_UUID: &str = "77A62F2E-8212-30F3-84C1-E8497440ACF8";

const PLANTED: [&str; 23] = [
    "alice",
    "Alice Liddell",
    "Liddell",
    "/Users/alice",
    "~/Library",
    "SecretIME",
    "Input Methods",
    "alice@example.com",
    "https://intranet.example.com/wiki",
    "intranet.example.com",
    "192.168.1.20",
    "fe80::1c2b:3a4d",
    "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
    "AWS_SECRET_ACCESS_KEY=abc",
    "PATH=/usr/bin",
    "Alices-MacBook-Pro",
    "WorkspaceSecretProject",
    "EvilPlugin",
    "Q3 Plans.pdf",
    "en_US",
    "regionFormat",
    "Contents/MacOS",
    "threadName",
];

fn forbidden_terms() -> Vec<String> {
    ["alice", "Alice", "Liddell", "/Users/alice", "Alices-MacBook-Pro"].map(str::to_owned).to_vec()
}

fn images() -> Vec<LoadedImage> {
    vec![
        LoadedImage::new(
            &format!("{APP_BUNDLE}/Contents/MacOS/cmux NEXT Nightly"),
            APP_UUID,
            0x1_0000_0000,
            0x100_0000,
        ),
        LoadedImage::new(
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            APPKIT_UUID,
            0x1_8000_0000,
            0x200_0000,
        ),
        LoadedImage::new(
            "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
            FOUNDATION_UUID,
            0x1_9000_0000,
            0x100_0000,
        ),
        LoadedImage::new(
            "/Users/alice/Library/Input Methods/SecretIME.app/Contents/MacOS/SecretIME",
            IME_UUID,
            0x2_0000_0000,
            0x10_0000,
        ),
        LoadedImage::new(
            "/Applications/EvilPlugin.app/Contents/MacOS/EvilPlugin",
            PLUGIN_UUID,
            0x2_1000_0000,
            0x10_0000,
        ),
    ]
}

fn classifier_with(system_names: &[&str]) -> Classifier {
    Classifier::new(
        Some(APP_BUNDLE),
        &forbidden_terms(),
        system_names.iter().map(|name| (*name).to_owned()),
    )
}

fn classifier() -> Classifier {
    classifier_with(&["AppKit", "Foundation", "libsystem_kernel.dylib", "CoreFoundation"])
}

fn builder() -> Builder {
    Builder::new(classifier(), images())
}

fn context() -> Context {
    Context {
        report_id: "5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11".to_owned(),
        install_id: "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20".to_owned(),
        day: "2026-10-23".to_owned(),
        app: App {
            build: "70123".to_owned(),
            channel: "nightly".to_owned(),
            version: "0.70.0".to_owned(),
        },
        os: Os { version: "15.7.4".to_owned() },
        hardware: HardwareClass {
            arch: "arm64".to_owned(),
            chip: "Apple M4 Pro".to_owned(),
            cores: 14,
            memory_gb: 48,
        },
        counts: CoarseCounts::new(1, 24, 12, 72),
    }
}

fn hang_tree() -> String {
    format!(
        r#"{{
  "callStackPerThread" : true,
  "regionFormat" : "en_US",
  "pid" : 4242,
  "callStacks" : [
    {{
      "threadAttributed" : false,
      "callStackRootFrames" : [
        {{"binaryUUID" : "{FOUNDATION_UUID}", "offsetIntoBinaryTextSegment" : 99, "sampleCount" : 9,
         "binaryName" : "Foundation", "address" : 6710886499}}
      ]
    }},
    {{
      "threadAttributed" : true,
      "threadName" : "WorkspaceSecretProject alice@example.com",
      "callStackRootFrames" : [
        {{
          "binaryUUID" : "{IME_UUID}",
          "offsetIntoBinaryTextSegment" : 4096,
          "sampleCount" : 20,
          "binaryName" : "/Users/alice/Library/Input Methods/SecretIME.app/Contents/MacOS/SecretIME",
          "address" : 8589938688,
          "subFrames" : [
            {{
              "binaryUUID" : "{APPKIT_UUID}",
              "offsetIntoBinaryTextSegment" : 123456,
              "sampleCount" : 20,
              "binaryName" : "AppKit",
              "address" : 6442573888,
              "subFrames" : [
                {{
                  "binaryUUID" : "{APP_UUID}",
                  "offsetIntoBinaryTextSegment" : 777,
                  "sampleCount" : 18,
                  "binaryName" : "cmux NEXT Nightly",
                  "address" : 4294968073,
                  "subFrames" : [
                    {{"binaryUUID" : "{GHOSTTY_UUID}", "offsetIntoBinaryTextSegment" : 55, "sampleCount" : 18,
                     "binaryName" : "{APP_BUNDLE}/Contents/Frameworks/GhosttyKit.framework/GhosttyKit", "address" : 1}}
                  ]
                }},
                {{
                  "binaryUUID" : "{PLUGIN_UUID}",
                  "offsetIntoBinaryTextSegment" : 12,
                  "sampleCount" : 2,
                  "binaryName" : "EvilPlugin",
                  "address" : 8858370060
                }}
              ]
            }}
          ]
        }}
      ]
    }}
  ]
}}"#
    )
}

fn cpu_tree() -> String {
    format!(
        r#"{{
  "callStackPerThread" : false,
  "callStacks" : [
    {{
      "callStackRootFrames" : [
        {{"binaryUUID" : "{APPKIT_UUID}", "offsetIntoBinaryTextSegment" : 10, "sampleCount" : 3, "binaryName" : "AppKit"}},
        {{"binaryUUID" : "AAAAAAAA-BBBB-3CCC-8DDD-EEEEEEEEEEEE", "offsetIntoBinaryTextSegment" : 20, "sampleCount" : 40,
         "binaryName" : "libAliceTools.dylib",
         "subFrames" : [
           {{"binaryUUID" : "BBBBBBBB-CCCC-3DDD-8EEE-FFFFFFFFFFFF", "offsetIntoBinaryTextSegment" : 30, "sampleCount" : 40,
            "binaryName" : "libsystem_kernel.dylib"}},
           {{"binaryUUID" : "not-a-uuid PATH=/usr/bin", "offsetIntoBinaryTextSegment" : 1, "sampleCount" : 1,
            "binaryName" : "Q3 Plans.pdf"}}
         ]}}
      ]
    }}
  ]
}}"#
    )
}

fn signpost(
    category: &str,
    name: &str,
    count: i64,
    buckets: Vec<HistogramBucket>,
    hitch: Option<f64>,
) -> Signpost {
    Signpost {
        category: category.to_owned(),
        name: name.to_owned(),
        count,
        buckets,
        hitch_ms_per_s: hitch,
    }
}

fn signposts() -> Vec<Signpost> {
    vec![
        signpost(
            "motion",
            "motion.frame",
            1200,
            vec![HistogramBucket::new(0, 10, 1100), HistogramBucket::new(10, 20, 100)],
            Some(0.4),
        ),
        signpost("switch", "/Users/alice/Documents", 3, vec![], None),
        signpost("WorkspaceSecretProject", "frame", 3, vec![], None),
        signpost("stall", "stall.main", 3, vec![], None),
        signpost("key", "https://intranet.example.com/wiki", 1, vec![], None),
    ]
}

fn metric_kit_input() -> MetricKitInput {
    let metrics = Metrics {
        hang_time: vec![HistogramBucket::new(0, 100, 40), HistogramBucket::new(100, 400, 3)],
        launch_first_draw: vec![HistogramBucket::new(200, 300, 2)],
        scroll_hitch_ms_per_s: Some(1.5),
        ..Metrics::default()
    };
    MetricKitInput {
        hangs: vec![MetricKitHang { duration_ms: 2_340, call_stack_tree: hang_tree() }],
        cpu_exceptions: vec![MetricKitCpuException {
            cpu_ms: 90_000,
            sampled_ms: 180_000,
            call_stack_tree: cpu_tree(),
        }],
        metrics,
        signposts: signposts(),
    }
}

/// Watchdog return addresses, innermost first: the input method, AppKit, our binary, the plug-in, nowhere.
const WATCHDOG_ADDRESSES: [u64; 5] =
    [0x2_0000_1000, 0x1_8000_2000, 0x1_0000_0300, 0x2_1000_0040, 0x7_0000_0000];

fn watchdog_frames() -> Vec<Frame> {
    let images = images();
    let addresses: Vec<Address> = WATCHDOG_ADDRESSES
        .iter()
        .map(|address| Address {
            address: *address,
            image: images.iter().find(|image| image.contains(*address)).cloned(),
        })
        .collect();
    address_frames(&classifier(), &addresses)
}

fn frame(image: &str, uuid: &str, offset: u64) -> Frame {
    Frame { image: image.to_owned(), offset: Some(offset), uuid: Some(uuid.to_owned()) }
}

fn report() -> (HangReport, Vec<u8>) {
    let mut aggregate = StallAggregate::default();
    aggregate.count(300);
    aggregate.keep(HangSample::new(
        Source::Watchdog,
        Kind::Stall,
        300,
        Some(290),
        watchdog_frames(),
    ));
    let report = builder().build(&context(), &aggregate, &[metric_kit_input()]);
    let body = report.wire();
    (report, body)
}

fn scanner() -> Scanner {
    Scanner::new(&forbidden_terms())
}

// MARK: privacy

#[test]
fn no_planted_string_reaches_the_encoded_report() {
    let (report, body) = report();
    let text = String::from_utf8(body).unwrap().to_lowercase();
    let readable = String::from_utf8(report.readable()).unwrap().to_lowercase();
    for secret in PLANTED {
        assert!(!text.contains(&secret.to_lowercase()), "leaked: {secret}");
        assert!(
            !readable.contains(&secret.to_lowercase()),
            "leaked in the readable copy: {secret}"
        );
    }
}

#[test]
fn the_leak_scanner_finds_nothing_in_a_built_report() {
    let (report, body) = report();
    assert!(scanner().findings(&body).is_empty(), "{:?}", scanner().findings(&body));
    assert!(scanner().findings(&report.readable()).is_empty());
}

#[test]
fn third_party_frames_lose_name_uuid_and_offset() {
    let (report, _) = report();
    let frames: Vec<&Frame> = report
        .hangs
        .iter()
        .flat_map(|hang| &hang.frames)
        .chain(report.cpu_exceptions.iter().flat_map(|cpu| &cpu.frames))
        .collect();
    assert!(frames.iter().any(|frame| frame.is_other()));
    for frame in frames.iter().filter(|frame| frame.is_other()) {
        assert!(frame.uuid.is_none() && frame.offset.is_none());
    }
    let named: std::collections::BTreeSet<&str> =
        frames.iter().filter(|frame| !frame.is_other()).map(|frame| frame.image.as_str()).collect();
    assert_eq!(
        named,
        ["AppKit", "GhosttyKit", "cmux NEXT Nightly", "libsystem_kernel.dylib"]
            .into_iter()
            .collect()
    );
    assert!(
        !frames.iter().any(|frame| matches!(frame.uuid.as_deref(), Some(IME_UUID | PLUGIN_UUID)))
    );
}

#[test]
fn ours_and_apples_frames_keep_uuid_and_offset() {
    let (report, _) = report();
    let metric_kit = report.hangs.iter().find(|hang| hang.source == Source::Metrickit).unwrap();
    assert_eq!(
        metric_kit.frames,
        vec![
            Frame::other(),
            frame("AppKit", APPKIT_UUID, 123_456),
            frame("cmux NEXT Nightly", APP_UUID, 777),
            frame("GhosttyKit", GHOSTTY_UUID, 55),
        ]
    );
    let watchdog = report.hangs.iter().find(|hang| hang.source == Source::Watchdog).unwrap();
    assert_eq!(
        watchdog.frames,
        vec![
            Frame::other(),
            frame("AppKit", APPKIT_UUID, 0x2000),
            frame("cmux NEXT Nightly", APP_UUID, 0x300),
            Frame::other(),
            Frame::other(),
        ]
    );
}

#[test]
fn only_allowlisted_intervals_are_sent() {
    let (report, _) = report();
    assert_eq!(
        report.intervals.iter().map(|interval| interval.category.as_str()).collect::<Vec<_>>(),
        ["motion"]
    );
    assert_eq!(report.intervals[0].name, "motion.frame");
    assert_eq!(report.intervals[0].count, 1_200);
}

#[test]
fn a_binary_name_holding_the_users_name_is_not_sent() {
    let classifier = classifier_with(&["AliceKit"]);
    assert_eq!(
        classifier.frame_metric_kit(Some("AliceKit"), Some(PLUGIN_UUID), Some(1), None),
        Frame::other()
    );
    let ours =
        classifier.frame_metric_kit(Some("cmux NEXT Nightly"), Some(APP_UUID), Some(1), None);
    assert_eq!(ours.image, "cmux NEXT Nightly");
}

#[test]
fn a_frame_without_a_valid_uuid_is_other() {
    let classifier = classifier();
    assert_eq!(
        classifier.frame_metric_kit(Some("AppKit"), Some("PATH=/usr/bin"), Some(1), None),
        Frame::other()
    );
    assert_eq!(classifier.frame_metric_kit(Some("AppKit"), None, Some(1), None), Frame::other());
    assert_eq!(
        classifier.frame_metric_kit(Some("AppKit"), Some(APPKIT_UUID), None, None),
        Frame::other()
    );
}

#[test]
fn unsafe_envelope_values_are_replaced() {
    let mut context = context();
    context.app = App {
        build: "/Users/alice".to_owned(),
        channel: "WorkspaceSecretProject".to_owned(),
        version: "0.70.0 (alice@example.com)".to_owned(),
    };
    context.os = Os { version: "Version 15.7.4 (Build 24G517) alice".to_owned() };
    context.day = "2026-10-23T10:11:12Z".to_owned();
    let report = builder().build(&context, &StallAggregate::default(), &[]);
    assert_eq!(
        report.app,
        App { build: "0".to_owned(), channel: "dev".to_owned(), version: "0".to_owned() }
    );
    assert_eq!(report.os.version, "0");
    assert_eq!(report.day, "1970-01-01");
    assert!(scanner().findings(&report.wire()).is_empty());
}

#[test]
fn a_nightly_run_id_build_number_is_kept() {
    let mut context = context();
    context.app = App {
        build: "2123456789012".to_owned(),
        channel: "nightly".to_owned(),
        version: "0.70.0".to_owned(),
    };
    let report = builder().build(&context, &StallAggregate::default(), &[]);
    assert_eq!(report.app.build, "2123456789012");
    assert!(scanner().findings(&report.wire()).is_empty());
}

#[test]
fn hardware_class_keeps_only_coarse_values() {
    let class = |arch: &str, chip: &str, cores, memory_gb| HardwareClass {
        arch: arch.to_owned(),
        chip: chip.to_owned(),
        cores,
        memory_gb,
    };
    assert_eq!(
        hardware(Some("arm64e"), Some("Apple M4 Pro"), 14, 48 << 30),
        class("arm64", "Apple M4 Pro", 14, 48)
    );
    assert_eq!(hardware(Some("arm64"), Some("Alice's Hackintosh 3000"), 8, 17 << 30).chip, "other");
    assert_eq!(
        hardware(Some("x86_64"), Some("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"), 16, 31 << 30),
        class("x86_64", "Intel", 16, 32)
    );
    assert_eq!(hardware(None, None, 0, 0), class("other", "other", 1, 4));
    assert_eq!(
        hardware(Some(" arm64 "), Some("Apple M10 Ultra"), 5_000, 1 << 40).chip,
        "Apple M10 Ultra"
    );
}

// MARK: wire format

const GOLDEN: &str = r#"{"app":{"build":"2123456789012","channel":"nightly","version":"0.70.0"},"counts":{"panes":"6-10","tabs":"31-100","windows":"1","workspaces":"11-30"},"cpuExceptions":[{"cpuMs":90000,"frames":[{"image":"other"},{"image":"libsystem_kernel.dylib","offset":30,"uuid":"BBBBBBBB-CCCC-3DDD-8EEE-FFFFFFFFFFFF"}],"sampledMs":180000}],"day":"2026-10-23","hangs":[{"durationMs":2340,"frames":[{"image":"other"},{"image":"AppKit","offset":123456,"uuid":"8B1E5C0A-1D4F-3B2E-A6C7-9F8E7D6C5B4A"},{"image":"cmux NEXT Nightly","offset":777,"uuid":"3F0C9E43-7A61-3C8E-9C1A-2B7F5D0E9A11"},{"image":"GhosttyKit","offset":55,"uuid":"77A62F2E-8212-30F3-84C1-E8497440ACF8"}],"kind":"hang","source":"metrickit"},{"cpuMs":290,"durationMs":300,"frames":[{"image":"other"},{"image":"AppKit","offset":8192,"uuid":"8B1E5C0A-1D4F-3B2E-A6C7-9F8E7D6C5B4A"}],"kind":"stall","source":"watchdog"}],"hardware":{"arch":"arm64","chip":"Apple M4 Pro","cores":14,"memoryGB":48},"installId":"0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20","intervals":[{"buckets":[{"count":1100,"highMs":10,"lowMs":0},{"count":100,"highMs":20,"lowMs":10}],"category":"motion","count":1200,"hitchMsPerS":0.4,"name":"motion.frame"}],"metrics":{"hangTime":[{"count":40,"highMs":100,"lowMs":0}],"launchExtended":[],"launchFirstDraw":[{"count":2,"highMs":300,"lowMs":200}],"launchOptimizedFirstDraw":[],"launchResume":[],"scrollHitchMsPerS":1.5},"os":{"version":"15.7.4"},"reportId":"5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11","schema":2,"stallHistogram":[{"count":1,"highMs":500,"lowMs":250}]}"#;

#[test]
fn the_golden_report_round_trips_to_the_same_bytes() {
    let report: HangReport = serde_json::from_str(GOLDEN).unwrap();
    let encoded = report.wire();
    assert_eq!(String::from_utf8(encoded.clone()).unwrap(), GOLDEN);
    assert!(scanner().findings(&encoded).is_empty());
}

#[test]
fn the_golden_matches_the_server_fixture() {
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../web/tests/fixtures/hang-report-schema2.json");
    let Ok(text) = std::fs::read_to_string(fixture) else { return };
    let ours: Value = serde_json::from_str(GOLDEN).unwrap();
    let theirs: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(ours, theirs);
}

#[test]
fn the_builder_writes_the_goldens_shape() {
    let report: HangReport = serde_json::from_str(GOLDEN).unwrap();
    assert!(
        report
            .intervals
            .iter()
            .all(|interval| signpost_allowed(&interval.category, &interval.name))
    );
    assert_eq!(
        SIGNPOST_CATEGORIES,
        ["action", "motion", "key", "switch", "create", "cef", "launch"]
    );
}

#[test]
fn a_whole_ratio_is_written_as_an_integer_and_the_readable_copy_uses_foundations_separator() {
    let mut report: HangReport = serde_json::from_str(GOLDEN).unwrap();
    report.metrics.scroll_hitch_ms_per_s = Some(2.0);
    let text = String::from_utf8(report.wire()).unwrap();
    assert!(text.contains(r#""scrollHitchMsPerS":2}"#), "{text}");
    let readable = String::from_utf8(report.readable()).unwrap();
    assert!(
        readable.starts_with("{\n  \"app\" : {\n    \"build\" : \"2123456789012\""),
        "{readable}"
    );
    let back: HangReport = serde_json::from_slice(report.readable().as_slice()).unwrap();
    assert_eq!(back, report);
}

// MARK: leak scanner

fn planted_findings(value: &str, key: &str) -> Vec<crate::scan::Finding> {
    let scanner = Scanner::new(&[forbidden_terms(), vec!["cmux".to_owned()]].concat());
    let mut report = builder().build(&context(), &StallAggregate::default(), &[]);
    let frame = Frame {
        image: if key == "image" { value.to_owned() } else { "AppKit".to_owned() },
        offset: Some(1),
        uuid: (key == "uuid").then(|| value.to_owned()),
    };
    report.hangs = vec![HangSample::new(Source::Watchdog, Kind::Stall, 300, None, vec![frame])];
    scanner.findings(&report.wire())
}

#[test]
fn refuses_each_kind_of_private_string() {
    let long = "a".repeat(200);
    let cases: [(&str, LeakKind); 12] = [
        ("/Users/alice/Library/Input Methods/X.app", LeakKind::UnsafeCharacter),
        ("~/Desktop", LeakKind::UnsafeCharacter),
        ("bob@example.com", LeakKind::UnsafeCharacter),
        ("https://intranet.example.com", LeakKind::UnsafeCharacter),
        ("10.0.0.12:22", LeakKind::UnsafeCharacter),
        ("fe80::1", LeakKind::UnsafeCharacter),
        ("HOME=x", LeakKind::UnsafeCharacter),
        ("\"quoted\"", LeakKind::UnsafeCharacter),
        ("ghpA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8", LeakKind::Token),
        ("Alice", LeakKind::PersonalTerm),
        ("Report for Alices-MacBook-Pro", LeakKind::PersonalTerm),
        (long.as_str(), LeakKind::TooLong),
    ];
    for (value, kind) in cases {
        let found = planted_findings(value, "image");
        let first = found.first().unwrap_or_else(|| panic!("nothing found for {value}"));
        assert_eq!(first.kind, kind, "{value}");
        assert_eq!(first.path, "$.hangs[0].frames[0].image");
        assert!(!first.description().contains(value));
    }
}

#[test]
fn accepts_uuids_versions_buckets_and_our_own_name_even_when_the_user_is_called_cmux() {
    assert!(planted_findings("cmux NEXT Nightly", "image").is_empty());
    assert!(planted_findings("libswiftCore.dylib", "image").is_empty());
    assert!(planted_findings("Chromium Embedded Framework", "image").is_empty());
    assert!(planted_findings(APP_UUID, "uuid").is_empty());
}

#[test]
fn refuses_text_that_is_not_json() {
    let kinds: Vec<LeakKind> =
        scanner().findings(b"not json").into_iter().map(|finding| finding.kind).collect();
    assert_eq!(kinds, [LeakKind::NotJson]);
    assert_eq!(serde_json::to_value(LeakKind::NotJson).unwrap(), json!("notJSON"));
}

#[test]
fn scans_keys_too() {
    let kinds: Vec<LeakKind> = scanner()
        .findings(br#"{"alice@example.com": 1, "ok": "fine"}"#)
        .into_iter()
        .map(|finding| finding.kind)
        .collect();
    assert_eq!(kinds, [LeakKind::UnsafeCharacter]);
}

#[test]
fn personal_terms_are_checked_by_name_and_scan() {
    let classifier = Classifier::new(None, &["alice".to_owned()], std::iter::empty());
    assert_eq!(classifier.sendable_name("/usr/lib/libalice.dylib"), None);
    assert_eq!(
        classifier.sendable_name("/usr/lib/libdispatch.dylib").as_deref(),
        Some("libdispatch.dylib")
    );
    assert!(!Scanner::new(&["alice".to_owned()]).findings(br#"{"name":"alice"}"#).is_empty());
}

// MARK: image ownership

#[test]
fn not_the_sealed_system_volume() {
    let classifier = classifier();
    for path in [
        "/System/Volumes/Data/Users/alice/secret-project/libX.dylib",
        "/System/Volumes/Data/Applications/AcmeInternal.app/Contents/MacOS/AcmeInternal",
        "/System/Volumes/Update/mnt1/libAcme.dylib",
        "/System/Library/Caches/com.acme/libAcmeHook.dylib",
        "/System/Library/AssetsV2/com_acme/libAcmeHook.dylib",
        "/usr/lib/../../Users/alice/secret-project/libhook.dylib",
        "/System/Library/Frameworks/../../../Users/alice/libhook.dylib",
        "/System/./Library/libAcme.dylib",
        "/System//Library/libAcme.dylib",
        "System/Library/Frameworks/AppKit.framework/AppKit",
    ] {
        assert_eq!(classifier.owner(path), Owner::Other, "{path}");
        let image =
            LoadedImage::new(path, "0F1E2D3C-4B5A-3968-8776-5A4B3C2D1E0F", 0x3_0000_0000, 0x1000);
        assert_eq!(classifier.frame_at(Some(&image), 0x3_0000_0010), Frame::other(), "{path}");
    }
}

#[test]
fn a_metric_kit_path_name_on_the_data_volume_is_other() {
    let frame = classifier().frame_metric_kit(
        Some("/System/Volumes/Data/Users/alice/secret-project/libX.dylib"),
        Some("0F1E2D3C-4B5A-3968-8776-5A4B3C2D1E0F"),
        Some(0x10),
        None,
    );
    assert_eq!(frame, Frame::other());
}

#[test]
fn apple_images_stay_apples() {
    for path in [
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/usr/lib/system/libsystem_kernel.dylib",
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
    ] {
        assert_eq!(classifier().owner(path), Owner::Apple, "{path}");
    }
}

#[test]
fn the_app_bundle_is_ours() {
    assert_eq!(classifier().owner(&format!("{APP_BUNDLE}/Contents/MacOS/cmux")), Owner::Ours);
    assert_eq!(
        classifier().owner(&format!("{APP_BUNDLE}/../Acme.app/Contents/MacOS/Acme")),
        Owner::Other
    );
}

#[test]
fn bare_names_are_the_ones_the_app_looks_up_on_disk() {
    for name in ["libdispatch.dylib", "AppKit", "libSystem.B.dylib"] {
        assert!(tree::bare_name(name), "{name}");
    }
    for name in [
        "",
        ".hidden",
        "system/libdispatch.dylib",
        "../libX.dylib",
        "cmux NEXT Nightly",
        "GhosttyKit",
    ] {
        assert!(!tree::bare_name(name), "{name}");
    }
}

// MARK: call stack trees

#[test]
fn call_stack_trees_read_the_attributed_threads_heaviest_path() {
    let offsets = |json: &str| {
        tree::stack(json.as_bytes()).into_iter().map(|frame| frame.offset).collect::<Vec<_>>()
    };
    assert_eq!(offsets(&hang_tree()), [Some(4_096), Some(123_456), Some(777), Some(55)]);
    assert!(tree::stack(b"[]").is_empty());
    assert_eq!(offsets(&cpu_tree()), [Some(20), Some(30)]);
}

#[test]
fn stack_refs_name_the_uuids_and_bare_names_to_look_up() {
    let hang = hang_tree();
    let cpu = cpu_tree();
    let refs = tree::refs([hang.as_bytes(), cpu.as_bytes()]);
    assert!(
        refs.uuids.contains(&IME_UUID.to_owned()) && refs.uuids.contains(&GHOSTTY_UUID.to_owned())
    );
    assert!(refs.uuids.iter().all(|uuid| is_uuid(uuid)));
    assert!(refs.names.contains(&"libsystem_kernel.dylib".to_owned()));
    assert!(!refs.names.iter().any(|name| name.contains('/') || name.starts_with("cmux")));
}

// MARK: collector

const fn nanos(ms: u64) -> u64 {
    ms * 1_000_000
}

/// The Swift collector's path: note_stall says what to count and keep, the app fills the frames.
fn note(aggregate: &mut StallAggregate, ms: u64, cpu_ms: u64, has_addresses: bool) {
    let noted = note_stall(
        nanos(ms),
        nanos(cpu_ms),
        has_addresses,
        aggregate.stalls.len(),
        aggregate.stalls.last().map(|last| last.duration_ms),
    );
    if let Some(index) = noted.bucket {
        aggregate.counts[index] += 1;
    }
    if let Some(mut sample) = noted.sample {
        sample.frames = vec![frame("AppKit", APPKIT_UUID, 1)];
        aggregate.keep(sample);
    }
}

#[test]
fn counts_every_stall_and_keeps_the_eight_longest_stacks() {
    let mut aggregate = StallAggregate::default();
    for ms in [60, 120, 260, 300, 310, 320, 330, 340, 350, 360, 370, 1_500, 2_500] {
        note(&mut aggregate, ms, ms / 2, true);
    }
    assert_eq!(
        aggregate.histogram(),
        vec![
            HistogramBucket::new(50, 100, 1),
            HistogramBucket::new(100, 250, 1),
            HistogramBucket::new(250, 500, 9),
            HistogramBucket::new(1_000, 2_000, 1),
            HistogramBucket::new(2_000, 5_000, 1),
        ]
    );
    // A hang-length stall is only counted; its stack comes from note_hang.
    assert_eq!(
        aggregate.stalls.iter().map(|stall| stall.duration_ms).collect::<Vec<_>>(),
        [1_500, 370, 360, 350, 340, 330, 320, 310]
    );
    assert!(aggregate.stalls.iter().all(|stall| stall.kind == Kind::Stall
        && stall.source == Source::Watchdog
        && !stall.frames.is_empty()));
    assert_eq!(aggregate.stalls[0].cpu_ms, Some(750));
}

#[test]
fn a_stall_without_addresses_is_counted_not_kept() {
    let noted = note_stall(nanos(400), 0, false, 0, None);
    assert_eq!(noted.bucket, Some(2));
    assert!(noted.sample.is_none());
    assert_eq!(note_stall(nanos(10), 0, true, 0, None).bucket, None);
}

#[test]
fn hangs_keep_their_stack_sampled_while_they_ran() {
    let noted = note_hang(nanos(2_000), true, 0, None);
    assert_eq!(noted.bucket, None);
    assert_eq!(noted.sample.map(|sample| sample.kind), Some(Kind::Hang));
    assert!(note_hang(nanos(2_000), false, 0, None).sample.is_none());
    assert!(note_hang(nanos(2_000), true, 8, Some(3_000)).sample.is_none());
    assert!(note_hang(nanos(4_000), true, 8, Some(3_000)).sample.is_some());
}

#[test]
fn an_aggregate_survives_encoding_and_merges() {
    let mut aggregate = StallAggregate::default();
    aggregate.count(70);
    aggregate.keep(HangSample::new(Source::Watchdog, Kind::Stall, 400, None, vec![Frame::other()]));
    let decoded: StallAggregate =
        serde_json::from_slice(&serde_json::to_vec(&aggregate).unwrap()).unwrap();
    assert_eq!(decoded, aggregate);
    let mut live = StallAggregate::default();
    note(&mut live, 80, 0, false);
    live.merge(&decoded);
    assert_eq!(live.histogram(), vec![HistogramBucket::new(50, 100, 2)]);
    assert_eq!(live.stalls.len(), 1);
    assert!(StallAggregate::default().is_empty() && !live.is_empty());
}

#[test]
fn coarse_counts_are_buckets() {
    let labels: Vec<&str> =
        [0, 1, 2, 5, 6, 10, 11, 30, 31, 100, 101, 5_000].into_iter().map(bucket).collect();
    assert_eq!(
        labels,
        [
            "0", "1", "2-5", "2-5", "6-10", "6-10", "11-30", "11-30", "31-100", "31-100", "101+",
            "101+"
        ]
    );
}

// MARK: ask policy

#[test]
fn ask_decides() {
    let cases = [
        (true, true, true, true, Ask::Send),
        (true, true, false, false, Ask::Send),
        (true, false, true, true, Ask::Confirm),
        (true, false, false, false, Ask::Confirm),
        (false, false, false, true, Ask::Invite),
        (false, false, false, false, Ask::Off),
        (false, true, false, true, Ask::Invite),
        (false, false, true, true, Ask::Off),
    ];
    for (setting_on, consented, invited, telemetry, expected) in cases {
        assert_eq!(ask(setting_on, consented, invited, telemetry), expected);
    }
}

// MARK: service rules

const DAY_S: f64 = 86_400.0;
/// 2026-10-23T12:00:00Z.
const NOW: f64 = 1_792_756_800.0;

#[test]
fn the_day_is_utc() {
    assert_eq!(service::day(0.0), "1970-01-01");
    assert_eq!(service::day(NOW), "2026-10-23");
    assert_eq!(service::day(951_782_400.0), "2000-02-29");
    assert_eq!(service::day(f64::NAN), "1970-01-01");
}

#[test]
fn at_most_four_reports_a_day() {
    let mut log = SendLog::default();
    for _ in 0..service::DAILY_LIMIT {
        log = take_send_slot(&log, NOW).unwrap();
    }
    assert_eq!(log.sent_today, 4);
    assert!(take_send_slot(&log, NOW + 60.0).is_none());
    let tomorrow = take_send_slot(&log, NOW + DAY_S).unwrap();
    assert_eq!(tomorrow.sent_today, 1);
    assert_eq!(tomorrow.last_sent_at, Some(NOW + DAY_S));
}

#[test]
fn a_launch_sends_the_watchdogs_findings_once_per_day() {
    assert!(service::launch_due(None, NOW, false));
    assert!(!service::launch_due(None, NOW, true));
    assert!(!service::launch_due(Some(NOW - 3_600.0), NOW, false));
    assert!(service::launch_due(Some(NOW - DAY_S), NOW, false));
}

#[test]
fn the_outbox_forgets_old_reports_and_keeps_the_newest_three() {
    let entry = |name: &str, modified: Option<f64>| OutboxEntry { name: name.to_owned(), modified };
    let plan = outbox_plan(
        &[
            entry("c.json", Some(NOW - 30.0)),
            entry("old.json", Some(NOW - 15.0 * DAY_S)),
            entry("a.json", Some(NOW - 50.0)),
            entry("d.json", Some(NOW - 10.0)),
            entry("b.json", Some(NOW - 40.0)),
            entry("notes.txt", Some(NOW)),
            entry(".json", Some(NOW)),
            entry("undated.json", None),
        ],
        NOW,
    );
    assert_eq!(plan.expired, ["old.json", "undated.json"]);
    assert_eq!(plan.ordered, ["a.json", "b.json", "c.json", "d.json"]);
    assert_eq!(plan.trim, ["a.json"]);
}

#[test]
fn the_install_id_rotates_after_thirty_days() {
    let id = "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20";
    assert!(install_id_valid(Some(id), Some(NOW - DAY_S), NOW));
    assert!(!install_id_valid(Some(id), Some(NOW - 31.0 * DAY_S), NOW));
    assert!(!install_id_valid(Some(id), Some(NOW + 60.0), NOW));
    assert!(!install_id_valid(Some("not a uuid"), Some(NOW), NOW));
    assert!(!install_id_valid(None, Some(NOW), NOW));
    assert!(!install_id_valid(Some(id), None, NOW));
}

#[test]
fn a_queued_report_from_another_build_or_schema_is_not_sendable() {
    let (_, body) = report();
    let app = context().app;
    assert!(service::sendable(&body, &app, &scanner()));
    let other = App { build: "70124".to_owned(), ..app.clone() };
    assert!(!service::sendable(&body, &other, &scanner()));
    let mut old: Value = serde_json::from_slice(&body).unwrap();
    old["schema"] = json!(1);
    assert!(!service::sendable(&serde_json::to_vec(&old).unwrap(), &app, &scanner()));
    assert!(!service::sendable(b"{}", &app, &scanner()));
}

#[test]
fn compose_sends_a_clean_report_and_refuses_or_skips_the_rest() {
    let (_, body) = report();
    let mut aggregate = StallAggregate::default();
    aggregate.count(300);
    aggregate.keep(HangSample::new(
        Source::Watchdog,
        Kind::Stall,
        300,
        Some(290),
        watchdog_frames(),
    ));
    let composed =
        service::compose(&builder(), &scanner(), &context(), &aggregate, &[metric_kit_input()]);
    assert_eq!(composed.status, ComposeStatus::Ok);
    assert_eq!(composed.body.as_deref().map(str::as_bytes), Some(body.as_slice()));
    let readable: HangReport = serde_json::from_str(composed.readable.as_deref().unwrap()).unwrap();
    assert_eq!(readable.wire(), body);

    let empty =
        service::compose(&builder(), &scanner(), &context(), &StallAggregate::default(), &[]);
    assert_eq!(empty.status, ComposeStatus::Empty);

    let mut context = context();
    context.report_id = "alice".to_owned();
    let refused = service::compose(&builder(), &scanner(), &context, &aggregate, &[]);
    assert_eq!(refused.status, ComposeStatus::Refused);
    assert!(refused.body.is_none());
    assert_eq!(refused.findings[0].path, "$.reportId");
}

#[test]
fn a_report_too_large_is_fitted_by_dropping_hangs() {
    let mut aggregate = StallAggregate::default();
    aggregate.count(300);
    let many: Vec<Frame> = (0..64).map(|offset| frame("AppKit", APPKIT_UUID, offset)).collect();
    let input = MetricKitInput { hangs: Vec::new(), ..metric_kit_input() };
    let mut inputs = vec![input; 1];
    for _ in 0..8 {
        aggregate.keep(HangSample::new(Source::Watchdog, Kind::Stall, 400, None, many.clone()));
        aggregate.keep(HangSample::new(Source::Watchdog, Kind::Hang, 4_000, None, many.clone()));
    }
    inputs[0].signposts =
        (0..64).map(|index| signpost("motion", &format!("m.{index}"), 1, vec![], None)).collect();
    let composed = service::compose(&builder(), &scanner(), &context(), &aggregate, &inputs);
    assert_eq!(composed.status, ComposeStatus::Ok);
    assert!(composed.body.unwrap().len() <= crate::report::MAX_BODY_BYTES);
}

#[test]
fn intervals_merge_by_category_and_name() {
    let merged = intervals(&[
        signpost("motion", "motion.frame", 2, vec![HistogramBucket::new(0, 10, 2)], Some(0.5)),
        signpost("key", "key.down", 1, vec![], None),
        signpost("motion", "motion.frame", 3, vec![HistogramBucket::new(0, 10, 3)], Some(f64::NAN)),
    ]);
    assert_eq!(merged.len(), 2);
    assert_eq!(merged[0].count, 5);
    assert_eq!(merged[0].buckets, vec![HistogramBucket::new(0, 10, 5)]);
    assert_eq!(merged[0].hitch_ms_per_s, Some(0.5));
    assert_eq!(merged[1].name, "key.down");
}

// MARK: ops

#[test]
fn ops_round_trip_through_json() {
    assert!(ops::serves("hang_report_compose") && !ops::serves("tab_discard_plan"));
    assert!(matches!(ops::call("hang_report_nope", json!({})), Err(ops::OpError::UnknownOp(_))));
    assert!(matches!(
        ops::call("hang_report_ask", json!({"settingOn": "yes"})),
        Err(ops::OpError::Invalid(_))
    ));

    let ask = ops::call(
        "hang_report_ask",
        json!({"settingOn": false, "consented": false, "invited": false,
                                                   "telemetryOptIn": true}),
    )
    .unwrap();
    assert_eq!(ask, json!({"decision": "invite"}));

    let noted = ops::call(
        "hang_report_note_stall",
        json!({"durationNanos": nanos(300), "cpuNanos": nanos(100),
                                                            "hasAddresses": true, "stallCount": 0}),
    )
    .unwrap();
    assert_eq!(
        noted,
        json!({"bucket": 2, "sample": {"cpuMs": 100, "durationMs": 300, "frames": [], "kind": "stall",
                                                      "source": "watchdog"}})
    );

    let counts = ops::call(
        "hang_report_counts",
        json!({"windows": 1, "workspaces": 24, "panes": 12, "tabs": 72}),
    )
    .unwrap();
    assert_eq!(
        counts,
        json!({"panes": "11-30", "tabs": "31-100", "windows": "1", "workspaces": "11-30"})
    );

    let day = ops::call("hang_report_day", json!({"now": NOW})).unwrap();
    assert_eq!(day, json!({"day": "2026-10-23"}));
}

#[test]
fn the_compose_op_builds_what_the_builder_builds() {
    let (_, body) = report();
    let hang = hang_tree();
    let cpu = cpu_tree();
    let refs = ops::call("hang_report_stack_refs", json!({"trees": [hang, cpu]})).unwrap();
    let uuids: Vec<String> = serde_json::from_value(refs["uuids"].clone()).unwrap();
    let loaded: Vec<Value> = images()
        .into_iter()
        .filter(|image| uuids.contains(&image.uuid))
        .map(|image| json!({"path": image.path, "uuid": image.uuid, "base": image.base, "size": image.size}))
        .collect();
    let images = images();
    let addresses: Vec<Value> = WATCHDOG_ADDRESSES
        .iter()
        .map(|address| match images.iter().find(|image| image.contains(*address)) {
            Some(image) => json!({"address": address, "image": {"path": image.path, "uuid": image.uuid, "base": image.base,
                                                                "size": image.size}}),
            None => json!({"address": address}),
        })
        .collect();
    let frames = ops::call(
        "hang_report_frames",
        json!({"addresses": addresses, "appBundlePath": APP_BUNDLE,
                                                        "forbiddenTerms": forbidden_terms()}),
    )
    .unwrap();
    let mut aggregate = serde_json::to_value(StallAggregate::default()).unwrap();
    aggregate = ops::call("hang_report_keep", json!({"aggregate": aggregate, "sample": {
        "cpuMs": 290, "durationMs": 300, "frames": frames["frames"], "kind": "stall", "source": "watchdog"}})).unwrap()
        ["aggregate"].clone();
    aggregate["counts"][2] = json!(1);
    let summary = ops::call("hang_report_aggregate", json!({"aggregate": aggregate})).unwrap();
    assert_eq!(summary["isEmpty"], json!(false));
    let context = json!({
        "reportId": "5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11", "installId": "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20",
        "day": "2026-10-23", "app": {"version": "0.70.0", "build": "70123", "channel": "nightly"},
        "os": {"version": "15.7.4"}, "hardware": {"arch": "arm64", "chip": "Apple M4 Pro", "cores": 14, "memoryGB": 48},
        "counts": {"windows": "1", "workspaces": "11-30", "panes": "11-30", "tabs": "31-100"},
    });
    let input = json!({
        "hangs": [{"durationMs": 2_340, "callStackTree": hang_tree()}],
        "cpuExceptions": [{"cpuMs": 90_000, "sampledMs": 180_000, "callStackTree": cpu_tree()}],
        "metrics": serde_json::to_value(metric_kit_input().metrics).unwrap(),
        "signposts": [
            {"category": "motion", "name": "motion.frame", "count": 1200, "hitchMsPerS": 0.4,
             "buckets": [{"lowMs": 0, "highMs": 10, "count": 1100}, {"lowMs": 10, "highMs": 20, "count": 100}]},
            {"category": "stall", "name": "stall.main", "count": 3},
        ],
    });
    let composed = ops::call("hang_report_compose", json!({
        "context": context, "watchdog": aggregate, "metricKit": [input], "appBundlePath": APP_BUNDLE,
        "forbiddenTerms": forbidden_terms(), "systemImages": ["AppKit", "Foundation", "libsystem_kernel.dylib"],
        "loadedImages": loaded,
    })).unwrap();
    assert_eq!(composed["status"], json!("ok"), "{composed}");
    assert_eq!(composed["body"].as_str().map(str::as_bytes), Some(body.as_slice()));
}
