use super::*;

#[test]
fn raw_plan_keeps_the_exact_private_object() {
    let request = json!({"id": 7, "cmd": "private-operation", "opaque": {"x": true}});
    let plan = RawCommandPlan { request: request.clone(), stream: false };
    assert_eq!(plan.request, request);
}

#[test]
fn explicit_session_precedes_ambient_socket_fallbacks() {
    let global = GlobalArgs { session: Some("session-alpha".into()), ..GlobalArgs::default() };
    let socket =
        super::super::wire::resolve_socket_with_env(&global, |_| Some("/tmp/stale.sock".into()))
            .expect("session socket path should resolve");

    assert_eq!(
        socket.0,
        cmux_tui_core::server::try_default_socket_path("session-alpha")
            .expect("session socket path should resolve")
    );
}
