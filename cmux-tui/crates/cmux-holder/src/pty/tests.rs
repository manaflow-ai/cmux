use super::*;

#[test]
fn a_bare_program_name_is_tried_in_each_path_entry_and_a_path_as_it_is() {
    let env = vec![b"HOME=/".to_vec(), b"PATH=/nonexistent-cmux-dir::bin:/usr/bin".to_vec()];
    let tried = program_candidates(b"sh", &env).unwrap();
    let tried: Vec<&[u8]> = tried.iter().map(|path| path.to_bytes()).collect();
    assert_eq!(tried, [&b"/nonexistent-cmux-dir/sh"[..], b"./sh", b"bin/sh", b"/usr/bin/sh"]);
    let default = program_candidates(b"sh", &[]).unwrap();
    let default: Vec<&[u8]> = default.iter().map(|path| path.to_bytes()).collect();
    assert_eq!(default, [&b"/usr/bin/sh"[..], b"/bin/sh"]);
    let named = program_candidates(b"/bin/sh", &env).unwrap();
    assert_eq!(named.len(), 1);
    assert_eq!(named[0].to_bytes(), b"/bin/sh");
    assert!(program_candidates(b"", &env).is_err());
}
