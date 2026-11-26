//! Date pins resolve to the newest revision on or before them, the server
//! names the version it served, and an old pin keeps the old shape.

use super::*;
use crate::{Change, Compat, MessageChange};

/// Base 12 is `2026-11-24`; revision 13 (`2027-03-01`) renames a result member.
fn dated() -> Schema {
    let mut schema = Schema::new("cmux-mux", 12);
    schema.base_date = Some("2026-11-24".into());
    schema.push_dated(
        "2027-03-01",
        "list-clients result: name is now label",
        vec![MessageChange {
            message: "response:list-clients".into(),
            change: Change::Rename { path: "/data/name".into(), to: "label".into() },
        }],
    );
    schema
}

#[test]
fn version_dates_parse_strictly() {
    assert_eq!(ApiDate::parse("2026-11-24").unwrap().to_string(), "2026-11-24");
    assert!(ApiDate::parse("2028-02-29").is_ok());
    for bad in
        ["2026-11-4", "2026/11/24", "2027-02-29", "2026-13-01", "2026-00-10", "+026-11-24", ""]
    {
        assert_eq!(ApiDate::parse(bad), Err(CompatError::BadVersion(bad.into())), "{bad}");
    }
    assert!(ApiDate::parse("2026-11-24").unwrap() < ApiDate::parse("2027-01-01").unwrap());
}

#[test]
fn version_pin_resolves_to_newest_revision_on_or_before_it() {
    let schema = dated();
    let resolve = |pin: &str| schema.resolve_version(pin).unwrap();
    assert_eq!(resolve("2026-11-24"), Resolved { revision: 12, served: "2026-11-24".into() });
    assert_eq!(resolve("2027-02-28"), Resolved { revision: 12, served: "2026-11-24".into() });
    assert_eq!(resolve("2027-03-01"), Resolved { revision: 13, served: "2027-03-01".into() });
    // A pin newer than this build gets the newest it has, and is told so.
    assert_eq!(resolve("2030-01-01"), Resolved { revision: 13, served: "2027-03-01".into() });
    assert_eq!(
        schema.resolve_version("2026-01-01"),
        Err(CompatError::UnsupportedVersion {
            version: "2026-01-01".into(),
            oldest: "2026-11-24".into(),
            newest: "2027-03-01".into(),
        })
    );
    assert_eq!(schema.current_version(), Some("2027-03-01"));
    assert_eq!(schema.oldest_version(), Some("2026-11-24"));
    assert!(Schema::new("undated", 1).resolve_version("2026-11-24").is_err());
}

#[test]
fn version_old_pin_keeps_the_old_response_shape() {
    let compat = Compat::new(dated()).unwrap();
    let reply = br#"{"id":1,"ok":true,"data":{"label":"agent","pid":7}}"#;
    let old = compat.schema().resolve_version("2026-12-01").unwrap().revision;
    let served = compat.translate("response:list-clients", 13, old, reply).unwrap();
    assert_eq!(&*served, br#"{"id":1,"ok":true,"data":{"name":"agent","pid":7}}"#);
    let new = compat.schema().resolve_version("2027-03-01").unwrap().revision;
    let served = compat.translate("response:list-clients", 13, new, reply).unwrap();
    assert_eq!(&*served, reply);
}

#[test]
fn version_dates_are_validated_with_the_schema() {
    let mut schema = dated();
    assert!(schema.validate().is_ok());
    schema.revisions[0].date = Some("2026-11-24".into());
    assert!(schema.validate().is_err(), "a revision must be dated after the one before");
    schema.revisions[0].date = None;
    assert!(schema.validate().is_err(), "a dated schema dates every revision");
    schema.base_date = None;
    assert!(schema.validate().is_ok());
    schema.revisions[0].date = Some("2027-03-01".into());
    assert!(schema.validate().is_err(), "a date needs a base_date");
    let json = br#"{"protocol":"p","base":3,"base_date":"2026-11-24","revisions":[{"rev":4,"date":"2026-12-01"}]}"#;
    assert_eq!(Schema::from_json(json).unwrap().resolve_version("2026-12-02").unwrap().revision, 4);
}
