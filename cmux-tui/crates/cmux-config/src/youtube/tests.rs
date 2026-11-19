use super::*;

const ID: &str = "dQw4w9WgXcQ";

fn id_of(text: &str) -> String {
    YouTubeWallpaper::from_input(text).unwrap_or_else(|error| panic!("{text}: {error}")).id()
}

#[test]
fn every_address_form_names_the_same_video() {
    for text in [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "HTTPS://WWW.YOUTUBE.COM/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&feature=share",
        "https://www.youtube.com/watch?feature=youtu.be&v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=2",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abcDEF",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ?rel=0",
        "https://www.youtube.com/live/dQw4w9WgXcQ?si=x",
        "https://www.youtube.com/v/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "https://youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "https://www.youtube.com:443/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com./watch?v=dQw4w9WgXcQ",
        "//www.youtube.com/watch?v=dQw4w9WgXcQ",
        "www.youtube.com/watch?v=dQw4w9WgXcQ",
        "youtube.com/watch?v=dQw4w9WgXcQ",
        "youtu.be/dQw4w9WgXcQ",
        "m.youtube.com/shorts/dQw4w9WgXcQ/",
        "  https://youtu.be/dQw4w9WgXcQ  ",
        "youtube:dQw4w9WgXcQ",
        "YouTube:dQw4w9WgXcQ",
    ] {
        assert_eq!(id_of(text), "youtube:dQw4w9WgXcQ", "{text}");
    }
}

#[test]
fn start_and_end_come_from_t_start_and_end_in_every_time_form() {
    let cases = [
        ("https://youtu.be/dQw4w9WgXcQ?t=90", "youtube:dQw4w9WgXcQ?start=90"),
        ("https://youtu.be/dQw4w9WgXcQ?t=90s", "youtube:dQw4w9WgXcQ?start=90"),
        ("https://youtu.be/dQw4w9WgXcQ?t=1m30s", "youtube:dQw4w9WgXcQ?start=90"),
        ("https://youtu.be/dQw4w9WgXcQ?t=1h2m3s", "youtube:dQw4w9WgXcQ?start=3723"),
        ("https://youtu.be/dQw4w9WgXcQ?t=1h", "youtube:dQw4w9WgXcQ?start=3600"),
        ("https://youtu.be/dQw4w9WgXcQ?t=2m", "youtube:dQw4w9WgXcQ?start=120"),
        ("https://youtu.be/dQw4w9WgXcQ?t=1H2M3S", "youtube:dQw4w9WgXcQ?start=3723"),
        ("https://youtu.be/dQw4w9WgXcQ?t=1:30", "youtube:dQw4w9WgXcQ?start=90"),
        ("https://youtu.be/dQw4w9WgXcQ?t=1:02:03", "youtube:dQw4w9WgXcQ?start=3723"),
        ("https://youtu.be/dQw4w9WgXcQ#t=45", "youtube:dQw4w9WgXcQ?start=45"),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "youtube:dQw4w9WgXcQ?start=42"),
        (
            "https://www.youtube.com/embed/dQw4w9WgXcQ?start=10&end=20",
            "youtube:dQw4w9WgXcQ?start=10&end=20",
        ),
        ("https://www.youtube.com/embed/dQw4w9WgXcQ?end=1m", "youtube:dQw4w9WgXcQ?end=60"),
        // `start` wins over `t`, the query over the fragment.
        ("https://youtu.be/dQw4w9WgXcQ?t=5&start=7#t=9", "youtube:dQw4w9WgXcQ?start=7"),
        // A start of 0 is the default and is left out.
        ("https://youtu.be/dQw4w9WgXcQ?t=0", "youtube:dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ?t=0s", "youtube:dQw4w9WgXcQ"),
    ];
    for (text, id) in cases {
        assert_eq!(id_of(text), id, "{text}");
    }
}

#[test]
fn a_youtube_id_reads_its_parameters_in_any_order_and_writes_them_canonically() {
    let cases = [
        (
            "youtube:dQw4w9WgXcQ?quality=720&end=20&start=10",
            "youtube:dQw4w9WgXcQ?start=10&end=20&quality=720",
        ),
        ("youtube:dQw4w9WgXcQ?start=0&quality=1080", "youtube:dQw4w9WgXcQ"),
        ("youtube:dQw4w9WgXcQ?quality=2160p", "youtube:dQw4w9WgXcQ?quality=2160"),
        ("youtube:dQw4w9WgXcQ?t=1m30s", "youtube:dQw4w9WgXcQ?start=90"),
        ("youtube:dQw4w9WgXcQ?end=86400", "youtube:dQw4w9WgXcQ?end=86400"),
        ("youtube:dQw4w9WgXcQ?", "youtube:dQw4w9WgXcQ"),
        ("youtube:dQw4w9WgXcQ?start=5&", "youtube:dQw4w9WgXcQ?start=5"),
        ("youtube:a-b_c-d_e-f?quality=360", "youtube:a-b_c-d_e-f?quality=360"),
    ];
    for (text, id) in cases {
        assert_eq!(id_of(text), id, "{text}");
    }
}

