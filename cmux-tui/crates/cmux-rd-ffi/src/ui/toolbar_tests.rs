//! Parity with `MacScreenToolbarTests`/`MacScreenStatsLineTests` and the toolbar's `apply()` rules.

use serde_json::json;

use super::*;

fn call(op: &str, args: Value) -> Value {
    handle(op, &args).expect("known op").expect("ok")
}

fn line(a: StatsLineArgs) -> String {
    english(&stats_line(&a))
}

#[test]
fn stats_line_reads_like_swift() {
    let a = StatsLineArgs {
        path: "Direct".into(),
        kbps: Some(148_000.0),
        fps: 120.0,
        target_fps: Some(120),
        latency_ms: Some(3.0),
        encoding: "-".into(),
        ..Default::default()
    };
    assert_eq!(line(a.clone()), "Direct · 148 Mbps · 120/120 fps · 3 ms");
    let ultra = StatsLineArgs { profile: Some("ultra".into()), ..a };
    assert_eq!(line(ultra), "Direct · Ultra · 148 Mbps · 120/120 fps · 3 ms");
    let codec = StatsLineArgs {
        path: "Direct".into(),
        fps: 118.4,
        target_fps: Some(120),
        latency_ms: Some(4.0),
        encoding: "H264 HW".into(),
        frame_width: 3024.0,
        frame_height: 1964.0,
        ..Default::default()
    };
    assert_eq!(line(codec), "Direct · 118/120 fps · 4 ms · H264 HW · 3024×1964");
    let relay = StatsLineArgs {
        path: "Relay".into(),
        fps: 59.6,
        encoding: "-".into(),
        ..Default::default()
    };
    assert_eq!(line(relay), "Relay · 60 fps");
}

#[test]
fn measured_fps_rounds_half_away_but_untargeted_rounds_half_even() {
    // `Int(fps.rounded())` vs `String(format: "%.0f")`.
    let a = StatsLineArgs {
        path: "P".into(),
        fps: 2.5,
        target_fps: Some(60),
        encoding: "-".into(),
        ..Default::default()
    };
    assert_eq!(line(a), "P · 3/60 fps");
    let b =
        StatsLineArgs { path: "P".into(), fps: 2.5, encoding: "-".into(), ..Default::default() };
    assert_eq!(line(b), "P · 2 fps");
    let nan = StatsLineArgs {
        path: "P".into(),
        fps: f64::NAN,
        target_fps: Some(60),
        encoding: "-".into(),
        ..Default::default()
    };
    assert_eq!(line(nan), "P · 0/60 fps");
}

#[test]
fn rate_text_bands() {
    assert_eq!(rate_text(0.0), "0 kbps");
    assert_eq!(rate_text(f64::INFINITY), "0 kbps");
    assert_eq!(rate_text(850.0), "850 kbps");
    assert_eq!(rate_text(2500.0), "2.5 Mbps");
    assert_eq!(rate_text(148_000.0), "148 Mbps");
}

#[test]
fn pill_line_matches_swift() {
    let p = |latency: Option<f64>, kbps: Option<f64>, profile: Option<&str>| {
        english(&pill_line(&PillArgs {
            latency_ms: latency,
            host_kbps: kbps,
            profile: profile.map(Into::into),
        }))
    };
    assert_eq!(p(Some(3.0), Some(148_000.0), None), "148 Mbps · 3 ms");
    assert_eq!(p(Some(3.0), None, None), "3 ms");
    assert_eq!(p(Some(3.0), Some(148_000.0), Some("ultra")), "Ultra · 148 Mbps · 3 ms");
    assert_eq!(p(None, None, None), "— ms");
}

