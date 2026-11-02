//! Version order. The Sparkle cases are Sparkle 2.10.0's own
//! `Tests/SUVersionComparisonTest.m` (the comparator the Swift app called,
//! `SUStandardVersionComparator`); the rest are the orders cmux relies on.

mod updater_core_version {
    use cmux_updater_core::version::{
        SystemVersion, compare_numeric, compare_sparkle, is_newer_build, is_older, newest_first,
    };
    use std::cmp::Ordering::{Equal, Greater, Less};

    fn ascending(a: &str, b: &str) {
        assert_eq!(compare_sparkle(a, b), Less, "{a} should be older than {b}");
    }
    fn descending(a: &str, b: &str) {
        assert_eq!(compare_sparkle(a, b), Greater, "{a} should be newer than {b}");
    }
    fn same(a: &str, b: &str) {
        assert_eq!(compare_sparkle(a, b), Equal, "{a} should equal {b}");
    }

    #[test]
    fn sparkle_numbers() {
        ascending("1.0", "1.1");
        same("1.0", "1.0");
        descending("2.0", "1.1");
        descending("0.1", "0.0.1");
        ascending("0.1", "0.1.2");
        same("1.0", "1.0.0");
        same("1.0.0", "1.0");
    }

    #[test]
    fn sparkle_commit_shas_after_a_dash_are_ignored() {
        ascending("1.5.5-335d3e2", "1.5.6-b252311");
        same("1.5.5-335d3e2", "1.5.5-a655360");
        descending("1.5.6-b252311", "1.5.5-335d3e2");
        same("1.5-335d3e2", "1.5.0-335d3e2");
        same("1.5.0-335d3e2", "1.5-335d3e2");
    }

    #[test]
    fn sparkle_prereleases() {
        ascending("1.5.5", "1.5.6a1");
        ascending("1.1.0b1", "1.1.0b2");
        ascending("1.1.1b2", "1.1.2b1");
        ascending("1.1.1b2", "1.1.2a1");
        ascending("1.0a1", "1.0b1");
        ascending("1.0b1", "1.0");
        ascending("0.9", "1.0a1");
        ascending("1.0b", "1.0b2");
        ascending("1.0b10", "1.0b11");
        ascending("1.0b9", "1.0b10");
        ascending("1.0rc", "1.0");
        ascending("1.0b", "1.0");
        ascending("1.0pre1", "1.0");
        same("1.0pre1", "1.0.0pre1");
        same("1.0.0pre1", "1.0pre1");
    }

    #[test]
    fn sparkle_versions_with_build_numbers() {
        ascending("1.0 (1234)", "1.0 (1235)");
        ascending("1.0b1 (1234)", "1.0 (1234)");
        ascending("1.0b5 (1234)", "1.0b5 (1235)");
        ascending("1.0b5 (1234)", "1.0.1b5 (1234)");
        ascending("1.0.1b5 (1234)", "1.0.1b6 (1234)");
        ascending("2.0.0.2429", "2.0.0.2430");
        ascending("1.1.1.1818", "2.0.0.2430");
        ascending("3.3 (5847)", "3.3.1b1 (5902)");
        same("3.3 (5847)", "3.3.0 (5847)");
        same("3.3.0 (5847)", "3.3 (5847)");
        same("1.1.1.1818", "1.1.1.1818.0");
        same("1.1.1.1818.0", "1.1.1.1818");
        same("3.3b1 (5902)", "3.3.0b1 (5902)");
        same("3.3.0b1 (5902)", "3.3b1 (5902)");
    }

    #[test]
    fn sparkle_reverse_date_based_numbers() {
        ascending("201210251627", "201211051041");
        same("201210251627.0", "201210251627");
        same("201210251627", "201210251627.0");
    }

    /// cmux NEXT's `CFBundleVersion` values: plain build numbers (nightly 24950001,
    /// the 13-digit pulled build 4091813159501) compare by value, not by text.
    #[test]
    fn cmux_build_numbers_compare_by_value() {
        assert!(is_older("100", "200"));
        assert!(is_older("99", "100"));
        assert!(is_older("24950001", "4091813159501"));
        assert!(!is_older("300", "300"));
        assert!(!is_older("500", "300"));
    }

    /// `+` is a Unicode symbol, not punctuation: Sparkle reads it as a string part.
    #[test]
    fn a_plus_is_a_string_part_and_a_string_tail_is_older() {
        ascending("1.0+build", "1.0");
        ascending("1.0 build", "1.0.1");
        // `_` is punctuation, which ends the number prefix: the balance pads
        // "1.0" to "1.0.0" before it, so "1.0_1" reads as older than "1.0.1".
        ascending("1.0_1", "1.0.1");
    }

    #[test]
    fn empty_versions() {
        same("", "");
        ascending("", "1");
        descending("1", "");
        // A tail that is a string makes the shorter version newer.
        descending("", "a");
    }

    /// `KeptVersionStore.isNewer`: `String.compare(_:options: .numeric)`.
    #[test]
    fn numeric_build_order() {
        assert_eq!(compare_numeric("10", "9"), Greater);
        assert_eq!(compare_numeric("Name2", "Name25"), Less);
        assert_eq!(compare_numeric("Name7", "Name25"), Less);
        assert_eq!(compare_numeric("4091813159501", "999999999999"), Greater);
        assert_eq!(compare_numeric("300", "300"), Equal);
        assert_eq!(compare_numeric("1a", "1b"), Less);
        assert_eq!(compare_numeric("1", "1a"), Less);
        // Digit runs longer than any integer still compare by value.
        assert_eq!(
            compare_numeric("123456789012345678901234567890", "123456789012345678901234567891"),
            Less
        );
        assert!(is_newer_build("400", "300"));
        assert!(!is_newer_build("300", "300"));
    }

    #[test]
    fn newest_first_is_a_stable_numeric_sort() {
        let builds: Vec<String> =
            ["300", "1000", "200", "300"].iter().map(|b| (*b).to_owned()).collect();
        assert_eq!(newest_first(&builds), vec![1, 0, 3, 2]);
    }

    /// `SystemVersion(String)`: "26", "26.0" or "15.6.1"; missing parts are zero.
    #[test]
    fn system_version_parses_one_to_three_numbers() {
        assert_eq!(SystemVersion::parse("26"), Some(SystemVersion::new(26, 0, 0)));
        assert_eq!(SystemVersion::parse("26.0"), Some(SystemVersion::new(26, 0, 0)));
        assert_eq!(SystemVersion::parse(" 15.6.1\n"), Some(SystemVersion::new(15, 6, 1)));
        assert_eq!(SystemVersion::parse("26"), SystemVersion::parse("26.0.0"));
        for bad in ["", "26.", ".26", "1.2.3.4", "26.x", "-1", "26.0b", "２６"] {
            assert_eq!(SystemVersion::parse(bad), None, "{bad:?}");
        }
        // Swift's `Int(_:)` reads a sign.
        assert_eq!(SystemVersion::parse("+26.0"), Some(SystemVersion::new(26, 0, 0)));
        assert_eq!(SystemVersion::parse("-0.1"), Some(SystemVersion::new(0, 1, 0)));
    }

    #[test]
    fn system_version_orders_numerically_and_describes_itself() {
        assert!(SystemVersion::new(15, 6, 1) < SystemVersion::new(26, 0, 0));
        assert!(SystemVersion::new(15, 10, 0) > SystemVersion::new(15, 9, 9));
        assert_eq!(SystemVersion::new(26, 0, 0).description(), "26.0");
        assert_eq!(SystemVersion::new(15, 6, 1).description(), "15.6.1");
    }
}
