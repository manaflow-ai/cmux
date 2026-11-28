use super::*;

#[test]
fn paths_read_as_foundation_reads_them() {
    assert_eq!(last_component("/bin/zsh"), "zsh");
    assert_eq!(last_component("zsh"), "zsh");
    assert_eq!(last_component("/usr/bin/"), "bin");
    assert_eq!(last_component("/"), "/");
    assert_eq!(parent_path("/a/b/ghostty"), "/a/b");
    assert_eq!(parent_path("/ghostty"), "/");
    assert_eq!(parent_path("ghostty"), "");
    assert_eq!(join("/s/", "a/b/"), "/s/a/b");
}
