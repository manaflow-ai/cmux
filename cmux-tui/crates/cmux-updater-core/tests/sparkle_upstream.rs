//! Sparkle 2.10.0's own comparator tests (Tests/SUVersionComparisonTest.m), every assertion that
//! is not commented out there, against `version::compare`: the order the app's Sparkle installs by.

use std::cmp::Ordering::{self, Equal, Greater, Less};

use cmux_updater_core::version::compare;

const CASES: &[(&str, &str, Ordering)] = &[
    // testNumbers
    ("1.0", "1.1", Less),
    ("1.0", "1.0", Equal),
    ("2.0", "1.1", Greater),
    ("0.1", "0.0.1", Greater),
    ("0.1", "0.1.2", Less),
    // testPrereleases
    ("1.5.5-335d3e2", "1.5.6-b252311", Less),
    ("1.5.5-335d3e2", "1.5.5-a655360", Equal),
    ("1.5.6-b252311", "1.5.5-335d3e2", Greater),
    ("1.5-335d3e2", "1.5.0-335d3e2", Equal),
    ("1.5.0-335d3e2", "1.5-335d3e2", Equal),
    ("1.5.5", "1.5.6a1", Less),
    ("1.1.0b1", "1.1.0b2", Less),
    ("1.1.1b2", "1.1.2b1", Less),
    ("1.1.1b2", "1.1.2a1", Less),
    ("1.0a1", "1.0b1", Less),
    ("1.0b1", "1.0", Less),
    ("0.9", "1.0a1", Less),
    ("1.0b", "1.0b2", Less),
    ("1.0b10", "1.0b11", Less),
    ("1.0b9", "1.0b10", Less),
    ("1.0rc", "1.0", Less),
    ("1.0b", "1.0", Less),
    ("1.0pre1", "1.0", Less),
    ("1.0pre1", "1.0.0pre1", Equal),
    ("1.0.0pre1", "1.0pre1", Equal),
    // testVersionsWithBuildNumbers
    ("1.0 (1234)", "1.0 (1235)", Less),
    ("1.0b1 (1234)", "1.0 (1234)", Less),
    ("1.0b5 (1234)", "1.0b5 (1235)", Less),
    ("1.0b5 (1234)", "1.0.1b5 (1234)", Less),
    ("1.0.1b5 (1234)", "1.0.1b6 (1234)", Less),
    ("2.0.0.2429", "2.0.0.2430", Less),
    ("1.1.1.1818", "2.0.0.2430", Less),
    ("3.3 (5847)", "3.3.1b1 (5902)", Less),
    ("3.3 (5847)", "3.3.0 (5847)", Equal),
    ("3.3.0 (5847)", "3.3 (5847)", Equal),
    ("1.1.1.1818", "1.1.1.1818.0", Equal),
    ("1.1.1.1818.0", "1.1.1.1818", Equal),
    ("3.3b1 (5902)", "3.3.0b1 (5902)", Equal),
    ("3.3.0b1 (5902)", "3.3b1 (5902)", Equal),
    // testVersionsWithReverseDateBasedNumbers
    ("201210251627", "201211051041", Less),
    ("201210251627.0", "201210251627", Equal),
    ("201210251627", "201210251627.0", Equal),
];

#[test]
fn every_upstream_assertion_holds() {
    for (a, b, order) in CASES {
        assert_eq!(compare(a, b), *order, "{a} vs {b}");
    }
}
