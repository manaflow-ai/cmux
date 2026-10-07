use super::*;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-cookie-backups-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

fn record(expires: f64) -> Value {
    json!({"site": "a.test", "store": null, "createdAt": 1, "cookies": [
        {"name": "sid", "value": "s3cret-cookie-value", "domain": "a.test", "path": "/",
         "expires": expires, "session": expires < 0.0}
    ]})
}

#[cfg(unix)]
fn mode(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn a_backup_is_encrypted_private_and_restores_once() {
    let dir = temp_dir("save");
    let backups = CookieBackups::open(&dir).unwrap();
    let id = backups.save(&record(4_000_000_000.0)).unwrap();
    assert!(stem(&id).is_some(), "{id}");
    let file = backups.path(stem(&id).unwrap());
    let bytes = fs::read(&file).unwrap();
    assert!(
        !String::from_utf8_lossy(&bytes).contains("s3cret-cookie-value"),
        "the backup holds no plain cookie value"
    );
    #[cfg(unix)]
    {
        assert_eq!(mode(&file), 0o600);
        assert_eq!(mode(&dir.join(KEY_FILE)), 0o600);
        assert_eq!(mode(&dir.join(BACKUPS)), 0o700);
        assert_eq!(mode(&dir), 0o700);
    }
    assert_eq!(backups.load(&id).unwrap(), record(4_000_000_000.0));
    let listed = backups.list(0.0);
    assert_eq!(listed, vec![json!({"restoreId": id, "site": "a.test", "cookies": 1, "createdAt": 1})]);
    assert!(!listed[0].to_string().contains("s3cret"), "a summary holds no value");
    backups.remove(&id).unwrap();
    assert!(backups.load(&id).unwrap_err().contains("no cookie backup"));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_backup_does_not_open_under_another_id_or_key() {
    let dir = temp_dir("bind");
    let backups = CookieBackups::open(&dir).unwrap();
    let a = backups.save(&record(4_000_000_000.0)).unwrap();
    let b = backups.save(&record(4_000_000_000.0)).unwrap();
    fs::copy(backups.path(stem(&a).unwrap()), backups.path(stem(&b).unwrap())).unwrap();
    assert!(backups.load(&b).unwrap_err().contains("does not open"), "renamed file");
    fs::remove_file(dir.join(KEY_FILE)).unwrap();
    assert!(backups.load(&a).unwrap_err().contains("does not open"), "another key");
    for bad in ["host:../../etc/passwd", "host:ABCDEF", "provider:0123", "0123456789abcdef0123456789abcdef"]
    {
        assert!(backups.load(bad).unwrap_err().contains("not a restore id"), "{bad}");
    }
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_backup_goes_when_every_cookie_has_expired_and_a_session_cookie_keeps_it() {
    let dir = temp_dir("expire");
    let backups = CookieBackups::open(&dir).unwrap();
    let dated = backups.save(&record(1_000.0)).unwrap();
    let session = backups.save(&record(-1.0)).unwrap();
    let later = backups.save(&record(5_000.0)).unwrap();
    assert_eq!(backups.prune_expired(2_000.0), 1);
    assert!(backups.load(&dated).is_err());
    assert!(backups.load(&session).is_ok(), "a session cookie has no expiry of its own");
    assert!(backups.load(&later).is_ok());
    let _ = fs::remove_dir_all(&dir);
}
