//! The appcast parse and what it offers this Mac. Ported from the Swift
//! `UpdateRingProbeTests` and `UpdateChannelCrossoverTests` (the feed and
//! selection half; which URL is fetched stays in the Swift prober), plus the
//! rules of the former `AppcastParser` and `AppcastSelector`.

mod updater_core_appcast {
    use cmux_updater_core::appcast::{AppcastItem, offered, parse};
    use cmux_updater_core::select::{Outcome, select};
    use cmux_updater_core::version::SystemVersion;
    use std::collections::BTreeSet;

    const RING_FEED: &str = r#"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
<item><title>stable</title><sparkle:version>200</sparkle:version><sparkle:channel>cmux-next-stable</sparkle:channel></item>
<item><title>nightly</title><sparkle:version>300</sparkle:version><sparkle:channel>cmux-next</sparkle:channel></item>
<item><title>canary</title><sparkle:version>400</sparkle:version><sparkle:channel>cmux-next-canary</sparkle:channel></item>
<item><title>dev</title><sparkle:version>500</sparkle:version><sparkle:channel>cmux-next-dev</sparkle:channel></item>
</channel></rss>"#;

    /// `UpdateRing.acceptedSparkleChannels`: each ring's tag and every slower ring's.
    fn ring(name: &str) -> BTreeSet<String> {
        let ladder = ["cmux-next-stable", "cmux-next", "cmux-next-canary", "cmux-next-dev"];
        let depth = match name {
            "stable" => 1,
            "nightly" => 2,
            "canary" => 3,
            _ => 4,
        };
        ladder.iter().take(depth).map(|tag| (*tag).to_owned()).collect()
    }

    fn tahoe() -> SystemVersion {
        SystemVersion::new(26, 0, 0)
    }

    fn version_of(items: &[AppcastItem], outcome: Outcome) -> Option<String> {
        match outcome {
            Outcome::UpdateAvailable { item } => items.get(item).map(|item| item.version.clone()),
            _ => None,
        }
    }

    #[test]
    fn parser_reads_each_items_sparkle_channel() {
        let items = parse(RING_FEED.as_bytes()).unwrap();
        let channels: Vec<Option<&str>> =
            items.iter().map(|item| item.sparkle_channel.as_deref()).collect();
        assert_eq!(
            channels,
            vec![
                Some("cmux-next-stable"),
                Some("cmux-next"),
                Some("cmux-next-canary"),
                Some("cmux-next-dev")
            ]
        );
        assert_eq!(items.first().and_then(|item| item.title.as_deref()), Some("stable"));
    }

    #[test]
    fn probe_offers_the_newest_item_of_the_ring_or_a_slower_one() {
        for (name, expected) in
            [("stable", "200"), ("nightly", "300"), ("canary", "400"), ("dev", "500")]
        {
            let items = offered(parse(RING_FEED.as_bytes()).unwrap(), Some(&ring(name)));
            let outcome = select(&items, "100", tahoe());
            assert_eq!(
                version_of(&items, outcome).as_deref(),
                Some(expected),
                "{name}: {outcome:?}"
            );
        }
    }

    #[test]
    fn untagged_items_are_offered_on_every_ring() {
        let item = AppcastItem::new("1");
        for name in ["stable", "nightly", "canary", "dev"] {
            assert!(item.is_offered(&ring(name)), "{name}");
        }
        let mut dev = AppcastItem::new("1");
        dev.sparkle_channel = Some("cmux-next-dev".to_owned());
        assert!(!dev.is_offered(&ring("canary")));
    }

    /// UpdateChannelCrossoverTests' feed: one item with a short version and an enclosure.
    #[test]
    fn a_feed_with_a_short_version_and_an_enclosure_offers_its_build() {
        let feed = r#"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title><item><sparkle:version>200</sparkle:version><sparkle:shortVersionString>0.1.0</sparkle:shortVersionString><enclosure url="https://example.com/update.dmg" /></item></channel></rss>"#;
        let items = offered(parse(feed.as_bytes()).unwrap(), Some(&BTreeSet::new()));
        assert_eq!(items.len(), 1);
        let item = items.first().unwrap();
        assert_eq!(item.version, "200");
        assert_eq!(item.display_version, "0.1.0");
        assert_eq!(item.download_url.as_deref(), Some("https://example.com/update.dmg"));
        assert_eq!(version_of(&items, select(&items, "100", tahoe())).as_deref(), Some("200"));
    }

