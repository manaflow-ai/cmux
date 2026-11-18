use super::*;

#[test]
fn host_and_a_session_id_name_that_session_by_id() {
    let id = "01a1acb2-5bb4-75a3-b5eb-a0eeea1d59d5";
    let to = recipient(&format!("machine-b/{id}"));
    assert_eq!(
        (to.session_id.as_deref(), to.name, to.host.as_deref()),
        (Some(id), None, Some("machine-b"))
    );
    let to = recipient("machine-b/own-e2e");
    assert_eq!((to.name.as_deref(), to.session_id), (Some("own-e2e"), None));
}

#[test]
fn a_prompt_id_the_hub_would_refuse_as_a_key_is_digested() {
    let id = "0190f2a4-7c1e-7d3a-9f00-0123456789ab";
    assert_eq!(idempotency_key(id), id);
    let short = idempotency_key("abc");
    assert!(short.starts_with("p:") && short.len() == 42, "{short}");
    assert_eq!(idempotency_key("has space in it"), idempotency_key("has space in it"));
    assert_eq!(recipient("huge-blue/dep-land").host.as_deref(), Some("huge-blue"));
    assert_eq!(recipient("dep-land").host, None);
    assert_eq!(
        recipient("@lawrence/coordinator").team_address.as_deref(),
        Some("@lawrence/coordinator")
    );
    assert!(valid_team_address("@team/role"));
    assert!(valid_team_address("@member/reviewer:backend"));
    assert!(!valid_team_address("@team"));
}
