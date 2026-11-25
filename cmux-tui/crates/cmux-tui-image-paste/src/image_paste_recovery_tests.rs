use super::*;
use std::fs;
use std::os::unix::fs::DirBuilderExt;

#[test]
fn cloud_image_paste_recovery_continues_across_batches_and_rescans() {
    let mut random = [0u8; 16];
    getrandom::fill(&mut random).unwrap();
    let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let temporary = std::env::temp_dir().join(format!("image-recovery-test-{suffix}"));
    fs::DirBuilder::new().mode(0o700).create(&temporary).unwrap();
    let storage = ImagePasteStorage::at(&temporary).unwrap();
    let namespace = storage.root().to_owned();
    // Explicitly keep the files to model process death; write no user data.
    let create_expired = |storage: &ImagePasteStorage| {
        let file = ImagePasteFile::create_in(storage, "png", 720).unwrap();
        let directory = file.directory().to_owned();
        let receipt_path = directory.join(".receipt");
        let mut receipt: serde_json::Value =
            serde_json::from_slice(&fs::read(&receipt_path).unwrap()).unwrap();
        receipt["expires"] = serde_json::json!(0);
        fs::write(&receipt_path, serde_json::to_vec(&receipt).unwrap()).unwrap();
        // Read-only recovery handles do not remove anything when dropped.
        let (_, recovered) = ImagePasteFile::recover_one(directory, 0).unwrap();
        file.abandon_for_test();
        drop(recovered);
    };
    for _ in 0..80 {
        create_expired(&storage);
    }
    let mut recovery = ImagePasteRecovery { storage: Some(storage), ..Default::default() };
    assert_eq!(recovery.scan(&HashSet::new()), Duration::from_millis(50));
    assert!(!recovery.ready);
    assert_eq!(fs::read_dir(&namespace).unwrap().count(), 16);
    assert_eq!(recovery.scan(&HashSet::new()), Duration::from_secs(30));
    assert!(recovery.ready);
    assert_eq!(fs::read_dir(&namespace).unwrap().count(), 0);
    create_expired(recovery.storage.as_ref().unwrap());
    assert_eq!(recovery.scan(&HashSet::new()), Duration::from_secs(30));
    assert_eq!(fs::read_dir(&namespace).unwrap().count(), 0);
    drop(recovery);
    fs::remove_dir(namespace).unwrap();
    fs::remove_dir(temporary).unwrap();
}