    #[test]
    fn the_enclosure_can_carry_the_version_and_an_items_own_field_wins() {
        let feed = r#"<rss><channel>
<item><enclosure url="https://x/a.zip" sparkle:version="7" sparkle:shortVersionString="1.7"/></item>
<item><sparkle:version>9</sparkle:version><enclosure sparkle:version="8"/></item>
<item><title>no version</title></item>
</channel></rss>"#;
        let items = parse(feed.as_bytes()).unwrap();
        let versions: Vec<(&str, &str)> = items
            .iter()
            .map(|item| (item.version.as_str(), item.display_version.as_str()))
            .collect();
        assert_eq!(versions, vec![("7", "1.7"), ("9", "9")]);
    }

    #[test]
    fn delta_enclosures_are_skipped_and_marked() {
        let feed = r#"<rss><channel><item><sparkle:version>5</sparkle:version>
<enclosure url="https://x/full.zip"/>
<sparkle:deltas><enclosure url="https://x/delta.zip" sparkle:deltaFrom="4"/></sparkle:deltas>
</item><item><sparkle:version>6</sparkle:version><enclosure url="https://x/six.zip"/></item></channel></rss>"#;
        let items = parse(feed.as_bytes()).unwrap();
        assert_eq!(
            items.first().and_then(|item| item.download_url.as_deref()),
            Some("https://x/full.zip")
        );
        assert!(items.first().unwrap().lists_deltas);
        assert!(!items.get(1).unwrap().lists_deltas);
    }

    #[test]
    fn fields_are_trimmed_text_entities_and_cdata_and_dates_are_read() {
        let feed = "<rss><channel><item>\n<sparkle:version>\n  42 \n</sparkle:version>\n\
<description><![CDATA[New: a & b\n]]></description>\n\
<title>A &amp; B &#x2014; &lt;C&gt;</title>\n\
<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>\n\
<sparkle:maximumSystemVersion>27</sparkle:maximumSystemVersion>\n\
<sparkle:releaseNotesLink>https://x/notes</sparkle:releaseNotesLink>\n\
<sparkle:fullReleaseNotesLink>https://x/full</sparkle:fullReleaseNotesLink>\n\
<pubDate>Sat, 10 Oct 2026 03:05:21 +0000</pubDate>\n</item></channel></rss>";
        let items = parse(feed.as_bytes()).unwrap();
        let item = items.first().unwrap();
        assert_eq!(item.version, "42");
        assert_eq!(item.item_description.as_deref(), Some("New: a & b"));
        assert_eq!(item.title.as_deref(), Some("A & B \u{2014} <C>"));
        assert_eq!(item.minimum_system_version, Some(SystemVersion::new(26, 0, 0)));
        assert_eq!(item.maximum_system_version, Some(SystemVersion::new(27, 0, 0)));
        assert_eq!(item.release_notes_url.as_deref(), Some("https://x/full"));
        assert_eq!(item.date, Some(1_791_601_521.0));
    }

    #[test]
    fn a_date_in_another_offset_and_a_bad_date() {
        let feed = |date: &str| {
            format!(
                "<rss><channel><item><sparkle:version>1</sparkle:version><pubDate>{date}</pubDate></item></channel></rss>"
            )
        };
        let date = |text: &str| parse(feed(text).as_bytes()).unwrap().first().unwrap().date;
        assert_eq!(date("Fri, 09 Oct 2026 20:05:21 -0700"), Some(1_791_601_521.0));
        assert_eq!(date("sat, 10 oct 2026 03:05:21 +0000"), Some(1_791_601_521.0));
        assert_eq!(date("Sat, 31 Feb 2026 03:05:21 +0000"), None);
        assert_eq!(date("2026-10-10T03:05:21Z"), None);
    }

