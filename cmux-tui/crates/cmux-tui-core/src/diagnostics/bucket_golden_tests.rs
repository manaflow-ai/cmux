//! The log-linear buckets match the golden that Swift's CmuxNextMetrics reads too
//! (`cmux-trace/tests/fixtures/metrics-log-linear-golden.txt`),
//! so a sample lands in the same bucket in the app's and the daemon's metrics files.

use super::LogLinearHistogram;

const GOLDEN: &str =
    include_str!("../../../cmux-trace/tests/fixtures/metrics-log-linear-golden.txt");

#[test]
fn log_linear_buckets_match_the_shared_golden() {
    let mut checked = 0;
    for line in GOLDEN.lines().filter(|line| !line.starts_with('#') && !line.is_empty()) {
        let fields: Vec<u64> = line
            .split(' ')
            .map(|field| field.parse().expect("golden fields are numbers"))
            .collect();
        let [value, index, upper] = fields[..] else {
            panic!("golden line {line:?} has three fields")
        };
        let index = usize::try_from(index).expect("index fits usize");
        assert_eq!(LogLinearHistogram::bucket_index(value), index, "value {value}");
        assert_eq!(LogLinearHistogram::bucket_upper_bound(index), upper, "index {index}");
        checked += 1;
    }
    assert_eq!(checked, 1000);
}
