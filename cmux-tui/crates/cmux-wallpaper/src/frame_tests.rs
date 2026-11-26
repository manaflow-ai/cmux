use super::*;

const PRELUDE: &str = include_str!("prelude.wgsl");

#[test]
fn the_layout_matches_the_prelude() {
    // The struct's fields, in order, as the prelude declares them.
    let body = PRELUDE.split("struct Frame {").nth(1).unwrap().split('}').next().unwrap();
    let fields: Vec<String> = body
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(|l| l.trim_end_matches(',').replace(' ', ""))
        .collect();
    assert_eq!(
        fields,
        [
            "time:vec4<f32>",
            "size:vec4<f32>",
            "pointer:vec4<f32>",
            "presence:vec4<f32>",
            "ink:vec4<f32>",
            "paper:vec4<f32>",
            "accent:vec4<f32>",
            "params:array<vec4<f32>,2>",
            "activity:vec4<f32>",
            "grade:vec4<f32>",
            "trail:array<vec4<f32>,16>",
        ]
    );
    assert_eq!(FRAME_FLOATS, 108);
    assert_eq!(FRAME_BYTES, 432);
}

#[cfg(feature = "compile")]
#[test]
fn layout_by_naga_is_432_bytes() {
    let module = naga::front::wgsl::parse_str(PRELUDE).unwrap();
    let mut layouter = naga::proc::Layouter::default();
    layouter.update(module.to_ctx()).unwrap();
    let (handle, _) =
        module.types.iter().find(|(_, t)| t.name.as_deref() == Some("Frame")).unwrap();
    assert_eq!(layouter[handle].size, 432);
}

#[test]
fn packs_every_field_in_place() {
    let input = FrameInput {
        time: 1.0,
        delta: 2.0,
        frame_number: 3.0,
        still: true,
        width: 5.0,
        height: 6.0,
        backing_scale: 7.0,
        seed: 0.5,
        pointer_x: 9.0,
        pointer_y: 10.0,
        velocity_x: 11.0,
        velocity_y: 12.0,
        presence: 0.25,
        since_moved: 14.0,
        button_down: true,
        dark: false,
        ink: [0.1, 0.2, 0.3],
        paper: [0.4, 0.5, 0.6],
        accent: [0.7, 0.8, 0.9],
        params: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0],
        activity: 0.75,
        since_agent_event: 1.5,
        agent_events: 3.0,
        grade: 0.6,
        trail: std::array::from_fn(|r| {
            let r = f32::from(u8::try_from(r).unwrap());
            [100.0 + r, 200.0 + r, r * 0.05, 1.0]
        }),
    };
    let f = pack_frame(&input);
    assert_eq!(&f[0..4], &[1.0, 2.0, 3.0, 1.0]);
    assert_eq!(&f[4..8], &[5.0, 6.0, 7.0, 0.5]);
    assert_eq!(&f[8..12], &[9.0, 10.0, 11.0, 12.0]);
    assert_eq!(&f[12..16], &[0.25, 14.0, 1.0, 0.0]);
    assert_eq!(&f[16..20], &[0.1, 0.2, 0.3, 1.0]);
    assert_eq!(&f[20..24], &[0.4, 0.5, 0.6, 1.0]);
    assert_eq!(&f[24..28], &[0.7, 0.8, 0.9, 1.0]);
    assert_eq!(&f[28..36], &[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]);
    assert_eq!(&f[36..40], &[0.75, 1.5, 3.0, 0.0]);
    assert_eq!(&f[40..44], &[0.6, 0.0, 0.0, 0.0]);
    assert_eq!(&f[44..48], &[100.0, 200.0, 0.0, 1.0]);
    assert_eq!(&f[104..108], &[115.0, 215.0, 0.75, 1.0]);
    // No grade and no trail from the host: those rows are zeros.
    assert!(pack_frame(&FrameInput::default())[40..].iter().all(|v| *v == 0.0));
}