    /// An element's text is what follows its last child, as XMLParser reports it.
    #[test]
    fn text_resets_at_every_tag() {
        let feed = "<rss><channel><item><sparkle:version>1</sparkle:version><title>a<b/>c</title></item></channel></rss>";
        assert_eq!(parse(feed.as_bytes()).unwrap().first().unwrap().title.as_deref(), Some("c"));
    }

    #[test]
    fn a_document_without_a_channel_or_not_well_formed_is_an_error() {
        assert_eq!(parse(b"<rss></rss>").unwrap_err().message, "appcast has no <channel>");
        for bad in [
            "",
            "<rss><channel></rss>",
            "<rss><channel>",
            "<rss><channel/></rss><rss/>",
            "<rss><channel/>&nbsp;</rss>",
            "<rss><channel>AT&T</channel></rss>",
            "text<rss><channel/></rss>",
            "<rss><channel a=\"1\" a=\"2\"/></rss>",
        ] {
            assert!(parse(bad.as_bytes()).is_err(), "{bad:?} parsed");
        }
        assert!(parse(&[0xff, 0xfe, 0x3c]).is_err());
    }

    #[test]
    fn comments_a_declaration_and_a_byte_order_mark_are_fine() {
        let feed = "\u{feff}<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- feed -->\n<rss><channel><item><sparkle:version>3<!-- x -->4</sparkle:version></item></channel></rss>\n";
        assert_eq!(parse(feed.as_bytes()).unwrap().first().unwrap().version, "34");
    }

    fn item(version: &str, minimum: Option<SystemVersion>) -> AppcastItem {
        let mut item = AppcastItem::new(version);
        item.minimum_system_version = minimum;
        item
    }

    /// A newer build that needs a newer macOS (a cmux-next build seen from macOS 15).
    #[test]
    fn a_newer_build_for_a_newer_macos_is_named_with_its_floor() {
        let sequoia = SystemVersion::new(15, 6, 0);
        let items = vec![item("300", Some(tahoe())), item("200", None)];
        assert_eq!(select(&items, "100", sequoia), Outcome::UpdateAvailable { item: 1 });
        assert_eq!(
            select(&items, "200", sequoia),
            Outcome::RequiresNewerSystem { item: 0, required: tahoe() }
        );
        assert_eq!(select(&items, "300", tahoe()), Outcome::UpToDate { latest: Some(0) });
    }

    #[test]
    fn up_to_date_names_the_newest_compatible_item_or_none() {
        let mut capped = AppcastItem::new("400");
        capped.maximum_system_version = Some(SystemVersion::new(15, 0, 0));
        let items = vec![item("100", None), capped];
        // 400 is newer but only for macOS 15 or older; it names this Mac's own system.
        assert_eq!(
            select(&items, "100", tahoe()),
            Outcome::RequiresNewerSystem { item: 1, required: tahoe() }
        );
        assert_eq!(select(&[], "100", tahoe()), Outcome::UpToDate { latest: None });
        assert_eq!(
            select(&[item("90", None)], "100", tahoe()),
            Outcome::UpToDate { latest: Some(0) }
        );
    }

    /// Swift's `max(by:)` keeps the first of equal versions.
    #[test]
    fn the_first_of_equal_newest_items_wins() {
        let items = vec![item("2", None), item("2.0", None), item("1", None)];
        assert_eq!(select(&items, "1", tahoe()), Outcome::UpdateAvailable { item: 0 });
    }

    #[test]
    fn supports_reads_both_bounds() {
        let mut bounded = item("1", Some(SystemVersion::new(15, 0, 0)));
        bounded.maximum_system_version = Some(SystemVersion::new(26, 0, 0));
        assert!(bounded.supports(SystemVersion::new(15, 0, 0)));
        assert!(bounded.supports(SystemVersion::new(26, 0, 0)));
        assert!(!bounded.supports(SystemVersion::new(14, 7, 0)));
        assert!(!bounded.supports(SystemVersion::new(26, 0, 1)));
    }
}
