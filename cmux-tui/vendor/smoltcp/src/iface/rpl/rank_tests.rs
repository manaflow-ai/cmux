use super::*;

#[test]
fn calculate_rank() {
    let r = Rank::new(27, 16);
    assert_eq!(r.dag_rank(), 1)
}

#[test]
fn comparison() {
    let r1 = Rank::ROOT;
    let r2 = Rank::new(16, 16);
    assert!(r1 == r2);

    let r1 = Rank::new(16, 16);
    let r2 = Rank::new(32, 16);
    assert!(r1 < r2);

    let r1 = Rank::ROOT;
    let r2 = Rank::INFINITE;
    assert!(r1 < r2);
}
