#[test]
fn eight_cores_encode_on_four_threads_and_fewer_on_two() {
    let threads: Vec<u16> = [1, 2, 4, 6, 8, 16].map(super::threads_for_cores).to_vec();
    assert_eq!(threads, [2, 2, 2, 2, 4, 4]);
}
