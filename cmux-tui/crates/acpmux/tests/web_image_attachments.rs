//! The dashboard keeps an image's original bytes for the prompt while using a
//! bounded copy for its local preview.

#[test]
fn large_images_are_accepted_and_keep_the_original_attachment() {
    let page = include_str!("../web/index.html");

    assert!(!page.contains("Image is larger than 8 MB"));
    assert!(page.contains("async function previewImage"));
    assert!(page.contains("data: url.slice(comma + 1)"));
    assert!(page.contains("data: x.data"));
}
