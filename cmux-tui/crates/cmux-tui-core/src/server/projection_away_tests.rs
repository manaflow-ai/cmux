use super::*;

#[test]
fn a_chat_works_in_the_projection_at_its_mount_point_or_below() {
    let at = Path::new("/home/u/work/chat");
    assert!(works_in("/home/u/work/chat", at));
    assert!(works_in("/home/u/work/chat/src", at));
    assert!(!works_in("/home/u/work/chat2", at));
    assert!(!works_in("/home/u/work", at));
}
