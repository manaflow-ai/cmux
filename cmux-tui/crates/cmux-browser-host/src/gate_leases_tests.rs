//! Browser grants (RFD 0125 D7.2): a session on the person's profile that
//! holds a grant reaches only its live leased sites; one without a grant
//! keeps its domain policy unchanged.

use super::*;
use cmux_browser_grants::{Lease, Leases, Tier};

fn far() -> u64 {
    now_ms() + 60 * 60 * 1000
}

fn lease(site: &str, expires_at_ms: u64) -> Lease {
    Lease { site: site.into(), tier: Tier::Read, expires_at_ms }
}

fn signed_in_gate() -> (Gate, Arc<FakeDriver>) {
    let (_, driver) = make_gate(Value::Null, false);
    let gate = Gate::new(driver.clone(), Grants { signed_in_profile: true, ..Grants::default() });
    (gate, driver)
}

/// Whether the gate lets the navigation reach the driver (the fake driver
/// fails every navigation itself, so only a Forbidden is the gate's).
fn reaches(gate: &Gate, url: &str) -> bool {
    match gate.driver_call("tab.navigate", json!({"targetId": "T", "url": url})) {
        Err(error) => error.code != ErrorCode::Forbidden,
        Ok(_) => true,
    }
}

fn refusal(gate: &Gate, url: &str) -> DriverError {
    let error = gate.driver_call("tab.navigate", json!({"targetId": "T", "url": url})).unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden, "{}", error.message);
    error
}

fn doc(url: &str) -> crate::driver::RequestInfo<'_> {
    crate::driver::RequestInfo { target: "T", url, kind: crate::driver::RequestKind::Document }
}

#[test]
fn a_leased_session_reaches_only_its_leased_sites() {
    let (gate, driver) = signed_in_gate();
    gate.set_leases(Some(Leases(vec![lease("github.com", far())]))).unwrap();
    assert!(reaches(&gate, "https://github.com/login"), "the leased site");
    assert!(reaches(&gate, "https://gist.github.com/"), "a subdomain of the leased site");
    let refused = refusal(&gate, "https://mail.google.com/");
    assert!(refused.message.contains("google.com is not lent"), "{}", refused.message);
    assert!(!reaches(&gate, "https://github.com.evil.test/"));
    // Documents the page opens itself go through the same lease.
    let filter = driver.filter.lock().unwrap().clone().expect("a request filter");
    assert!(filter(&doc("https://github.com/x")).is_none());
    assert!(filter(&doc("https://mail.google.com/")).is_some());
    // A page's own subresources follow it (its CDN is not a sign-in).
    assert!(filter(&sub("https://github.githubassets.com/app.js")).is_none());
    // Its cookies: the leased site's only.
    assert!(gate.policy.lock().unwrap().cookie_refusal(".github.com").is_none());
    assert!(gate.policy.lock().unwrap().cookie_refusal("mail.google.com").is_some());
    let got = policy(&gate, "get", json!({})).unwrap();
    assert_eq!(got["leasedSites"], json!(["github.com"]));
}

#[test]
fn an_expired_or_revoked_lease_reaches_nothing() {
    let (gate, _) = signed_in_gate();
    gate.set_leases(Some(Leases(vec![lease("github.com", now_ms().saturating_sub(1))]))).unwrap();
    assert!(!reaches(&gate, "https://github.com/"), "expired");
    // Every grant revoked (Stop All): an empty lease set, still enforced.
    gate.set_leases(Some(Leases::default())).unwrap();
    assert!(!reaches(&gate, "https://github.com/"), "revoked");
    assert!(reaches(&gate, "about:blank"));
}

#[test]
fn a_lease_never_widens_the_domain_policy() {
    let (gate, _) = signed_in_gate();
    gate.set_leases(Some(Leases(vec![lease("github.com", far()), lease("linear.app", far())])))
        .unwrap();
    policy(&gate, "set", json!({"allowed": ["linear.app"]})).unwrap();
    assert!(!reaches(&gate, "https://github.com/"), "allowedDomains still narrows");
    assert!(reaches(&gate, "https://linear.app/"), "both allow it");
    policy(&gate, "set", json!({"allowed": null, "prohibited": ["linear.app"]})).unwrap();
    assert!(!reaches(&gate, "https://linear.app/"), "prohibitedDomains still refuses");
}

#[test]
fn a_session_without_grants_is_unchanged() {
    let (gate, driver) = signed_in_gate();
    assert!(reaches(&gate, "https://anything.test/"), "no policy, no grant: as today");
    assert!(driver.filter.lock().unwrap().is_none(), "no filter installed without a policy");
    policy(&gate, "set", json!({"allowed": ["example.com"]})).unwrap();
    assert!(reaches(&gate, "https://example.com/"));
    let refused = refusal(&gate, "https://evil.test/");
    assert!(refused.message.contains("session.allowedDomains"), "{}", refused.message);
    assert!(policy(&gate, "get", json!({})).unwrap().get("leasedSites").is_none());
    // Clearing the leases returns a leased session to the same behaviour.
    gate.set_leases(Some(Leases(vec![lease("github.com", far())]))).unwrap();
    gate.set_leases(None).unwrap();
    assert!(reaches(&gate, "https://example.com/"));
}

#[test]
fn the_agent_profile_takes_no_lease() {
    let (gate, _) = make_gate(Value::Null, false);
    assert!(gate.set_leases(Some(Leases(vec![lease("github.com", far())]))).is_err());
    gate.set_leases(None).unwrap();
}