#[test]
fn only_the_canonical_form_is_a_stored_id() {
    let pattern = regex::Regex::new(ID_PATTERN).expect("pattern");
    for good in [
        "youtube:dQw4w9WgXcQ",
        "youtube:dQw4w9WgXcQ?start=90",
        "youtube:dQw4w9WgXcQ?end=60",
        "youtube:dQw4w9WgXcQ?start=10&end=20&quality=720",
        "youtube:dQw4w9WgXcQ?start=10&quality=2160",
        "youtube:dQw4w9WgXcQ?quality=360",
        "youtube:dQw4w9WgXcQ?start=86399",
    ] {
        assert!(is_canonical_id(good), "{good}");
        assert!(pattern.is_match(good), "the JSON Schema pattern takes {good}");
    }
    for bad in [
        "youtube:",
        "youtube:dQw4w9WgXc",
        "youtube:dQw4w9WgXcQQ",
        "youtube:dQw4w9WgXc!",
        "YouTube:dQw4w9WgXcQ",
        "youtube:dQw4w9WgXcQ?start=0",
        "youtube:dQw4w9WgXcQ?quality=1080",
        "youtube:dQw4w9WgXcQ?end=20&start=10",
        "youtube:dQw4w9WgXcQ?start=90s",
        "youtube:dQw4w9WgXcQ?start=20&end=10",
        "youtube:dQw4w9WgXcQ?start=10&end=10",
        "youtube:dQw4w9WgXcQ?end=86401",
        "youtube:dQw4w9WgXcQ?start=86400",
        "youtube:dQw4w9WgXcQ?quality=1000",
        "youtube:dQw4w9WgXcQ?quality=720p",
        "youtube:dQw4w9WgXcQ?",
        "youtube:dQw4w9WgXcQ?loop=1",
        "youtube:dQw4w9WgXcQ|youtube:dQw4w9WgXcQ",
        " youtube:dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "dQw4w9WgXcQ",
    ] {
        assert!(!is_canonical_id(bad), "{bad}");
    }
}

#[test]
fn the_json_schema_pattern_refuses_the_non_canonical_shapes() {
    let pattern = regex::Regex::new(ID_PATTERN).expect("pattern");
    for bad in [
        "youtube:dQw4w9WgXcQ?start=0",
        "youtube:dQw4w9WgXcQ?quality=1080",
        "youtube:dQw4w9WgXcQ?end=20&start=10",
        "youtube:dQw4w9WgXcQ?",
        "youtube:short",
        "youtube:dQw4w9WgXcQ|x",
    ] {
        assert!(!pattern.is_match(bad), "{bad}");
    }
}

