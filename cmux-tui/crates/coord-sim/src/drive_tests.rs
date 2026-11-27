use super::*;

#[test]
fn join_counts_loss_and_duplicates() {
    let emit = |seq, update: &str| EmitRecord {
        c: 1,
        seq,
        k: 0,
        kind: "in:plan".into(),
        update: update.into(),
        bytes: 10,
        due_us: 1000,
        emit_us: 2000,
    };
    let mut store = HashMap::new();
    store.insert(
        (1, 1, 0),
        vec![("in".to_string(), "plan".to_string(), 3), ("out".into(), "x".into(), 9)],
    );
    store.insert((1, 3, 0), vec![("mux".to_string(), "user_message".to_string(), 5)]);
    let seen = vec![((1, 1, 0, 2000), 4000), ((1, 1, 0, 2000), 4500)];
    let rows = join(&[emit(1, "plan"), emit(2, "plan"), emit(3, "turn")], &store, &seen);
    assert_eq!(rows[0]["daemon_n"], 1);
    assert_eq!(rows[0]["daemon_at_ms"], 3);
    assert_eq!(rows[0]["reader_us"], 4000);
    assert_eq!(rows[0]["reader_n"], 2);
    assert_eq!(rows[1]["daemon_n"], 0);
    assert_eq!(rows[2]["src"], "turn");
    assert_eq!(rows[2]["daemon_n"], 1);
}
