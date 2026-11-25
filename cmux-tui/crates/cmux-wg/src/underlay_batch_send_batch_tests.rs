use super::*;

#[test]
fn consumed_datagrams_leave_the_front_in_order() {
    let target = SocketAddr::from(([127, 0, 0, 1], 9));
    let mut batch = SendBatch::default();
    for n in 0..200u8 {
        batch.push(&[n; 3], target);
        if n % 2 == 1 {
            batch.consume(1);
        }
    }
    assert_eq!(batch.len(), 100);
    assert_eq!(batch.get(0), Some((&[100u8; 3][..], target)));
    assert!(batch.entries.len() < 200, "consumed entries were compacted away");
    batch.consume(100);
    assert!(batch.is_empty() && batch.data.is_empty());
}
