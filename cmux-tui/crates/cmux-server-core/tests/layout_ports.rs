//! Layout table (server.md 4.3) and port block (server.md 8.2).

use cmux_server_core::ports::{first_candidate, fnv1a64};

#[test]
fn fnv_and_first_candidate_golden() {
    assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    assert_eq!(first_candidate(""), 21469);
    assert_eq!(first_candidate("a"), 17428);
    assert_eq!(first_candidate("inst_test"), 17274);
}
