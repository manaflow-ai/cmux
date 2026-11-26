use super::*;

#[test]
fn png_size_reads_ihdr_from_base64() {
    // 1x1 transparent PNG.
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
    assert_eq!(png_size(png), Some((1, 1)));
    // 640x480 header.
    let header = "iVBORw0KGgoAAAANSUhEUgAAAoAAAAHgCAYAAAA";
    assert_eq!(png_size(header), Some((640, 480)));
    assert_eq!(png_size("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJ"), None);
    assert_eq!(png_size("short"), None);
}
