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
    let (deadline, recovered) = ImagePasteFile::recover_one(directory.clone()).unwrap();
    assert!(deadline <= Instant::now() + Duration::from_secs(720));
    assert_eq!(fs::read(&path).unwrap(), b"private image bytes");
    assert!(recovered.remove_owned());
    drop(recovered);
    assert!(!path.exists());
    assert!(!directory.exists());
}

#[test]
fn cloud_image_paste_recovery_requires_a_marker_even_when_inode_metadata_matches() {
    let mut original = ImagePasteFile::create("png").unwrap();
    let path = original.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    original.cleanup = false;
    drop(original);
    fs::remove_file(&path).unwrap();
    fs::write(&path, "replacement user file").unwrap();
    let receipt_path = directory.join(".receipt");
    let mut receipt: Receipt = serde_json::from_reader(File::open(&receipt_path).unwrap()).unwrap();
    let replacement = fs::metadata(&path).unwrap();
    // Model an allocator reusing the recorded inode without depending on a
    // particular filesystem's inode allocator. Keep the original ownership token.
    receipt.file_device = replacement.dev();
    receipt.file_inode = replacement.ino();
    serde_json::to_writer(File::create(&receipt_path).unwrap(), &receipt).unwrap();
    assert!(ImagePasteFile::recover_one(directory.clone()).is_none());
    assert_eq!(fs::read_to_string(&path).unwrap(), "replacement user file");
    fs::remove_file(path).unwrap();
    fs::remove_file(receipt_path).unwrap();
    fs::remove_dir(directory).unwrap();
}
