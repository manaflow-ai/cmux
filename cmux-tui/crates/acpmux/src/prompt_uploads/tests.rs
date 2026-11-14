use super::*;

#[test]
fn a_resolved_link_under_web_control_is_refused() {
    // A web client's queue edit keeps a person's resolved blocks; its turn is refused.
    let mut blocks = vec![
        json!({"type": "text", "text": "edited"}),
        json!({"type": "resource_link", "uri": "file:///x/a.bin", "name": "a.bin",
                "_meta": {"acpmux": {"uploadPath": "/x/a.bin"}}}),
    ];
    let refused = resolve("s", true, &mut blocks).unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "upload.remote");
    // The same blocks under the person's control are resolved already: nothing to read.
    assert!(resolve("s", false, &mut blocks).is_ok());
    assert_eq!(blocks.len(), 2);
}

#[test]
fn a_remote_web_prompt_is_refused_before_any_file_is_read() {
    let mut blocks = vec![json!({"type": "image", "_meta": {"acpmux": {"upload": {
            "uploadId": "01a17a00-0000-7000-8000-000000000000", "fileName": "a.png"}}}})];
    let refused = resolve("s", true, &mut blocks).unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "upload.remote");
    assert!(resolve("s", true, &mut vec![json!({"type": "text", "text": "x"})]).is_ok());
}

#[test]
fn a_link_names_its_upload_on_any_platform() {
    let (id, peer) = (uuid::Uuid::now_v7(), uuid::Uuid::now_v7());
    let link =
        |path: String| json!({"type": "resource_link", "_meta": {"acpmux": {"uploadPath": path}}});
    let blocks = [
        link(format!("/home/me/state/uploads/chat/{id}/a.png")),
        link(format!("C:\\Users\\me\\acpmux\\uploads\\chat\\{}\\b.png", peer.simple())),
        link("a.png".to_owned()),
    ];
    assert_eq!(upload_ids(&blocks), [id.to_string(), peer.to_string()].into_iter().collect());
}
