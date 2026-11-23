use super::path_identity;
use std::path::Path;

#[test]
fn a_moved_state_path_keeps_its_name_from_before_the_move() {
    let support = Path::new("/Users/a/Library/Application Support");
    let at = |folder: &str, rest: &str| support.join(folder).join(rest);
    for rest in ["tags/nightly/tui/terminal-hosts-x", "builds/k1/tui"] {
        assert_eq!(path_identity(&at("cmux-next", rest)), at("cmux", rest));
    }
    for own in
        [Path::new("/Users/a/.local/state/cmux-tui").to_path_buf(), at("cmux-next", "agent-home")]
    {
        assert_eq!(path_identity(&own), own);
    }
}
