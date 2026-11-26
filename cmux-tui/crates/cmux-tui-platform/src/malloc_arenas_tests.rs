use super::env_leaves_default;
use std::ffi::OsStr;

#[test]
fn an_environment_limit_wins_over_the_cap() {
    assert!(env_leaves_default(None, None));
    assert!(env_leaves_default(None, Some(OsStr::new("glibc.malloc.tcache_count=0"))));
    assert!(!env_leaves_default(Some(OsStr::new("4")), None));
    assert!(!env_leaves_default(None, Some(OsStr::new("glibc.malloc.arena_max=8"))));
    assert!(!env_leaves_default(
        None,
        Some(OsStr::new("glibc.malloc.tcache_count=0:glibc.malloc.arena_max=1"))
    ));
}
