use super::blob_fingerprints;

#[test]
fn blob_fingerprints_cover_hunk_and_binary_sections() {
    let patch = concat!(
        "diff --git a/src/a.txt b/src/a.txt\n",
        "index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644\n",
        "--- a/src/a.txt\n+++ b/src/a.txt\n",
        "@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/assets/logo.png b/assets/logo.png\n",
        "index aaaaaaa..bbbbbbb 100644\n",
        "Binary files a/assets/logo.png and b/assets/logo.png differ\n",
    );
    let values = blob_fingerprints(patch.as_bytes());
    assert_eq!(values.len(), 2);
    assert_eq!(values[0].0, "src/a.txt");
    assert_eq!(values[1].0, "assets/logo.png");
    assert_eq!(values[0].1, "blob:8df14ed8");
    assert!(values.iter().all(|(_, fingerprint)| fingerprint.starts_with("blob:")));
    assert_ne!(values[0].1, values[1].1);
}
