use super::*;

#[test]
fn receiver_protocol_hello_bounds_leave_control_frames_small() {
    for length in [1100, MAX_LINK_TOKEN_BYTES] {
        let hello = ServiceHello {
            service: Service::Daemon,
            epoch: Some(4),
            link_token: Some("t".repeat(length)),
        };
        let wire = line(&hello);
        assert!(wire.len() > MAX_LINE_BYTES && wire.len() <= MAX_HELLO_BYTES);
        assert_eq!(ServiceHello::parse(&wire), Some(hello));
        assert!(parse_line::<serde_json::Value>(&wire).is_none());
    }
    let oversized = ServiceHello {
        service: Service::Daemon,
        epoch: Some(4),
        link_token: Some("t".repeat(MAX_LINK_TOKEN_BYTES + 1)),
    };
    assert!(ServiceHello::parse(&line(&oversized)).is_none());
    let padded =
        format!("{}{}", " ".repeat(MAX_HELLO_BYTES), line(&ServiceHello::paired(Service::Daemon)));
    assert!(ServiceHello::parse(&padded).is_none());
    assert!(ServiceHello::parse(r#"{"service":"daemon","extra":true}"#).is_none());
}

#[test]
fn the_dial_contract_has_stable_wire_shapes() {
    let request =
        parse_request(r#"{"op":"link.dial","host":"inst_9","service":"daemon"}"#).unwrap();
    assert_eq!(request.host, "inst_9");
    assert_eq!(
        line(&DialReply::connected(PathState::Direct)),
        "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n"
    );
    assert_eq!(
        line(&DialReply::failed(DialError::Unreachable)),
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n"
    );
    assert_eq!(line(&ServiceHello::paired(Service::Daemon)), "{\"service\":\"daemon\"}\n");
    let cloud =
        ServiceHello { service: Service::Ssh, link_token: Some("tok".into()), epoch: Some(3) };
    assert_eq!(line(&cloud), "{\"service\":\"ssh\",\"link_token\":\"tok\",\"epoch\":3}\n");
    let desktop = ServiceHello { service: Service::Desktop, link_token: None, epoch: None };
    assert_eq!(line(&desktop), "{\"service\":\"desktop\"}\n");
    assert_eq!(line(&ServiceHello::paired(Service::Acpmux)), "{\"service\":\"acpmux\"}\n");
    assert_eq!(
        line(&DialReply::failed(DialError::HostPaused)),
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"host_paused\"}\n"
    );
    assert_eq!(
        line(&DialReply::failed_because(
            DialError::Unreachable,
            "connect_info: cloud.machine.not_bound\n"
        )),
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\",\"error_detail\":\"connect_info: cloud.machine.not_bound\"}\n"
    );
    let long = DialReply::failed_because(DialError::Unreachable, &"x".repeat(1000));
    assert_eq!(long.error_detail.map(|d| d.len()), Some(MAX_ERROR_DETAIL_BYTES));
    let wide = DialReply::failed_because(DialError::Unreachable, &"\u{e9}".repeat(1000));
    assert!(wide.error_detail.is_some_and(|d| d.len() <= MAX_ERROR_DETAIL_BYTES));
    assert_eq!(DialReply::failed_because(DialError::Unreachable, " \n").error_detail, None);
    // A reply with a field this reader does not know still parses.
    let newer: DialReply = parse_line(
            "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\",\"later_field\":1}",
        )
        .expect("an unknown reply field is ignored");
    assert_eq!(newer.error_code, Some(DialError::Unreachable));
}

#[test]
fn bad_dial_requests_are_refused() {
    for bad in [
        r#"{"op":"link.dial","host":"inst","service":"shell"}"#,
        r#"{"op":"link.listen","host":"inst","service":"daemon"}"#,
        r#"{"op":"link.dial","host":"../x","service":"daemon"}"#,
        r#"{"op":"link.dial","host":"inst","service":"daemon","command":"sh"}"#,
    ] {
        assert_eq!(parse_request(bad), Err(DialError::BadRequest), "{bad}");
    }
}
