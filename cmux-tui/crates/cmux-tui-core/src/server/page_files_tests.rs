use super::*;

fn packed_tree(name: &str) -> PathBuf {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::temp_dir()
        .join(format!("cmux-page-files-{name}-{}-{stamp}", std::process::id()))
        .join("pages");
    std::fs::create_dir_all(root.join("__shared")).unwrap();
    std::fs::write(root.join("__shared/kept.js"), "export const kept = 1;").unwrap();
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(b"export const settings = 'packed';").unwrap();
    std::fs::write(root.join("__shared/page-settings.js.deflate"), encoder.finish().unwrap())
        .unwrap();
    root
}

#[test]
fn a_packed_page_script_is_served_inflated_as_javascript() {
    let root = packed_tree("served");
    let (file, body) = page_file(&root, "/pages/__shared/page-settings.js?v=1").unwrap();
    assert_eq!(body, b"export const settings = 'packed';");
    assert_eq!(file.file_name().unwrap(), "page-settings.js");
    assert_eq!(content_type(&file), "text/javascript; charset=utf-8");
    // An unpacked file is read as it is.
    let (_, kept) = page_file(&root, "/pages/__shared/kept.js").unwrap();
    assert_eq!(kept, b"export const kept = 1;");
    // The packed copy itself and missing files are not served.
    assert!(page_file(&root, "/pages/__shared/page-settings.js.deflate").is_none());
    assert!(page_file(&root, "/pages/__shared/missing.js").is_none());
    let _ = std::fs::remove_dir_all(root.parent().unwrap());
}

#[test]
fn a_packed_file_that_does_not_inflate_is_not_served() {
    let root = packed_tree("corrupt");
    std::fs::write(root.join("__shared/broken.js.deflate"), [0xff, 0xff, 0xff, 0xff]).unwrap();
    assert!(page_file(&root, "/pages/__shared/broken.js").is_none());
    let _ = std::fs::remove_dir_all(root.parent().unwrap());
}
