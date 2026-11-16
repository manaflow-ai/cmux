//! A sidebar document request and a connection shutdown that race.

use super::*;
use crate::session::remote::tests::{SilentWriter, test_session};

/// The shutdown lands after the request's first shutdown check and before
/// its answer slot exists, so the shutdown's sweep of waiting requests
/// misses it: the request must still end with the shutdown, not wait for
/// an answer that can never come.
#[test]
fn a_sidebar_request_that_starts_as_the_connection_shuts_down_ends_with_the_shutdown() {
    let session = test_session(Box::new(SilentWriter));
    let weak = Arc::downgrade(&session);
    *lock(&session.sidebar_doc.before_pending_insert) = Some(Box::new(move || {
        if let Some(session) = weak.upgrade() {
            session.begin_shutdown();
        }
    }));
    let error = session
        .protocol2_request("sidebar.get", Map::new(), false)
        .expect_err("no answer can come after the shutdown");
    assert!(
        matches!(error.downcast_ref::<RemoteRequestError>(), Some(RemoteRequestError::Shutdown)),
        "{error:#}"
    );
    assert!(session.sidebar_doc.pending().is_empty(), "the request left its answer slot behind");
}
