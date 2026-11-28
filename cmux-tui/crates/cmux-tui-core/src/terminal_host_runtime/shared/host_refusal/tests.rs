use super::*;

#[test]
fn host_hello_refusals_stay_typed_through_context() {
    let refused = anyhow::Error::new(RefusedHostHello).context("connect terminal host");
    assert!(is_refused_host_hello(&refused));
    assert!(is_no_common_host_protocol(&no_common_protocol_if_refused(refused)));
    let every_version = adoption_failed(&["protocol 4: refused".into()], true).context("adopt");
    assert!(is_no_common_host_protocol(&every_version));
    let other = anyhow::anyhow!("terminal host did not send an initial snapshot");
    assert!(!is_refused_host_hello(&other));
    assert!(!is_no_common_host_protocol(&no_common_protocol_if_refused(other)));
    assert!(!is_no_common_host_protocol(&adoption_failed(&[], false)));
}
