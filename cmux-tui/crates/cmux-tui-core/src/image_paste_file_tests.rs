use super::*;

#[test]
fn cloud_image_paste_crash_receipt_recovers_exact_owned_bytes() {
    let mut file = ImagePasteFile::create("png").unwrap();
    file.append(b"private image bytes").unwrap();
    let path = file.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    // Model process death: descriptors close, but Drop cannot unlink anything.
    file.cleanup = false;
    drop(file);
    let (deadline, mut recovered) = ImagePasteFile::recover_one(directory.clone()).unwrap();
    assert!(deadline <= Instant::now() + Duration::from_secs(720));
    assert_eq!(fs::read(&path).unwrap(), b"private image bytes");
    recovered.expire();
    drop(recovered);
    assert!(!path.exists());
    assert!(!directory.exists());
}

#[test]
fn cloud_image_paste_recovery_rejects_replaced_files() {
    let mut file = ImagePasteFile::create("png").unwrap();
    let path = file.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    let original = directory.join("moved.png");
    fs::rename(&path, &original).unwrap();
    fs::write(&path, "user replacement").unwrap();
    file.cleanup = false;
    drop(file);
    assert!(ImagePasteFile::recover_one(directory.clone()).is_none());
    assert_eq!(fs::read_to_string(&path).unwrap(), "user replacement");
    for name in ["clipboard.png", ".receipt", "moved.png"] {
        fs::remove_file(directory.join(name)).unwrap();
    }
    fs::remove_dir(directory).unwrap();
}

#[test]
fn cloud_image_paste_recovery_does_not_own_an_active_daemons_file_before_expiry() {
    let file = ImagePasteFile::create("png").unwrap();
    let path = file.path().unwrap();
    let (_, recovered) = ImagePasteFile::recover_one(path.parent().unwrap().to_owned()).unwrap();
    drop(recovered);
    assert!(path.exists());
    drop(file);
    assert!(!path.exists());
}
