use super::*;

#[test]
fn a_failing_widget_waits_longer_each_time_up_to_five_minutes() {
    let waits: Vec<u64> = (1..=11).map(|n| retry_delay(n).as_secs()).collect();
    assert_eq!(waits, [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300]);
    assert_eq!(retry_delay(u32::MAX), RETRY_MAX);
}

fn spec(options: Value) -> Spec {
    Spec::from_entry(&json!({ "export": "r", "options": options }))
}

#[test]
fn a_spec_defaults_to_one_small_size_in_both_places_with_no_tick() {
    let s = Spec::from_entry(&json!({ "export": "r" }));
    assert_eq!(s.sizes, vec![Size::Small]);
    assert_eq!(s.default_size, Size::Small);
    assert_eq!(s.places, vec![Place::Newtab, Place::Sidebar]);
    assert_eq!(s.every, None);
}

#[test]
fn a_large_only_widget_never_goes_in_the_sidebar() {
    let s = spec(json!({ "sizes": ["large"] }));
    assert_eq!(s.places, vec![Place::Newtab]);
    let both = spec(json!({ "sizes": ["small", "large"], "defaultSize": "large" }));
    assert_eq!(both.default_in(Place::Sidebar), Some(Size::Small));
    assert_eq!(both.default_in(Place::Newtab), Some(Size::Large));
    assert_eq!(both.sizes_in(Place::Sidebar), vec![Size::Small]);
}

#[test]
fn refresh_is_raised_to_the_floor_and_capped_at_a_day() {
    assert_eq!(spec(json!({ "refresh": { "everySeconds": 1 } })).every, Some(60));
    assert_eq!(spec(json!({ "refresh": { "everySeconds": 900 } })).every, Some(900));
    assert_eq!(spec(json!({ "refresh": { "everySeconds": 999_999 } })).every, Some(86_400));
}

#[test]
fn ticks_fall_on_wall_clock_boundaries() {
    // A whole minute (and a whole quarter hour): 1_794_000_600_000 ms since the epoch.
    let base: u64 = 1_794_000_600_000;
    // 42.5 s past the minute: the next minute is 17.5 s away.
    assert_eq!(next_tick_delay(base + 42_500, 60), Duration::from_millis(17_500));
    assert_eq!(
        next_tick_delay(base, 60),
        Duration::from_secs(60),
        "on the boundary: a full minute"
    );
    assert_eq!(next_tick_delay(base + 1, 900), Duration::from_millis(899_999));
}

fn specs(app: &str) -> Option<Spec> {
    match app {
        "local/clock" => Some(spec(json!({ "sizes": ["small", "medium", "large"] }))),
        "local/todo" => Some(spec(json!({ "sizes": ["medium", "large"], "places": ["newtab"] }))),
        _ => None,
    }
}

fn add(layout: &mut Layout, place: Place, app: &str, size: Option<&str>) -> Result<(), String> {
    apply(
        layout,
        place,
        Edit::Add { app: app.into(), size: size.map(str::to_string), before: None },
        specs,
    )
}

#[test]
fn add_remove_resize_and_move_keep_one_ordered_layout_per_place() {
    let mut layout = Layout::default();
    add(&mut layout, Place::Newtab, "local/clock", None).unwrap();
    add(&mut layout, Place::Newtab, "local/todo", None).unwrap();
    add(&mut layout, Place::Sidebar, "local/clock", Some("medium")).unwrap();
    let ids =
        |l: &Layout, p: Place| l.place(p).iter().map(|i| i.instance.clone()).collect::<Vec<_>>();
    assert_eq!(ids(&layout, Place::Newtab), ["w1", "w2"]);
    assert_eq!(ids(&layout, Place::Sidebar), ["w3"]);
    assert_eq!(layout.newtab.get(1).map(|i| i.size), Some(Size::Medium), "todo's default");
    assert_eq!(layout.revision, 3);

    let edit = |l: &mut Layout, e: Edit| apply(l, Place::Newtab, e, specs);
    edit(&mut layout, Edit::Move { instance: "w2".into(), before: Some("w1".into()) }).unwrap();
    assert_eq!(ids(&layout, Place::Newtab), ["w2", "w1"]);
    edit(&mut layout, Edit::Move { instance: "w2".into(), before: None }).unwrap();
    assert_eq!(ids(&layout, Place::Newtab), ["w1", "w2"]);
    edit(&mut layout, Edit::Resize { instance: "w1".into(), size: "large".into() }).unwrap();
    assert_eq!(layout.newtab.first().map(|i| i.size), Some(Size::Large));
    edit(
        &mut layout,
        Edit::Configure { instance: "w1".into(), settings: json!({ "zone": "Asia/Tokyo" }) },
    )
    .unwrap();
    assert_eq!(
        layout.newtab.first().map(|i| i.settings.clone()),
        Some(json!({ "zone": "Asia/Tokyo" }).as_object().cloned().unwrap())
    );
    edit(&mut layout, Edit::Remove { instance: "w1".into() }).unwrap();
    assert_eq!(ids(&layout, Place::Newtab), ["w2"]);
    // Ids are never reused.
    add(&mut layout, Place::Newtab, "local/clock", None).unwrap();
    assert_eq!(ids(&layout, Place::Newtab), ["w2", "w4"]);
}

