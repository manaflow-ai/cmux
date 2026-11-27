use super::*;

#[test]
fn spread_of_one_to_hundred() {
    let s: Vec<f64> = (1..=100).map(f64::from).collect();
    let v = spread_ms(&s);
    assert_eq!(v["n"], 100);
    assert_eq!(v["p50"], 51.0);
    assert_eq!(v["p95"], 95.0);
    assert_eq!(v["max"], 100.0);
    assert_eq!(spread_ms(&[])["n"], 0);
    assert_eq!(ratio(Some(3.0), Some(2.0)), json!(1.5));
    assert_eq!(ratio(Some(3.0), Some(0.0)), Value::Null);
}
