//! Arguments, the release-key spec, kernel route tables and hex text come
//! from outside the process: each gives a value or a typed error, never a
//! panic.

use cmux_server::cli::{Args, parse};
use cmux_server::health::probe::has_default_route;
use cmux_server::{ExitKind, host, keys};

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

fn key(id: &str, byte: &str) -> String {
    format!("{id}:{}", byte.repeat(32))
}

#[test]
fn key_spec_parses_ids_and_keys() {
    assert_eq!(keys::parse("").unwrap(), []);
    assert_eq!(keys::parse(" \n\t").unwrap(), []);
    let parsed =
        keys::parse(&format!(" {} ,{}\n", key("current", "0a"), key("next.v-2", "Ff"))).unwrap();
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0].id, "current");
    assert_eq!(parsed[0].public_key, [0x0a; 32]);
    assert_eq!(parsed[1].id, "next.v-2");
    assert_eq!(parsed[1].public_key, [0xff; 32]);
}

#[test]
fn malformed_key_specs_name_the_first_problem() {
    let good = key("a", "00");
    let cases = [
        (format!("{good},"), "CMUX_SERVER_RELEASE_KEYS has an empty entry"),
        (format!(",{good}"), "CMUX_SERVER_RELEASE_KEYS has an empty entry"),
        (format!("{good}, ,{}", key("b", "00")), "CMUX_SERVER_RELEASE_KEYS has an empty entry"),
        ("a".to_owned(), "CMUX_SERVER_RELEASE_KEYS entry is not <id>:<64 hex>"),
        (format!(":{}", "00".repeat(32)), "CMUX_SERVER_RELEASE_KEYS entry has an empty id"),
        (key("a b", "00"), "CMUX_SERVER_RELEASE_KEYS id is not [A-Za-z0-9._-]+"),
        (key("é", "00"), "CMUX_SERVER_RELEASE_KEYS id is not [A-Za-z0-9._-]+"),
        (format!("a:{}", "00".repeat(31)), "CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits"),
        (format!("a:{}0g", "00".repeat(31)), "CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits"),
        (format!("a:{}é", "00".repeat(31)), "CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits"),
        (format!("a::{}", "0".repeat(63)), "CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits"),
        (format!("{good},{}", key("b", "11")), ""),
        (format!("{good},{}", key("a", "11")), "CMUX_SERVER_RELEASE_KEYS repeats a key id"),
        (
            format!("{good},{},{}", key("b", "11"), key(" a", "22")),
            "CMUX_SERVER_RELEASE_KEYS repeats a key id",
        ),
        // Validity is checked before uniqueness, entry by entry.
        (format!("{good},a:00"), "CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits"),
    ];
    for (spec, want) in cases {
        match keys::parse(&spec) {
            Ok(_) => assert_eq!(want, "", "{spec:?} parsed"),
            Err(reason) => assert_eq!(reason, want, "{spec:?}"),
        }
    }
}

#[test]
fn args_split_flags_positionals_and_the_separator() {
    let args = parse(&words("server db archive-wal --json pg_wal/0001 0001")).unwrap();
    assert_eq!(args.verb, ["db", "archive-wal"]);
    assert_eq!(args.positionals, ["pg_wal/0001", "0001"]);
    assert!(args.json);
    assert_eq!(args.positional(1, "file").unwrap(), "0001");

    // After `--` a word that starts with `--` is a positional.
    let args = parse(&words("db archive-wal -- --odd é")).unwrap();
    assert_eq!(args.positionals, ["--odd", "é"]);

    let args = parse(&words("db create --mode=schema app")).unwrap();
    assert_eq!(args.value("mode"), Some("schema"));
    assert_eq!(args.positionals, ["app"]);
    let args = parse(&words("pin --clear")).unwrap();
    assert!(args.positionals.is_empty());
    assert!(args.has("clear"));

    for line in ["", "help", "help install", "--help"] {
        assert!(parse(&words(line)).unwrap().help, "{line:?}");
    }
}

#[test]
fn bad_args_are_usage_errors() {
    for line in [
        "nope",
        "db",
        "db create",
        "db archive-wal one",
        "db url a b",
        "install --bogus",
        "install --system=1",
        "install --version",
        "install --=x",
    ] {
        let error = parse(&words(line)).unwrap_err();
        assert_eq!(error.kind, ExitKind::Usage, "{line:?}: {}", error.message);
    }
}

#[test]
fn a_missing_positional_is_a_usage_error() {
    let args = Args::default();
    let error = args.positional(0, "app").unwrap_err();
    assert_eq!(error.kind, ExitKind::Usage);
    assert_eq!(error.message, "missing <app>");
}

#[test]
fn default_route_reads_short_and_odd_route_lines() {
    let proc_dir = tempfile::tempdir().unwrap();
    let net = proc_dir.path().join("net");
    std::fs::create_dir(&net).unwrap();
    let route = net.join("route");
    let ipv6 = net.join("ipv6_route");
    let header = "Iface\tDestination\tGateway\tFlags\n";

    std::fs::write(&route, format!("{header}eth0\t00000000\t0101A8C0\t0003\n")).unwrap();
    assert_eq!(has_default_route(proc_dir.path()), Some(true));

    // Down (no RTF_UP), not the default, short and non-hex lines.
    std::fs::write(&route, format!("{header}eth0\t00000000\t0101A8C0\t0002\neth0\t0000A8C0\t0\t0001\neth0\t00000000\n\né\t00000000\tx\tzz\n")).unwrap();
    assert_eq!(has_default_route(proc_dir.path()), Some(false));

    let v6_default = "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003 eth0\n";
    std::fs::write(&ipv6, v6_default).unwrap();
    assert_eq!(has_default_route(proc_dir.path()), Some(true));
    std::fs::write(&ipv6, v6_default.replace(" eth0", " lo")).unwrap();
    assert_eq!(has_default_route(proc_dir.path()), Some(false));
    std::fs::write(&ipv6, "00000000000000000000000000000000 00 0 00 0 0 0 0 00000003\n").unwrap();
    assert_eq!(has_default_route(proc_dir.path()), Some(false));

    std::fs::remove_file(&route).unwrap();
    std::fs::remove_file(&ipv6).unwrap();
    assert_eq!(has_default_route(proc_dir.path()), None);
}

#[test]
fn unhex32_needs_64_hex_digits() {
    assert_eq!(host::unhex32(&"ab".repeat(32)), Some([0xab; 32]));
    assert_eq!(host::unhex32(&"ab".repeat(31)), None);
    assert_eq!(host::unhex32(&format!("{}zz", "ab".repeat(31))), None);
    assert_eq!(host::unhex32(&format!("{}é", "a".repeat(62))), None);
}
