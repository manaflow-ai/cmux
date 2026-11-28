use super::*;

#[test]
fn grant_is_per_caller_tenant_repo_and_expires() {
    let cache = AuthCache::new(Duration::from_millis(50));
    let a = caller_key(Some(b"Basic YTpi"));
    let b = caller_key(Some(b"Basic Yzpk"));
    assert_ne!(a, b);
    assert!(!a.contains("YTpi"));
    cache.grant(&a, "t1", "o/r");
    assert!(cache.allowed(&a, "t1", "o/r"));
    assert!(!cache.allowed(&b, "t1", "o/r"));
    assert!(!cache.allowed(&a, "t2", "o/r"));
    assert!(!cache.allowed(&a, "t1", "o/other"));
    assert!(!cache.allowed("anon", "t1", "o/r"));
    cache.revoke(&a, "t1", "o/r");
    assert!(!cache.allowed(&a, "t1", "o/r"));
    cache.grant(&a, "t1", "o/r");
    std::thread::sleep(Duration::from_millis(80));
    assert!(!cache.allowed(&a, "t1", "o/r"));
}
