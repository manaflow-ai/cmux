use super::*;

#[test]
fn reads_days_groupings_and_formats_and_refuses_anything_else() {
    assert_eq!(
        AuditQuery::from_params(&json!({})).unwrap(),
        AuditQuery { since: None, until: None, group_by: "person", csv: false }
    );
    assert_eq!(
            AuditQuery::from_params(
                &json!({"since": "2026-11-01", "until": "2026-11-09", "groupBy": "machine", "format": "csv"})
            )
            .unwrap(),
            AuditQuery {
                since: Some("2026-11-01".into()),
                until: Some("2026-11-09".into()),
                group_by: "machine",
                csv: true
            }
        );
    for bad in [
        json!({"since": "yesterday"}),
        json!({"until": 1762646400000u64}),
        json!({"since": "2026-11-1"}),
        json!({"groupBy": "team"}),
        json!({"groupBy": ["day"]}),
        json!({"format": "xml"}),
    ] {
        assert!(AuditQuery::from_params(&bad).is_err(), "{bad}");
    }
}

#[tokio::test]
async fn only_the_local_socket_and_the_app_read_the_team_audit() {
    for origin in [Origin::Web, Origin::Peer] {
        let err = handle(origin, &json!({})).await.unwrap_err();
        assert!(format!("{err:?}").contains("_acpmux/team_audit"), "{err:?}");
    }
    assert!(handle(Origin::Local, &json!({"groupBy": "nope"})).await.is_err());
}

#[test]
fn a_csv_keeps_a_plain_suggested_name() {
    assert_eq!(
        suggested_name(Some(
            r#"attachment; filename="cmux-agent-spend-2026-11-01-2026-11-09-model.csv""#
        )),
        "cmux-agent-spend-2026-11-01-2026-11-09-model.csv"
    );
    for odd in [
        None,
        Some("attachment"),
        Some(r#"attachment; filename="../x.csv""#),
        Some("filename=a.sh"),
    ] {
        assert_eq!(suggested_name(odd), DEFAULT_CSV_NAME, "{odd:?}");
    }
}

#[tokio::test]
async fn a_csv_never_replaces_a_file_and_concurrent_downloads_get_their_own() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.csv"), "theirs").unwrap();
    let saved = write_new(dir.path(), "a.csv", b"mine", CSV_NAMES).await.unwrap();
    assert_eq!(saved, dir.path().join("a 2.csv"));
    assert_eq!(std::fs::read_to_string(dir.path().join("a.csv")).unwrap(), "theirs");
    assert_eq!(std::fs::read_to_string(&saved).unwrap(), "mine");

    let both = tempfile::tempdir().unwrap();
    let downloads = (0..16).map(|i| {
        let dir = both.path().to_owned();
        tokio::spawn(async move {
            let body = format!("download {i}");
            let path = write_new(&dir, "b.csv", body.as_bytes(), CSV_NAMES).await.unwrap();
            (path, body)
        })
    });
    let mut paths = std::collections::BTreeSet::new();
    for download in downloads.collect::<Vec<_>>() {
        let (path, body) = download.await.unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), body);
        assert!(paths.insert(path));
    }
    assert_eq!(paths.len(), 16);
}

#[tokio::test]
async fn a_csv_fails_when_every_name_is_taken_and_touches_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let taken: Vec<_> = candidates(dir.path(), "c.csv", 3).collect();
    assert_eq!(taken, ["c.csv", "c 2.csv", "c 3.csv"].map(|name| dir.path().join(name)).to_vec());
    for path in &taken {
        std::fs::write(path, "theirs").unwrap();
    }
    let err = write_new(dir.path(), "c.csv", b"mine", 3).await.unwrap_err();
    assert!(err.contains("already exist"), "{err}");
    for path in &taken {
        assert_eq!(std::fs::read_to_string(path).unwrap(), "theirs");
    }
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 3);
}

/// CMUX-284: the platform's CSV went to Downloads as it came, so a cell a teammate controls (a
/// session title, a name) starting with `=`, `+`, `-` or `@` ran as a formula when opened.
#[test]
fn a_saved_csv_opens_formulas_as_text() {
    let body = b"person,title,cost,note\r\n\
alice,=HYPERLINK(\"http://x\"),-12.5,ok\r\n\
bob,\"=1+1, \"\"quoted\"\"\",+3,@SUM(A1)\r\n\
carol,-2+3,\"\r=x\",\tlead\n\
dave,,\"plain, text\",+cmd|' /C calc'!A0\n\
eve,\"multi\nline\",7,";
    let want = b"person,title,cost,note\r\n\
alice,'=HYPERLINK(\"http://x\"),-12.5,ok\r\n\
bob,\"'=1+1, \"\"quoted\"\"\",+3,'@SUM(A1)\r\n\
carol,'-2+3,\"'\r=x\",'\tlead\n\
dave,,\"plain, text\",'+cmd|' /C calc'!A0\n\
eve,\"multi\nline\",7,";
    assert_eq!(String::from_utf8_lossy(&defuse_formulas(body)), String::from_utf8_lossy(want));
    // A CSV with nothing risky is the same bytes.
    let plain = b"a,b\n\"x, y\",-1\n";
    assert_eq!(defuse_formulas(plain), plain.to_vec());
}

#[test]
fn a_refusal_names_only_a_plain_code() {
    assert_eq!(
        refusal(503, br#"{"code":"usage.unavailable"}"#),
        "cmux-platform refused (503 usage.unavailable)"
    );
    assert_eq!(refusal(500, b"<html>secret</html>"), "cmux-platform refused (500)");
    assert_eq!(refusal(400, br#"{"code":"has spaces in it"}"#), "cmux-platform refused (400)");
}