#[test]
fn an_edit_the_widget_does_not_offer_is_refused_and_changes_nothing() {
    let mut layout = Layout::default();
    add(&mut layout, Place::Sidebar, "local/clock", None).unwrap();
    let before = layout.clone();
    assert!(
        add(&mut layout, Place::Sidebar, "local/clock", Some("large")).is_err(),
        "sidebar takes no large"
    );
    assert!(add(&mut layout, Place::Sidebar, "local/todo", None).is_err(), "todo is New Tab only");
    assert!(
        add(&mut layout, Place::Newtab, "local/todo", Some("small")).is_err(),
        "todo draws no small"
    );
    assert!(add(&mut layout, Place::Newtab, "local/gone", None).is_err(), "not shown: not placed");
    let side = |l: &mut Layout, e: Edit| apply(l, Place::Sidebar, e, specs);
    assert!(
        side(&mut layout, Edit::Resize { instance: "w1".into(), size: "large".into() }).is_err()
    );
    assert!(
        side(&mut layout, Edit::Move { instance: "w1".into(), before: Some("w9".into()) }).is_err()
    );
    assert!(
        side(&mut layout, Edit::Configure { instance: "w1".into(), settings: json!([1]) }).is_err()
    );
    let big = json!({ "x": "a".repeat(MAX_SETTINGS_BYTES) });
    assert!(side(&mut layout, Edit::Configure { instance: "w1".into(), settings: big }).is_err());
    assert_eq!(layout, before);
}

#[test]
fn a_place_holds_at_most_its_limit() {
    let mut layout = Layout::default();
    for _ in 0..MAX_PER_PLACE {
        add(&mut layout, Place::Newtab, "local/clock", None).unwrap();
    }
    assert!(add(&mut layout, Place::Newtab, "local/clock", None).is_err());
}

#[test]
fn the_mount_context_is_built_here_and_refuses_what_the_widget_does_not_offer() {
    let s = spec(
        json!({ "sizes": ["small", "medium"], "refresh": { "everySeconds": 30 }, "places": ["sidebar"] }),
    );
    let mut layout = Layout::default();
    layout.sidebar.push(Item {
        instance: "w7".into(),
        app: "local/clock".into(),
        size: Size::Medium,
        settings: json!({ "zone": "UTC" }).as_object().cloned().unwrap(),
    });
    let (context, widget) =
        mount_context("local/clock", &s, &json!({ "place": "sidebar", "size": "medium", "instance": "w7", "surface": "x", "settings": { "evil": 1 }, "locale": "fr-FR", "timeZone": "Europe/Paris" }), &layout)
            .unwrap();
    assert_eq!(
        context,
        json!({ "surface": "widget", "place": "sidebar", "size": "medium", "instance": "w7",
                "settings": { "zone": "UTC" }, "refresh": { "everySeconds": 60 },
                "locale": "fr-FR", "timeZone": "Europe/Paris" })
    );
    assert_eq!(widget.every, Some(60));
    assert!(widget.visible);
    for bad in [
        json!({ "place": "newtab", "size": "small", "instance": "w7" }),
        json!({ "place": "sidebar", "size": "large", "instance": "w7" }),
        json!({ "place": "sidebar", "size": "small" }),
        json!({ "place": "dock", "size": "small", "instance": "w7" }),
    ] {
        assert!(mount_context("local/clock", &s, &bad, &layout).is_err(), "{bad}");
    }
    // Another app mounting with this tile's instance id does not get its settings.
    let (other, _) = mount_context(
        "local/spy",
        &s,
        &json!({ "place": "sidebar", "size": "medium", "instance": "w7" }),
        &layout,
    )
    .unwrap();
    assert_eq!(other["settings"], json!({}));
    // A malformed locale or zone falls back rather than reaching the widget.
    let (fallback, _) = mount_context(
        "local/clock",
        &s,
        &json!({ "place": "sidebar", "instance": "w7", "locale": "fr FR<", "timeZone": "../etc/passwd" }),
        &layout,
    )
    .unwrap();
    assert_eq!(fallback["locale"], "en");
    assert_ne!(fallback["timeZone"], "../etc/passwd");
    assert!(is_zone_name(fallback["timeZone"].as_str().unwrap()));
    assert!(is_zone_name("America/Argentina/Buenos_Aires") && is_zone_name("Etc/GMT+9"));
    assert!(!is_zone_name("/etc/x") && !is_zone_name("a//b") && !is_zone_name(""));
}

#[test]
fn a_layout_file_that_does_not_read_is_kept_aside_not_replaced() {
    let dir = std::env::temp_dir().join(format!("cmux-widgets-bad-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(LAYOUT_FILE), b"{ not json").unwrap();
    assert_eq!(read_layout(&dir).unwrap(), Layout::default());
    assert!(!dir.join(LAYOUT_FILE).exists());
    let kept: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().starts_with("apps-widgets-layout.json.bad-"))
        .collect();
    assert_eq!(kept.len(), 1);
    assert_eq!(std::fs::read(kept[0].path()).unwrap(), b"{ not json");
    std::fs::remove_dir_all(&dir).unwrap();
}
