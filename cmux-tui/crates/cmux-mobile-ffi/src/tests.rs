use super::*;

fn mac(id: &str, cols: u16, rows: u16) -> TerminalSizingParticipant {
    TerminalSizingParticipant {
        viewport: Some(TerminalGridSize::new(cols, rows)),
        ..TerminalSizingParticipant::new(id, TerminalDeviceKind::Mac)
    }
}

#[test]
fn wire_helpers_match_the_contract() {
    assert_eq!(
        terminal_sizing_reason_wire(TerminalSizingReason::PriorityFallback),
        "priority-fallback"
    );
    assert_eq!(terminal_sizing_reason_wire(TerminalSizingReason::Held), "held");
    assert_eq!(terminal_device_kind_from_wire("quantum".into()), TerminalDeviceKind::Unknown);
    assert_eq!(terminal_device_kind_wire(TerminalDeviceKind::Iphone), "iphone");
    let policy = terminal_sizing_policy(
        TerminalSizingMode::Fixed,
        Vec::new(),
        Some(TerminalGridSize::new(0, 0)),
    );
    assert_eq!(policy.fixed, Some(TerminalGridSize::new(2, 1)));
    assert_eq!(
        terminal_sizing_policy_from_json(r#"{"mode":"fixed","fixed":{"cols":1,"rows":0}}"#.into()),
        Ok(policy)
    );
    let engine =
        TerminalSizingEngine::new(TerminalGridSize::new(80, 24), TerminalSizingPolicy::default());
    engine.attach(mac("a", 100, 30));
    let json = terminal_sizing_state_to_json(engine.state()).unwrap();
    assert_eq!(terminal_sizing_state_from_json(json), Ok(engine.state()));
    assert!(matches!(
        terminal_sizing_state_from_json("{".into()),
        Err(TerminalSizingWireError::Invalid { .. })
    ));
}
