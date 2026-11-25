use super::*;

fn gib(value: f64) -> u64 {
    (value * GIB as f64).round() as u64
}

fn report(total: f64, used: f64) -> DiskReport {
    DiskReport {
        total_bytes: Some(gib(total)),
        used_bytes: Some(gib(used)),
        free_bytes: Some(gib(total - used)),
        ..DiskReport::default()
    }
}

fn split(total: f64, system: f64, project: f64, caches: f64) -> DiskReport {
    DiskReport {
        system_bytes: Some(gib(system)),
        project_bytes: Some(gib(project)),
        caches_bytes: Some(gib(caches)),
        ..report(total, system + project + caches)
    }
}

fn kinds(view: &DiskView) -> Vec<SegmentKind> {
    view.segments.iter().map(|s| s.kind).collect()
}

fn widths_sum(view: &DiskView) -> u32 {
    view.segments.iter().map(|s| s.width).sum()
}

#[test]
fn the_rfd_example_reads_used_over_allocated_and_the_free_rest() {
    let view = view(Some(gib(20.0)), &split(20.0, 5.3, 6.2, 1.7)).unwrap();
    assert_eq!(view.label, "13.2 / 20 GB");
    assert_eq!(view.text, "13.2 of 20 GB, 6.8 free");
    assert_eq!(view.state, DiskState::Ok);
    assert_eq!(
        kinds(&view),
        [SegmentKind::System, SegmentKind::Project, SegmentKind::Caches, SegmentKind::Free]
    );
    assert_eq!(view.segments.iter().map(|s| s.gb).collect::<Vec<_>>(), [5.3, 6.2, 1.7, 6.8]);
    assert_eq!(view.segments.iter().map(|s| s.width).collect::<Vec<_>>(), [265, 310, 85, 340]);
}

#[test]
fn a_fresh_machine() {
    let view = view(Some(gib(20.0)), &split(20.0, 5.2, 0.1, 0.0)).unwrap();
    assert_eq!(view.label, "5.3 / 20 GB");
    assert_eq!(view.text, "5.3 of 20 GB, 14.7 free");
    assert_eq!(view.state, DiskState::Ok);
    // An empty cache takes no width; a tiny project still shows as a sliver.
    let caches = &view.segments[2];
    assert_eq!((caches.kind, caches.width), (SegmentKind::Caches, 0));
    assert_eq!(view.segments[1].width, MIN_SEGMENT_PARTS);
    assert_eq!(widths_sum(&view), BAR_PARTS);
}

#[test]
fn a_day_in_drops_the_trailing_zero() {
    let view = view(Some(gib(20.0)), &split(20.0, 5.3, 4.5, 3.2)).unwrap();
    assert_eq!(view.label, "13 / 20 GB");
    assert_eq!(view.text, "13 of 20 GB, 7 free");
    assert_eq!(view.state, DiskState::Ok);
}

#[test]
fn almost_full_under_two_gib_free() {
    let view = view(Some(gib(20.0)), &split(20.0, 5.4, 9.0, 4.2)).unwrap();
    assert_eq!(view.label, "18.6 / 20 GB");
    assert_eq!(view.text, "18.6 of 20 GB, 1.4 free");
    assert_eq!(view.state, DiskState::AlmostFull);

    let total = gib(20.0);
    let at = |free: u64| {
        let r = DiskReport {
            total_bytes: Some(total),
            used_bytes: Some(total - free),
            free_bytes: Some(free),
            ..DiskReport::default()
        };
        super::view(None, &r).unwrap().state
    };
    assert_eq!(at(ALMOST_FULL_FREE_BYTES), DiskState::Ok);
    assert_eq!(at(ALMOST_FULL_FREE_BYTES - 1), DiskState::AlmostFull);
}

#[test]
fn just_grown_the_guest_total_wins_over_the_record() {
    // The record still says 20; the guest already sees the grown 24.
    let view = view(Some(gib(20.0)), &split(24.0, 5.4, 10.0, 5.1)).unwrap();
    assert_eq!(view.label, "20.5 / 24 GB");
    assert_eq!(view.text, "20.5 of 24 GB, 3.5 free");
    assert_eq!(view.total_gb, 24.0);
    assert_eq!(view.state, DiskState::Ok);
}

#[test]
fn numbers_absent_show_the_allocation_alone() {
    let view = view(Some(gib(20.0)), &DiskReport::default()).unwrap();
    assert_eq!(view.state, DiskState::Allocated);
    assert_eq!(view.label, "20 GB");
    assert_eq!(view.text, "20 GB");
    assert!(view.segments.is_empty());
    assert_eq!((view.used_gb, view.free_gb), (None, None));
    assert_eq!(super::view(None, &DiskReport::default()), None);
    assert_eq!(super::view(Some(0), &DiskReport::default()), None);
}