#[test]
fn nan_never_reaches_the_gpu() {
    let input = FrameInput {
        time: f32::NAN,
        presence: f32::INFINITY,
        ink: [f32::NAN; 3],
        grade: f32::NAN,
        trail: [[f32::NAN, f32::INFINITY, 0.0, 1.0]; TRAIL_POINTS],
        ..Default::default()
    };
    assert!(pack_frame(&input).iter().all(|v| v.is_finite()));
}

#[test]
fn the_grade_amount_is_clamped() {
    let at = |grade| pack_frame(&FrameInput { grade, ..Default::default() })[GRADE_START];
    assert_eq!(at(-1.0), 0.0);
    assert_eq!(at(0.25), 0.25);
    assert_eq!(at(7.0), 1.0);
    assert_eq!(at(f32::INFINITY), 0.0);
}

#[test]
fn srgb_matches_the_standard() {
    assert_eq!(srgb_to_linear(0.0), 0.0);
    assert!((srgb_to_linear(1.0) - 1.0).abs() < 1e-6);
    assert!((srgb_to_linear(0.5) - 0.214_041).abs() < 1e-4);
}

#[test]
fn a_burst_of_agent_output_counts_once_and_the_level_settles() {
    let mut a = ActivityState::default();
    assert!(a.settled(0.0));
    assert_eq!(a.since_event(5.0), MAX_SINCE_MOVED);
    a.event(10.0);
    // Twenty chunks of output within the gap: one counted event.
    for i in 1..20 {
        a.event(10.0 + f64::from(i) * 0.01);
    }
    assert_eq!(a.count, 1);
    assert!(a.level > 0.3 && a.level < 1.0, "{}", a.level);
    assert!(!a.settled(10.5));
    a.event(11.0);
    assert_eq!(a.count, 2);
    assert_eq!(a.since_event(11.5), 0.5);
    a.advance(11.0);
    a.advance(40.0);
    assert_eq!(a.level, 0.0);
    assert!(a.settled(40.0));
}

#[test]
fn the_agent_event_count_wraps() {
    let mut a = ActivityState::default();
    for i in 0..u32::from(AGENT_EVENT_WRAP) + 3 {
        a.event(f64::from(i));
    }
    assert_eq!(a.count, 3);
}

#[test]
fn velocity_follows_motion_and_decays() {
    let mut p = PointerState::default();
    p.moved(0.0, 0.0, 0.0);
    assert_eq!((p.vx, p.vy), (0.0, 0.0));
    for i in 1..=20 {
        p.moved(f32::from(u8::try_from(i).unwrap()) * 10.0, 0.0, f64::from(i) / 60.0);
    }
    // 10 px per 1/60 s = 600 px/s.
    assert!((p.vx - 600.0).abs() < 5.0, "{}", p.vx);
    p.advance(20.0 / 60.0);
    p.advance(3.0);
    assert_eq!((p.vx, p.vy), (0.0, 0.0));
}

#[test]
fn a_long_gap_does_not_make_a_jump() {
    let mut p = PointerState::default();
    p.moved(0.0, 0.0, 0.0);
    p.moved(500.0, 0.0, 5.0);
    assert_eq!(p.vx, 0.0);
}

#[test]
fn presence_eases_in_and_out() {
    let mut p = PointerState::default();
    p.advance(0.0);
    p.moved(1.0, 1.0, 0.0);
    p.advance(0.05);
    assert!(p.presence > 0.0 && p.presence < 1.0);
    assert!(!p.settled());
    p.advance(3.0);
    assert_eq!(p.presence, 1.0);
    assert!(p.settled());
    p.left();
    p.advance(3.1);
    assert!(p.presence < 1.0);
    p.advance(6.0);
    assert_eq!(p.presence, 0.0);
    assert_eq!(p.since_moved(6.0), 6.0);
    assert_eq!(PointerState::default().since_moved(1.0), MAX_SINCE_MOVED);
}

#[test]
fn bad_times_are_ignored() {
    let mut p = PointerState::default();
    p.moved(f32::NAN, 0.0, 0.0);
    p.moved(0.0, 0.0, f64::NAN);
    p.advance(f64::INFINITY);
    assert_eq!(p, PointerState::default());
}
