use std::io::Write as _;

#[test]
fn a_failed_unit_write_keeps_the_previous_unit() {
    let dir = std::env::temp_dir().join(format!("cmux-host-unit-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("cmux-host-remote.service");
    std::fs::write(&path, "old\n").unwrap();
    let full = || std::io::Error::from(std::io::ErrorKind::StorageFull);
    let error = super::imp::replace_unit(&path, |file| {
        file.write_all(b"cut")?;
        Err(full())
    })
    .unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::StorageFull);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "old\n");
    assert!(!path.with_extension("service.new").exists());
    super::imp::replace_unit(&path, |file| file.write_all(b"new\n")).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "new\n");
    std::fs::remove_dir_all(dir).unwrap();
}