#[test]
fn totals_without_a_split_draw_one_used_segment() {
    let view = view(None, &report(20.0, 13.2)).unwrap();
    assert_eq!(kinds(&view), [SegmentKind::Used, SegmentKind::Free]);
    assert_eq!(view.segments.iter().map(|s| s.width).collect::<Vec<_>>(), [660, 340]);
    // Used alone: free is the rest.
    let used_only = DiskReport { used_bytes: Some(gib(13.2)), ..DiskReport::default() };
    assert_eq!(super::view(Some(gib(20.0)), &used_only).unwrap().text, "13.2 of 20 GB, 6.8 free");
    // Free alone: used is the rest.
    let free_only = DiskReport { free_bytes: Some(gib(6.8)), ..DiskReport::default() };
    assert_eq!(super::view(Some(gib(20.0)), &free_only).unwrap().label, "13.2 / 20 GB");
}

#[test]
fn use_the_split_leaves_out_counts_as_system() {
    let r = DiskReport {
        project_bytes: Some(gib(6.0)),
        caches_bytes: Some(gib(2.0)),
        ..report(20.0, 13.0)
    };
    let view = view(None, &r).unwrap();
    assert_eq!(view.segments[0].gb, 5.0);
}

#[test]
fn a_split_past_the_used_total_is_scaled_down() {
    let r = DiskReport {
        system_bytes: Some(gib(10.0)),
        project_bytes: Some(gib(10.0)),
        caches_bytes: Some(gib(10.0)),
        ..report(20.0, 15.0)
    };
    let view = view(None, &r).unwrap();
    assert_eq!(view.segments.iter().map(|s| s.gb).collect::<Vec<_>>(), [5.0, 5.0, 5.0, 5.0]);
    assert_eq!(widths_sum(&view), BAR_PARTS);
}

#[test]
fn used_past_the_total_is_a_full_bar() {
    let r = DiskReport {
        total_bytes: Some(gib(20.0)),
        used_bytes: Some(gib(21.0)),
        ..DiskReport::default()
    };
    let view = view(None, &r).unwrap();
    assert_eq!(view.label, "20 / 20 GB");
    assert_eq!(view.state, DiskState::AlmostFull);
    assert_eq!(view.segments.last().map(|s| (s.kind, s.width)), Some((SegmentKind::Free, 0)));
}

#[test]
fn widths_always_sum_to_the_bar() {
    for used in [0.0, 0.01, 1.0, 3.33, 9.99, 12.345, 19.99, 20.0] {
        for caches in [0.0, 0.001, 0.5] {
            let r = DiskReport {
                project_bytes: Some(gib(used / 3.0)),
                caches_bytes: Some(gib(caches)),
                ..report(20.0, used)
            };
            let view = view(None, &r).unwrap();
            assert_eq!(widths_sum(&view), BAR_PARTS, "used {used} caches {caches}");
            for s in &view.segments {
                assert!(s.bytes == 0 || s.width >= MIN_SEGMENT_PARTS, "{s:?} at used {used}");
            }
        }
    }
}

#[test]
fn mib_values_read_as_bytes_and_bad_ones_as_absent() {
    let r = DiskReport::from_mib(Some(20_480.0), Some(13_516.8), None).with_split_mib(
        None,
        Some(6_348.8),
        Some(1_740.8),
    );
    assert_eq!(view(None, &r).unwrap().text, "13.2 of 20 GB, 6.8 free");
    assert_eq!(mib(Some(f64::NAN)), None);
    assert_eq!(mib(Some(-1.0)), None);
}

#[test]
fn the_view_serializes_in_snake_case() {
    let json = serde_json::to_value(view(Some(gib(20.0)), &report(20.0, 18.6)).unwrap()).unwrap();
    assert_eq!(json["state"], "almost_full");
    assert_eq!(json["segments"][0]["kind"], "used");
    assert_eq!(json["label"], "18.6 / 20 GB");
}

#[test]
fn a_platform_disk_health_reads_as_a_report() {
    // cmux-platform's names (MiB) and the guest's own (`acpmux machine load`, bytes) read alike.
    let platform = serde_json::json!({"total_mb": 20480, "used_mb": 13516.8, "free_mb": 6963.2,
        "system_mb": 5427.2, "project_mb": 6348.8, "caches_mb": 1740.8, "floor_mb": 2048,
        "observed_at": 1, "top_users": []});
    let guest = serde_json::json!({"rootTotalBytes": gib(20.0), "rootUsedBytes": gib(13.2),
        "rootFreeBytes": gib(6.8), "diskSplit": {"systemBytes": gib(5.3), "projectBytes": gib(6.2),
        "cachesBytes": gib(1.7)}});
    for value in [platform, guest] {
        let report = DiskReport::from_health(&value).unwrap();
        let view = view(Some(gib(20.0)), &report).unwrap();
        assert_eq!(view.label, "13.2 / 20 GB", "{value}");
        let kinds: Vec<SegmentKind> = view.segments.iter().map(|s| s.kind).collect();
        assert_eq!(
            kinds,
            [SegmentKind::System, SegmentKind::Project, SegmentKind::Caches, SegmentKind::Free]
        );
    }
    // Nothing it knows: no report.
    assert_eq!(DiskReport::from_health(&serde_json::json!({"state": "unknown"})), None);
    assert_eq!(DiskReport::from_health(&serde_json::json!(null)), None);
}
