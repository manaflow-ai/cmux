use super::*;

const BAD: [f64; 6] = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1e300, 0., 1e300];

fn finite(o: &CmuxGooOutline) -> bool {
    o.p.iter().all(|p| p.x.is_finite() && p.y.is_finite())
}

fn blob() -> CmuxGooBlob {
    CmuxGooBlob {
        left: 10.,
        right: 170.,
        top: 6.,
        baseline: 36.,
        corner_radius: 8.,
        feet_radius: 8.,
        skips_leading: false,
    }
}

#[test]
fn goo_ffi_is_null_safe() {
    let null_track = std::ptr::null::<CmuxGooTrack>();
    let null_blob = std::ptr::null::<CmuxGooBlob>();
    let null_tuning = std::ptr::null::<CmuxGooTuning>();
    let mut out = CmuxGooOutline::default();
    let mut key = [0.; 4];
    let mut outs = [CmuxGooOutline::default(); 4];
    let mut d = 7.;
    let track =
        CmuxGooTrack { x0: 0., v0: 0., target: 10., start: 0., spring: CmuxGooSpring::default() };
    // SAFETY: every pointer is null or valid for the call.
    unsafe {
        cmux_goo_track_state(null_track, 0., std::ptr::null_mut(), std::ptr::null_mut());
        cmux_goo_track_state(&track, 0.1, std::ptr::null_mut(), std::ptr::null_mut());
        assert_eq!(cmux_goo_track_rest_time(null_track, 0.5), 0.);
        let r = cmux_goo_track_retarget(null_track, 1., 5., CmuxGooSpring::default());
        assert!(r.x0 == 5. && r.target == 5.);
        cmux_goo_blob_outline(null_blob, &mut out);
        cmux_goo_blob_outline(&blob(), std::ptr::null_mut());
        let b = blob();
        assert_eq!(
            cmux_goo_plan(
                0,
                null_blob,
                &b,
                &track,
                &track,
                null_tuning,
                120.,
                false,
                outs.as_mut_ptr(),
                key.as_mut_ptr(),
                4,
                &mut d
            ),
            0
        );
        assert_eq!(d, 0.);
        assert_eq!(
            cmux_goo_plan(
                0,
                &b,
                &b,
                &track,
                &track,
                null_tuning,
                120.,
                false,
                std::ptr::null_mut(),
                key.as_mut_ptr(),
                4,
                std::ptr::null_mut()
            ),
            0
        );
        let n = cmux_goo_plan(
            0,
            &b,
            &b,
            &track,
            &track,
            null_tuning,
            120.,
            false,
            outs.as_mut_ptr(),
            key.as_mut_ptr(),
            4,
            &mut d,
        );
        assert!((1..=4).contains(&n));
        cmux_goo_drag_neck(
            null_blob,
            0.,
            0.,
            10.,
            10.,
            true,
            null_tuning,
            &mut out,
            std::ptr::null_mut(),
        );
        cmux_goo_drag_neck(
            &b,
            0.,
            0.,
            10.,
            10.,
            true,
            null_tuning,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        cmux_goo_neck(null_blob, 0., 0., 10., 10., 4., null_tuning, &mut out);
        cmux_goo_neck(&b, 0., 0., 10., 10., 4., null_tuning, std::ptr::null_mut());
    }
}

#[test]
fn goo_ffi_is_garbage_safe() {
    let mut outs = [CmuxGooOutline::default(); 8];
    let mut key = [0.; 8];
    for &a in &BAD {
        for &b in &BAD {
            let spring = CmuxGooSpring { response: a, damping_fraction: b };
            let tuning = CmuxGooTuning {
                select: spring,
                open: spring,
                close: spring,
                reorder: spring,
                snap: spring,
                absorb: spring,
                wobble: spring,
                stretch: a,
                lean: b,
                feet_scale: a,
                k: b,
                break_distance: a,
                capture_distance: b,
                wobble_amplitude: a,
            };
            let track = CmuxGooTrack { x0: a, v0: b, target: b, start: a, spring };
            let gb = CmuxGooBlob {
                left: a,
                right: b,
                top: a,
                baseline: b,
                corner_radius: a,
                feet_radius: b,
                skips_leading: true,
            };
            let mut out = CmuxGooOutline::default();
            let (mut x, mut v, mut d, mut att) = (0., 0., 0., false);
            // SAFETY: every pointer is valid for the call.
            unsafe {
                cmux_goo_track_state(&track, a, &mut x, &mut v);
                assert!(x.is_finite() && v.is_finite());
                let r = cmux_goo_track_retarget(&track, b, a, spring);
                assert!(
                    r.x0.is_finite()
                        && r.v0.is_finite()
                        && r.target.is_finite()
                        && r.start.is_finite()
                );
                assert!(cmux_goo_track_rest_time(&track, b).is_finite());
                cmux_goo_blob_outline(&gb, &mut out);
                assert!(finite(&out));
                for event in [0, 3, 6, 7, u32::MAX] {
                    let n = cmux_goo_plan(
                        event,
                        &gb,
                        &gb,
                        &track,
                        &track,
                        &tuning,
                        a,
                        false,
                        outs.as_mut_ptr(),
                        key.as_mut_ptr(),
                        8,
                        &mut d,
                    );
                    assert!(n <= 8 && d.is_finite());
                    assert!(
                        outs.iter().take(n).all(finite)
                            && key.iter().take(n).all(|k| k.is_finite())
                    );
                }
                cmux_goo_drag_neck(&gb, a, b, a, b, true, &tuning, &mut out, &mut att);
                assert!(finite(&out));
                cmux_goo_neck(&gb, a, b, a, b, a, &tuning, &mut out);
                assert!(finite(&out));
            }
        }
    }
    for level in [0, 1, 2, 3, u32::MAX] {
        let t = cmux_goo_tuning_for_level(level);
        assert!(t.stretch.is_finite() && t.select.response > 0.);
    }
    assert_eq!(cmux_goo_tuning_for_level(9), cmux_goo_tuning_for_level(0));
}

#[test]
fn goo_ffi_plan_caps_at_capacity_and_ends_at_rest() {
    let tuning = cmux_goo_tuning_for_level(2);
    let from = blob();
    let to = CmuxGooBlob { left: 300., right: 460., ..blob() };
    let left = CmuxGooTrack { x0: 10., v0: 0., target: 300., start: 1., spring: tuning.select };
    let right = CmuxGooTrack { x0: 170., v0: 0., target: 460., start: 1., spring: tuning.select };
    let mut outs = [CmuxGooOutline::default(); 3];
    let mut key = [0.; 3];
    let mut d = 0.;
    let mut rest = CmuxGooOutline::default();
    // SAFETY: every pointer is valid for the call.
    let n = unsafe {
        cmux_goo_blob_outline(&to, &mut rest);
        cmux_goo_plan(
            0,
            &from,
            &to,
            &left,
            &right,
            &tuning,
            120.,
            false,
            outs.as_mut_ptr(),
            key.as_mut_ptr(),
            3,
            &mut d,
        )
    };
    assert_eq!(n, 3);
    assert!(d > 0.);
    assert_eq!(outs[2], rest);
    assert_eq!(key, [0., 0.5, 1.]);
    // SAFETY: as above.
    let n = unsafe {
        cmux_goo_plan(
            0,
            &from,
            &to,
            &left,
            &right,
            &tuning,
            120.,
            true,
            outs.as_mut_ptr(),
            key.as_mut_ptr(),
            3,
            &mut d,
        )
    };
    assert_eq!((n, d), (1, 0.));
    assert_eq!(outs[0], rest);
}
