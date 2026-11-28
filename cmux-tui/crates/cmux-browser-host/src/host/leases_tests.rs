use serde_json::json;

use super::super::{Caller, Host};
use crate::host::Engines;
use crate::protocol::{DriverError, ErrorCode};
use std::sync::Arc;

struct NoEngines;
impl Engines for NoEngines {
    fn driver(
        &self,
        _: &str,
        _: crate::driver::EventSink,
        _: &crate::host::SessionContext,
    ) -> Result<Arc<dyn crate::driver::Driver>, DriverError> {
        Err(DriverError::unsupported_method("driver"))
    }
}

fn caller(origin: &str) -> Caller {
    Caller {
        actor: "t".into(),
        on_behalf_of: None,
        origin: origin.into(),
        locality: crate::locality::CallerLocality::Local,
    }
}

#[test]
fn only_the_person_lends_a_sign_in() {
    let host = Host::new(Arc::new(NoEngines), "/tmp");
    let params = json!({"session": "s", "leases": [
        {"site": "github.com", "tier": "act", "expiresAt": u64::MAX}]});
    for origin in ["cli", "mcp", "script", "remote"] {
        let refused = host.dispatch(&caller(origin), "browser.repl.leases", &params).unwrap_err();
        assert_eq!(refused.code, ErrorCode::Forbidden, "{origin}");
    }
    let missing = host.dispatch(&caller("user"), "browser.repl.leases", &params).unwrap_err();
    assert!(missing.message.contains("no session s"), "{}", missing.message);
}

#[test]
fn a_lease_names_one_site_and_a_tier() {
    let host = Host::new(Arc::new(NoEngines), "/tmp");
    for (lease, needle) in [
        (json!({"site": "com", "tier": "act", "expiresAt": 1}), "public suffix"),
        (json!({"site": "*.github.com", "tier": "act", "expiresAt": 1}), "site"),
        (json!({"site": "github.com", "tier": "admin", "expiresAt": 1}), "tier"),
        (json!({"site": "github.com", "tier": "read"}), "expiresAt"),
    ] {
        let params = json!({"session": "s", "leases": [lease]});
        let refused = host.dispatch(&caller("user"), "browser.repl.leases", &params).unwrap_err();
        assert_eq!(refused.code, ErrorCode::Invalid);
        assert!(refused.message.contains(needle), "{needle}: {}", refused.message);
    }
    let absent = host.dispatch(&caller("user"), "browser.repl.leases", &json!({"session": "s"}));
    assert!(absent.unwrap_err().message.contains("leases"));
}
