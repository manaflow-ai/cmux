use super::*;
use std::os::unix::fs::PermissionsExt;

#[test]
fn cloud_image_paste_refuses_a_writable_non_sticky_temporary_parent() {
    let mut nonce = [0u8; 16];
    getrandom::fill(&mut nonce).unwrap();
    let suffix: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    let parent = std::env::temp_dir().join(format!("image-unsafe-test-{suffix}"));
    fs::create_dir(&parent).unwrap();
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(ImagePasteStorage::at(&parent).is_err());
    fs::remove_dir(parent).unwrap();
}
