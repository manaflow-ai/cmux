use super::*;

fn temp_dir(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-cookie-backups-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

fn record(expires: f64) -> Value {
    json!({"site": "a.test", "store": null, "createdAt": 1, "cookies": [
        {"name": "sid", "value": "s3cret-cookie-value", "domain": "a.test", "path": "/",
         "expires": expires, "session": expires < 0.0}
    ]})
}

#[test]
fn a_full_backup_store_refuses_a_new_backup_and_keeps_every_old_one() {
    // By count.
    let dir = temp_dir("count");
    let backups = CookieBackups::open(&dir).unwrap().with_limits(3, u64::MAX);
    let kept: Vec<String> =
        (0..3).map(|_| backups.save(&record(4_000_000_000.0)).unwrap()).collect();
    let refused = backups.save(&record(4_000_000_000.0)).unwrap_err();
    assert!(refused.contains("full"), "{refused}");
    assert!(refused.contains("restore") && refused.contains("purge"), "{refused}");
    assert_eq!(backups.ids().len(), 3, "nothing written, nothing dropped");
    for id in &kept {
        assert!(backups.load(id).is_ok(), "the oldest backup is never dropped");
    }
    backups.remove(&kept[0]).unwrap();
    assert!(backups.save(&record(4_000_000_000.0)).is_ok(), "room again after a restore");
    let _ = fs::remove_dir_all(&dir);

    // By size: two backups fit, the third does not.
    let dir = temp_dir("bytes");
    let probe = CookieBackups::open(&dir).unwrap();
    let first = probe.save(&record(4_000_000_000.0)).unwrap();
    let size = fs::metadata(probe.path(stem(&first).unwrap())).unwrap().len();
    let backups = CookieBackups::open(&dir).unwrap().with_limits(50, size * 2 + size / 2);
    let second = backups.save(&record(4_000_000_000.0)).unwrap();
    let refused = backups.save(&record(4_000_000_000.0)).unwrap_err();
    assert!(refused.contains("full"), "{refused}");
    assert!(backups.load(&first).is_ok() && backups.load(&second).is_ok());
    assert_eq!(backups.ids().len(), 2);
    let _ = fs::remove_dir_all(&dir);
}
