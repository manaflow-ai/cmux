use super::*;

#[test]
fn slug_matches_claude_code() {
    assert_eq!(
        claude_slug(Path::new("/Users/me/conductor/workspaces/app/lima.v2")),
        "-Users-me-conductor-workspaces-app-lima-v2"
    );
}
