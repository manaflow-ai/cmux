use super::*;

#[tokio::test]
async fn a_record_round_trips_and_an_oversized_one_closes_the_reader() {
    let (mut a, mut b) = tokio::io::duplex(1 << 16);
    write_frame(&mut a, &json!({"id": 1, "method": "read"})).await.unwrap();
    assert_eq!(read_frame(&mut b).await, Some(json!({"id": 1, "method": "read"})));
    a.write_u32((MAX_FRAME + 1) as u32).await.unwrap();
    assert_eq!(read_frame(&mut b).await, None);
}
