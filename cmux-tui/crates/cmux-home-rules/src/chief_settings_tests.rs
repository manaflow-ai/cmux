use super::*;

#[test]
fn format_fills_positional_and_sequential_arguments() {
    assert_eq!(format("%1$@ · %2$@ context", &["Opus 5.5", "1M"]), "Opus 5.5 · 1M context");
    assert_eq!(format("%2$@ / %1$@", &["a", "b"]), "b / a");
    assert_eq!(format("Default (%@)", &["Claude"]), "Default (Claude)");
    assert_eq!(format("100%% %@", &["x"]), "100% x");
}

#[test]
fn every_op_routes() {
    for op in OPS {
        assert_ne!(call(op, &Value::Null), Err(OpError::Unknown), "{op}");
    }
}
