use super::*;
use crate::host::Engines;

struct NoEngines;
impl Engines for NoEngines {
    fn driver(
        &self,
        _: &str,
        _: crate::driver::EventSink,
        _: &crate::host::SessionContext,
    ) -> Result<Arc<dyn crate::driver::Driver>, DriverError> {
        Err(DriverError::unsupported_method("driver"))
    }
}

fn caller(origin: &str) -> Caller {
    Caller {
        actor: "t".into(),
        on_behalf_of: None,
        origin: origin.into(),
        locality: crate::locality::CallerLocality::Local,
    }
}

fn host(name: &str) -> (Host, Arc<CookieBackups>, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("cmux-cookie-purge-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let backups = Arc::new(CookieBackups::open(&dir).unwrap());
    let host = Host::new(Arc::new(NoEngines), "/tmp").with_cookie_backups(backups.clone());
    (host, backups, dir)
}

fn backup(backups: &CookieBackups) -> String {
    backups
        .save(&json!({"site": "a.test", "store": null, "createdAt": 1, "cookies": [
                {"name": "sid", "value": "v", "domain": "a.test", "path": "/", "session": true}]}))
        .unwrap()
}

#[test]
fn only_the_person_lists_or_purges_cookie_backups() {
    let (host, backups, dir) = host("origin");
    let id = backup(&backups);
    for origin in ["cli", "mcp", "script", "remote"] {
        for (op, params) in [
            ("browser.cookieBackups.list", json!({})),
            ("browser.cookieBackups.purge", json!({"restoreId": id})),
            ("browser.cookieBackups.purge", json!({"all": true, "confirm": "x"})),
        ] {
            let refused = host.dispatch(&caller(origin), op, &params).unwrap_err();
            assert_eq!(refused.code, ErrorCode::Forbidden, "{origin} {op}");
        }
    }
    assert!(backups.load(&id).is_ok(), "no agent removed the backup");
    let listed = host.dispatch(&caller("user"), "browser.cookieBackups.list", &json!({})).unwrap();
    assert_eq!(listed["backups"][0]["restoreId"], id.as_str());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_purge_deletes_only_after_its_own_confirmation() {
    let (host, backups, dir) = host("confirm");
    let (a, b) = (backup(&backups), backup(&backups));
    let purge =
        |params: Value| host.dispatch(&caller("user"), "browser.cookieBackups.purge", &params);
    let asked = purge(json!({"restoreId": a})).unwrap();
    assert_eq!(asked["deleted"], 0);
    assert_eq!(asked["backups"].as_array().unwrap().len(), 1);
    let token = asked["confirm"].as_str().unwrap().to_owned();
    assert!(backups.load(&a).is_ok(), "asking deletes nothing");
    // A token confirms only its own request, once.
    assert!(purge(json!({"all": true, "confirm": token})).is_err());
    assert!(backups.load(&a).is_ok() && backups.load(&b).is_ok());
    let token = purge(json!({"restoreId": a})).unwrap()["confirm"].as_str().unwrap().to_owned();
    assert_eq!(purge(json!({"restoreId": a, "confirm": token})).unwrap()["deleted"], 1);
    assert!(backups.load(&a).is_err() && backups.load(&b).is_ok());
    assert!(purge(json!({"restoreId": a, "confirm": token})).is_err(), "used once");
    let token = purge(json!({"all": true})).unwrap()["confirm"].as_str().unwrap().to_owned();
    assert_eq!(purge(json!({"all": true, "confirm": token})).unwrap()["deleted"], 1);
    assert!(backups.ids().is_empty());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_purge_is_logged_where_the_person_reads_it() {
    let (host, backups, dir) = host("log");
    let (a, _b) = (backup(&backups), backup(&backups));
    let user = caller("user");
    let purge = |params: Value| host.dispatch(&user, "browser.cookieBackups.purge", &params);
    let token = purge(json!({"restoreId": a})).unwrap()["confirm"].as_str().unwrap().to_owned();
    let log = |host: &Host| {
        host.dispatch(&user, "browser.cookieBackups.list", &json!({})).unwrap()["log"].clone()
    };
    assert_eq!(log(&host), json!([]), "asking deletes nothing and logs nothing");
    purge(json!({"restoreId": a, "confirm": token})).unwrap();
    let entries = log(&host);
    let entries = entries.as_array().unwrap();
    assert_eq!(entries.len(), 1, "{entries:?}");
    let entry = &entries[0];
    assert_eq!(entry["op"], "cookieBackups.purge");
    assert_eq!(entry["restoreIds"], json!([a]));
    assert_eq!(entry["deleted"], 1);
    assert_eq!(entry["origin"], "user");
    assert_eq!(entry["actor"], "t");
    assert!(entry["at"].as_u64().is_some());
    assert!(!entry.to_string().contains("\"v\""), "no cookie value: {entry}");
    let _ = std::fs::remove_dir_all(dir);
}
