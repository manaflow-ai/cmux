use super::*;

#[test]
fn index_from_cwd() {
    assert_eq!(index_of(Some("/run/cwd/s00042")), 42);
    assert_eq!(index_of(Some("/run/cwd/s00042/")), 42);
    assert_eq!(index_of(Some("/elsewhere")), 0);
    assert_eq!(index_of(None), 0);
}