#[test]
fn stats_lines_short_and_widest() {
    let v = call(
        "statsLines",
        json!({"path": "Direct", "kbps": 5000.0, "fps": 59.0, "targetFps": 60, "latencyMs": 12.0,
               "encoding": "HEVC", "frameWidth": 1920.0, "frameHeight": 1080.0, "rate": true}),
    );
    let text = |k: &str| {
        v[k].as_array()
            .unwrap()
            .iter()
            .map(|p| p["text"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
            .join(" · ")
    };
    assert_eq!(text("full"), "Direct · 5.0 Mbps · 59/60 fps · 12 ms · HEVC · 1920×1080");
    assert_eq!(text("short"), "Direct · 5.0 Mbps · 59/60 fps · 12 ms");
    assert_eq!(text("widest"), "Direct · 888 Mbps · 888/888 fps · 888 ms · HEVC · 1920×1080");
    let no_rate =
        call("statsLines", json!({"path": "Relay", "kbps": 5000.0, "fps": 30.0, "encoding": "-"}));
    assert_eq!(no_rate["full"].as_array().unwrap().len(), 2);
}

#[test]
fn bar_and_look() {
    assert_eq!(
        call("bar", json!({"placement": "floating", "layout": "bar", "bar": "icons"})),
        json!("icons")
    );
    assert_eq!(
        call("bar", json!({"placement": "floating", "layout": "pill", "bar": "icons"})),
        json!("stacked")
    );
    assert_eq!(
        call("bar", json!({"placement": "topBar", "layout": "bar", "bar": "row"})),
        json!("stacked")
    );
    let hidden = |strip, auto, pill, shown, live| {
        hidden_by_look(&HiddenArgs {
            status_strip: strip,
            auto_hidden: auto,
            pill,
            shows_session_controls: shown,
            live,
        })
    };
    assert!(hidden(true, false, false, true, true));
    assert!(hidden(false, true, false, true, true));
    assert!(!hidden(false, false, false, false, false));
    assert!(hidden(false, false, true, true, false));
    assert!(!hidden(false, false, true, true, true));
}

#[test]
fn title_pieces() {
    let t = title(&TitleArgs {
        name: "Studio".into(),
        linked_display_gone: false,
        run_name: Some("build".into()),
    });
    assert_eq!(english(&t), "Studio · build");
    let gone = title(&TitleArgs {
        name: "Studio".into(),
        linked_display_gone: true,
        run_name: Some("build".into()),
    });
    assert_eq!(gone[1].key, Some("macScreen.run.displayGone"));
}

#[test]
fn status_ink_rules() {
    let ink = |hub: Option<&str>, open, session: Option<&str>, reconnecting| {
        status_ink(&StatusArgs {
            hub_phase: hub.map(Into::into),
            gate_open: open,
            session_phase: session.map(Into::into),
            reconnecting,
        })
    };
    assert_eq!(ink(Some("waitingForApproval"), true, Some("connected"), false), "attention");
    assert_eq!(ink(Some("revoked"), true, Some("connected"), false), "danger");
    assert_eq!(ink(Some("idle"), true, Some("connected"), false), "tertiary");
    assert_eq!(ink(Some("streaming"), true, Some("connected"), false), "success");
    assert_eq!(ink(Some("streamFailed"), true, Some("failed"), false), "danger");
    assert_eq!(ink(None, false, Some("connected"), false), "tertiary");
    assert_eq!(ink(None, true, None, false), "tertiary");
    assert_eq!(ink(None, true, Some("connected"), true), "attention");
    assert_eq!(ink(None, true, Some("connecting"), false), "attention");
    assert_eq!(ink(None, true, Some("ended"), false), "tertiary");
}

#[test]
fn stats_mode_order() {
    let m = |show, pill, quiet, inline| {
        stats_mode(&StatsModeArgs { show_stats: show, pill, quiet_outage: quiet, inline })
    };
    assert_eq!(m(true, false, true, true), "lines");
    assert_eq!(m(true, true, true, false), "reconnecting");
    assert_eq!(m(false, false, false, true), "pill");
    assert_eq!(m(false, false, false, false), "latency");
}

#[test]
fn strained() {
    let s = |loss, fps, target| {
        is_strained(&StrainArgs { loss_percent: loss, fps, target_fps: target })
    };
    assert!(s(Some(6.0), 60.0, None));
    assert!(!s(Some(5.0), 60.0, Some(60)));
    assert!(s(None, 29.0, Some(60)));
    assert!(!s(None, 0.0, Some(60)));
    assert!(!s(None, 30.0, Some(60)));
}

fn chip(bar: &str, readout: &str, live: bool, kbps: Option<f64>, loss: Option<f64>) -> Value {
    call(
        "qualityChip",
        json!({"bar": bar, "readout": readout, "live": live, "hostKbps": kbps, "quality": "auto", "lossPercent": loss}),
    )
}

#[test]
fn quality_chip_rules() {
    let c = chip("row", "inline", true, Some(148_000.0), None);
    assert_eq!(c["title"][0]["text"], "148 Mbps");
    assert_eq!(c["ink"], "secondary");
    assert_eq!(chip("controls", "inline", true, Some(148_000.0), Some(9.0))["ink"], "attention");
    // Icons never rate; a one-row bar idles empty, the stacked bar names the quality.
    assert_eq!(chip("icons", "chip", true, Some(1.0), None)["title"], json!([]));
    assert_eq!(chip("row", "inline", false, Some(1.0), None)["title"], json!([]));
    assert_eq!(
        chip("stacked", "inline", true, Some(1.0), None)["title"][0]["key"],
        "macScreen.quality.auto"
    );
    assert_eq!(chip("stacked", "chip", true, Some(900.0), None)["title"][0]["text"], "900 kbps");
    assert!(
        handle(
            "qualityChip",
            &json!({"bar": "stacked", "readout": "x", "live": false, "quality": "nope"})
        )
        .unwrap()
        .is_err()
    );
}

#[test]
fn titles_and_keys() {
    assert_eq!(bitrate_title(None).key, Some("macScreen.customize.bitrateAuto"));
    assert_eq!(bitrate_title(Some(25_000)).english(), "25 Mbps");
    assert_eq!(display_title(0).english(), "Display 1");
    assert_eq!(access(true).title.key, Some("macScreen.scope.view"));
    assert_eq!(access(false).symbol, "cursorarrow");
    for q in QUALITIES {
        assert!(quality_title(q).is_ok());
    }
}

fn controls_args(bar: Bar) -> ControlsArgs {
    ControlsArgs {
        controls_shown: true,
        pill: false,
        bar,
        live: true,
        ended: false,
        view_only: false,
        can_send_keys: true,
        display_count: 2,
        scope_segments: false,
        capture_keyboard: true,
        has_session: true,
        recording: Recording::default(),
    }
}

#[test]
fn controls_stacked_live() {
    let c = controls(&controls_args(Bar::Stacked));
    assert!(c.stats_slot && c.hint_slot && c.segments_show_titles && !c.dot_tip_is_title);
    assert!(!c.access_hidden && c.segments_hidden && c.access_enabled);
    assert!(!c.display_hidden && !c.send_keys_hidden && !c.refresh_hidden && c.refresh_enabled);
    assert!(c.connect_hidden && !c.disconnect_hidden && c.disconnect_glyph_hidden);
    assert_eq!(c.send_keys_tip.key, Some("macScreen.toolbar.sendKeys"));
    assert_eq!(c.record_tip.key, Some("macScreen.record.title"));
    assert!(!c.record_enabled);
}

#[test]
fn controls_variants() {
    let icons = controls(&ControlsArgs { scope_segments: true, ..controls_args(Bar::Icons) });
    assert!(!icons.segments_show_titles && icons.access_hidden && !icons.segments_hidden);
    assert!(icons.disconnect_hidden && !icons.disconnect_glyph_hidden && icons.send_keys_hidden);
    let ended =
        controls(&ControlsArgs { ended: true, live: false, ..controls_args(Bar::Controls) });
    assert!(
        !ended.connect_hidden
            && ended.disconnect_hidden
            && ended.dot_tip_is_title
            && !ended.stats_slot
    );
    let pill = controls(&ControlsArgs {
        pill: true,
        view_only: true,
        can_send_keys: false,
        ..controls_args(Bar::Stacked)
    });
    assert!(pill.full_screen_hidden && pill.display_hidden && pill.send_keys_hidden);
    assert_eq!(pill.send_keys_tip.key, Some("macScreen.toolbar.sendKeysViewOnly"));
    assert_eq!(pill.send_keys_ink, "tertiary");
    let off = controls(&ControlsArgs { controls_shown: false, ..controls_args(Bar::Stacked) });
    assert!(
        off.access_hidden
            && off.more_hidden
            && off.quality_hidden
            && off.record_hidden
            && !off.access_enabled
    );
    let recording = Recording { is_recording: true, failed: true, ..Recording::default() };
    let rec = controls(&ControlsArgs { recording, ..controls_args(Bar::Stacked) });
    assert!(rec.record_enabled && rec.record_active);
    assert_eq!((rec.record_symbol, rec.record_ink), ("record.circle.fill", "danger"));
    assert_eq!(rec.record_tip.key, Some("macScreen.record.failed"));
    let last = Recording { has_last_file: true, ..Recording::default() };
    assert!(
        controls(&ControlsArgs { live: false, recording: last, ..controls_args(Bar::Stacked) })
            .record_enabled
    );
}

#[test]
fn menus() {
    let ids = |rows: &[MenuRow]| rows.iter().map(|r| r.id.clone()).collect::<Vec<_>>();
    let more = more_menu(&MoreArgs {
        display_count: 2,
        can_send_keys: false,
        live: true,
        record_hidden: true,
        pill: true,
    });
    assert_eq!(
        ids(&more),
        ["displays", "sendKeys", "refresh", "record", "separator", "fullScreen"]
    );
    assert!(!more[1].enabled && more[2].enabled);
    let plain = more_menu(&MoreArgs {
        display_count: 1,
        can_send_keys: true,
        live: false,
        record_hidden: false,
        pill: false,
    });
    assert_eq!(ids(&plain), ["sendKeys", "refresh"]);
    assert!(!plain[1].enabled);

    let rec = record_menu(&RecordArgs {
        is_recording: false,
        can_record: true,
        live: false,
        has_file: false,
        has_last_file: true,
    });
    assert_eq!(rec[0].title.as_ref().unwrap().key, Some("macScreen.record.start"));
    assert!(!rec[0].enabled && rec[1].enabled);

    let head = |readout: &str, live, connected| {
        quality_menu_head(&QualityHeadArgs { readout: readout.into(), live, connected })
    };
    assert_eq!(head("chip", true, true), "readout");
    assert_eq!(head("chip", false, true), "stats");
    assert_eq!(head("inline", true, false), "none");

    let d = display_menu(&DisplayMenuArgs {
        displays: vec![
            Size { width: 1920.0, height: 1080.0 },
            Size { width: 3024.0, height: 1964.0 },
        ],
        current: 1,
    });
    assert_eq!(d[1].title.as_ref().unwrap().english(), "Display 2 (3024 × 1964)");
    assert!(!d[0].checked && d[1].checked);

    let q = call(
        "qualityMenu",
        json!({"quality": "high", "showStats": true, "maxKbps": 50000, "maxKbpsChoices": [null, 25000, 50000], "showCursorInStream": false}),
    );
    let rows = q.as_array().unwrap();
    assert_eq!(rows[4]["id"], "quality:high");
    assert_eq!(rows[4]["checked"], true);
    assert_eq!(rows[6]["checked"], true);
    let caps = rows[9]["submenu"].as_array().unwrap();
    assert_eq!(caps[0]["id"], "cap:auto");
    assert_eq!(caps[2]["checked"], true);
    assert_eq!(rows[10]["id"], "showCursor");
}

fn space() -> Space {
    Space { space2: 8.0, space3: 12.0, space6: 24.0 }
}

#[test]
fn widths() {
    assert_eq!(
        control_width(&ControlWidthArgs { text_widths: vec![60.2, 80.1], space: space() }),
        113.0
    );
    // 9 controls' worth of padding plus each width and gap.
    assert_eq!(
        expanded_width(&ExpandedArgs { widths: vec![100.0, 50.0], space: space() }),
        432.0 + 166.0
    );
    let titles = control_titles(&ControlTitlesArgs {
        control: "quality".into(),
        bar: Bar::Stacked,
        quality_has_title: false,
        profile: None,
    });
    assert_eq!(titles.unwrap().len(), 5);
    assert!(
        control_titles(&ControlTitlesArgs {
            control: "quality".into(),
            bar: Bar::Row,
            quality_has_title: false,
            profile: None
        })
        .is_none()
    );
    let rate = control_titles(&ControlTitlesArgs {
        control: "quality".into(),
        bar: Bar::Row,
        quality_has_title: true,
        profile: Some("ultra".into()),
    });
    assert_eq!(english(&rate.unwrap()[0]), "Ultra · 888 Mbps");
    assert!(
        control_titles(&ControlTitlesArgs {
            control: "record".into(),
            bar: Bar::Row,
            quality_has_title: true,
            profile: None
        })
        .is_none()
    );
}

#[test]
fn header_widths() {
    let h = |kind: &str, bar: Bar| {
        header_width(&HeaderArgs {
            kind: kind.into(),
            bar,
            space: space(),
            body_point_size: 13.0,
            icon_width: 16.0,
            name_width: 500.0,
            stats_slot: true,
            stats_room: 100.0,
            hint_slot: false,
            hint_width: 50.0,
            controls: vec![40.0, 60.0],
            expanded_width: 900.0,
        })
    };
    // lead 40, icon 16+8, name min(500, 208)+8, stats 108; controls 116.
    assert_eq!(h("pill", Bar::Stacked), 40.0 + 24.0 + 216.0 + 108.0 + 116.0);
    assert_eq!(h("oneRow", Bar::Controls), 156.0);
    // header 388 past the 384 allowance.
    assert_eq!(h("floating", Bar::Stacked), 904.0);
}

#[test]
fn arrange_by_width() {
    let a = |width: f64, pill: bool, bar: Bar| {
        arrange(&ArrangeArgs {
            width,
            pill,
            bar,
            controls_shown: true,
            expanded_width: 900.0,
            one_row_width: 600.0,
            display_count: 2,
            space: space(),
            hidden: [("connect".to_string(), true), ("disconnectGlyph".to_string(), true)]
                .into_iter()
                .collect(),
        })
    };
    assert_eq!(
        a(880.0, false, Bar::Stacked).order,
        [
            "scope",
            "display",
            "quality",
            "sendKeys",
            "record",
            "refresh",
            "fullScreen",
            "disconnect"
        ]
    );
    // 900 - 192 = 708: compact below it.
    assert_eq!(
        a(700.0, false, Bar::Stacked).order,
        ["scope", "quality", "fullScreen", "more", "disconnect"]
    );
    assert_eq!(
        a(700.0, false, Bar::Row).order,
        ["scope", "display", "quality", "fullScreen", "more", "disconnect"]
    );
    assert_eq!(
        a(500.0, false, Bar::Row).order,
        ["scope", "quality", "fullScreen", "more", "disconnect"]
    );
    assert_eq!(
        a(500.0, true, Bar::Stacked).order,
        ["access", "quality", "record", "more", "disconnect"]
    );
}

#[test]
fn height_wraps_stacked_rows() {
    let h = |width: f64, bar: Bar| {
        height(&HeightArgs {
            width,
            row_height: 40.0,
            controls_shown: true,
            expanded_width: 900.0,
            pill: false,
            bar,
            widths: vec![100.0, 100.0, 100.0, 100.0],
            space: space(),
        })
    };
    assert_eq!(h(1000.0, Bar::Stacked), 40.0);
    assert_eq!(h(500.0, Bar::Row), 40.0);
    // 476 available: 3 fit (324 + 100 > 476 wraps the 4th? 108*3=324, 324+100=424 fits; all 4 fit).
    assert_eq!(h(500.0, Bar::Stacked), 80.0);
    // 276 available: two per row.
    assert_eq!(h(300.0, Bar::Stacked), 120.0);
}

fn layout_args(width: f64, bar: Bar) -> LayoutArgs {
    LayoutArgs {
        width,
        row_height: 40.0,
        pill: false,
        bar,
        controls_shown: true,
        expanded_width: 900.0,
        one_row_width: 600.0,
        space: space(),
        icon_width: 16.0,
        name_width: 120.0,
        stats_width: None,
        stats_full_width: Some(300.0),
        stats_short_width: Some(150.0),
        stats_slot: true,
        starter_slot: false,
        starter_width: 0.0,
        hint_slot: true,
        hint_width: 80.0,
        controls: vec![100.0, 100.0],
    }
}

#[test]
fn layout_wide_and_stacked() {
    let wide = layout(&layout_args(1200.0, Bar::Stacked));
    assert!(!wide.stacked && !wide.icon_hidden && !wide.hint_hidden);
    assert_eq!(wide.stats_line, Some("full"));
    assert_eq!(wide.dot, Slot { x: 12.0, y: 16.0, width: 8.0 });
    assert_eq!(wide.icon, Some(Slot { x: 28.0, y: 0.0, width: 16.0 }));
    // Controls end at the right padding.
    assert_eq!(wide.controls[1].x + wide.controls[1].width, 1188.0);
    assert_eq!(wide.controls[0].y, 0.0);

    let stacked = layout(&layout_args(800.0, Bar::Stacked));
    assert!(stacked.stacked && !stacked.compact);
    assert_eq!(stacked.controls[0], Slot { x: 12.0, y: 40.0, width: 100.0 });

    let compact = layout(&LayoutArgs {
        controls: vec![100.0, 100.0, 100.0],
        ..layout_args(300.0, Bar::Stacked)
    });
    assert!(compact.compact && compact.icon_hidden);
    assert_eq!(compact.stats_line, Some("short"));
    assert!(compact.hint_hidden);
    // 12 + 108 + 108 + 100 passes 288: the third wraps.
    assert_eq!(
        (compact.controls[1].y, compact.controls[2].y, compact.controls[2].x),
        (40.0, 80.0, 12.0)
    );

    let bare = layout(&layout_args(1200.0, Bar::Controls));
    assert!(bare.icon_hidden && bare.name_hidden && bare.stats_hidden && bare.name.is_none());

    let narrow_row = layout(&layout_args(500.0, Bar::Row));
    assert!(narrow_row.icon_hidden && !narrow_row.stacked);
}

#[test]
fn dispatch_unknown_op() {
    assert!(handle("nope", &json!({})).is_none());
    assert!(handle("bar", &json!({})).unwrap().is_err());
}
