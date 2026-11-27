use super::*;

#[test]
fn the_bucket_count_is_one_per_bound_and_the_overflow() {
    assert_eq!(BUCKET_COUNT, 1 + (POWERS * SUB_BUCKETS) as usize + 1);
    assert_eq!(bounds_us().len(), BUCKET_COUNT - 1);
}

#[test]
fn each_bound_is_in_its_own_bucket() {
    for (index, bound) in bounds_us().into_iter().enumerate() {
        assert_eq!(bucket(bound), index);
        assert_eq!(bucket(bound + 1), index + 1);
    }
    assert_eq!(bucket(u64::MAX), BUCKET_COUNT - 1);
}