#[test]
fn playlists_channels_and_other_sites_are_refused_with_what_to_paste() {
    let cases = [
        ("https://www.youtube.com/playlist?list=PL123", YouTubeError::Playlist),
        ("https://www.youtube.com/watch?list=PL123", YouTubeError::Playlist),
        ("https://www.youtube.com/embed/videoseries?list=PL123", YouTubeError::Playlist),
        ("https://music.youtube.com/playlist?list=OLAK5", YouTubeError::Playlist),
        ("https://www.youtube.com/@SomeChannel", YouTubeError::Channel),
        ("https://www.youtube.com/@SomeChannel/live", YouTubeError::Channel),
        ("https://www.youtube.com/channel/UC1234", YouTubeError::Channel),
        ("https://www.youtube.com/c/Name", YouTubeError::Channel),
        ("https://www.youtube.com/user/name", YouTubeError::Channel),
        ("https://www.youtube.com/", YouTubeError::NoVideo),
        ("https://www.youtube.com/results?search_query=rain", YouTubeError::NoVideo),
        ("https://www.youtube.com/watch", YouTubeError::NoVideo),
        ("https://www.youtube.com/watch?v=", YouTubeError::NoVideo),
        ("https://youtu.be/", YouTubeError::NoVideo),
        ("https://vimeo.com/123456", YouTubeError::OtherSite("vimeo.com".into())),
        (
            "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
            YouTubeError::OtherSite("notyoutube.com".into()),
        ),
        (
            "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
            YouTubeError::OtherSite("youtube.com.evil.example".into()),
        ),
        (
            "https://youtube.com@evil.example/watch?v=dQw4w9WgXcQ",
            YouTubeError::OtherSite("evil.example".into()),
        ),
        ("https://youtu.be/short", YouTubeError::BadVideoId("short".into())),
        (
            "https://www.youtube.com/watch?v=dQw4w9WgXcQxx",
            YouTubeError::BadVideoId("dQw4w9WgXcQxx".into()),
        ),
        ("~/Movies/rain.mp4", YouTubeError::NotYouTube),
        ("/Users/me/rain.mov", YouTubeError::NotYouTube),
        ("file:/Users/me/rain.mov", YouTubeError::NotYouTube),
        ("munch-scream", YouTubeError::NotYouTube),
        ("", YouTubeError::NotYouTube),
        ("youtube:dQw4w9WgXcQ?loop=1", YouTubeError::UnknownParameter("loop".into())),
        ("youtube:dQw4w9WgXcQ?quality=999", YouTubeError::BadQuality("999".into())),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=abc",
            YouTubeError::BadTime { name: "start", value: "abc".into() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=",
            YouTubeError::BadTime { name: "start", value: String::new() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=-5",
            YouTubeError::BadTime { name: "start", value: "-5".into() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=1.5",
            YouTubeError::BadTime { name: "start", value: "1.5".into() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=30s1m",
            YouTubeError::BadTime { name: "start", value: "30s1m".into() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=1m1m",
            YouTubeError::BadTime { name: "start", value: "1m1m".into() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=1:5",
            YouTubeError::BadTime { name: "start", value: "1:5".into() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=1:60",
            YouTubeError::BadTime { name: "start", value: "1:60".into() },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=25h",
            YouTubeError::TimeTooLate { name: "start", seconds: 90_000 },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?t=99999999999999999999999",
            YouTubeError::TimeTooLate { name: "start", seconds: u64::MAX },
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?start=20&end=10",
            YouTubeError::EndNotAfterStart { start: 20, end: 10 },
        ),
        ("https://youtu.be/dQw4w9WgXcQ?end=0", YouTubeError::EndNotAfterStart { start: 0, end: 0 }),
    ];
    for (text, error) in cases {
        assert_eq!(YouTubeWallpaper::from_input(text), Err(error), "{text}");
    }
    // Every refusal says what to do instead.
    assert!(YouTubeError::Playlist.to_string().contains("one of its videos"));
    assert!(YouTubeError::Channel.to_string().contains("one of its videos"));
    assert!(YouTubeError::OtherSite("vimeo.com".into()).to_string().contains("not YouTube"));
}

#[test]
fn a_bare_video_id_is_read_only_where_asked() {
    assert_eq!(YouTubeWallpaper::from_input(ID), Err(YouTubeError::NotYouTube));
    assert_eq!(
        YouTubeWallpaper::from_input_or_video_id(ID).map(|w| w.id()),
        Ok("youtube:dQw4w9WgXcQ".to_owned())
    );
    assert_eq!(
        YouTubeWallpaper::from_input_or_video_id("https://youtu.be/dQw4w9WgXcQ?t=3")
            .map(|w| w.id()),
        Ok("youtube:dQw4w9WgXcQ?start=3".to_owned())
    );
    assert!(YouTubeWallpaper::from_input_or_video_id("dQw4w9WgXc").is_err());
    // An 11-letter word with no capital or digit is a word, not a video.
    assert!(YouTubeWallpaper::from_input_or_video_id("not-a-thing").is_err());
    assert!(!looks_like_video_id("sunset-glow"));
    assert!(looks_like_video_id("a-b_c-d_e-F"));
}

#[test]
fn normalize_rewrites_youtube_and_leaves_everything_else() {
    assert_eq!(
        normalize("https://youtu.be/dQw4w9WgXcQ?t=90").as_deref(),
        Some("youtube:dQw4w9WgXcQ?start=90")
    );
    assert_eq!(normalize("youtube:dQw4w9WgXcQ?start=0").as_deref(), Some("youtube:dQw4w9WgXcQ"));
    assert_eq!(normalize("youtube:dQw4w9WgXcQ").as_deref(), Some("youtube:dQw4w9WgXcQ"));
    for left in [
        "file:/Users/me/rain.mov",
        "munch-scream",
        "none",
        "desktop",
        ID,
        "https://vimeo.com/123",
        // A YouTube address that is no wallpaper stays as typed, so the row refuses it by name.
        "https://www.youtube.com/playlist?list=PL1",
    ] {
        assert_eq!(normalize(left), None, "{left}");
    }
    assert!(claims_youtube("https://www.youtube.com/playlist?list=PL1"));
    assert!(claims_youtube("youtube:bad"));
    assert!(!claims_youtube("https://vimeo.com/123"));
    assert!(!claims_youtube("/tmp/youtube.com/x.mp4"));
}

#[test]
fn check_bounds_the_times_and_quality() {
    let mut wallpaper = YouTubeWallpaper::new(ID).expect("id");
    assert_eq!(wallpaper.check(), Ok(()));
    wallpaper.start = 10;
    wallpaper.end = Some(10);
    assert_eq!(wallpaper.check(), Err(YouTubeError::EndNotAfterStart { start: 10, end: 10 }));
    wallpaper.end = Some(MAX_SECONDS);
    assert_eq!(wallpaper.check(), Ok(()));
    wallpaper.quality = 999;
    assert_eq!(wallpaper.check(), Err(YouTubeError::BadQuality("999".into())));
    wallpaper.quality = 480;
    assert_eq!(wallpaper.id(), "youtube:dQw4w9WgXcQ?start=10&end=86400&quality=480");
    assert!(!wallpaper.id().contains('|'));
}

#[test]
fn quality_reads_pixels_with_or_without_p() {
    assert_eq!(parse_quality("720"), Ok(720));
    assert_eq!(parse_quality("720p"), Ok(720));
    assert_eq!(parse_quality("1440P"), Ok(1440));
    for bad in ["", "p", "4k", "+720", "721", "720pp"] {
        assert!(parse_quality(bad).is_err(), "{bad}");
    }
}
