use super::*;

fn read_rate(enc: &OpenH264, option: ENCODER_OPTION, layer: LAYER_NUM) -> i32 {
    let mut rate = SBitrateInfo { iLayer: layer, iBitrate: 0 };
    let get = enc.vtbl().GetOption.expect("GetOption");
    // SAFETY: a live encoder and a writable payload of the option's documented type.
    let status = unsafe { get(enc.enc, option, (&mut rate as *mut SBitrateInfo).cast::<c_void>()) };
    assert_eq!(status, 0);
    rate.iBitrate
}

#[test]
fn bitrate_retarget_updates_the_active_layer_ceiling_in_both_directions() {
    let cfg =
        EncCfg { width: 640, height: 480, fps: 60, kbps: 8000, threads: 1, screen_content: true };
    let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
    for kbps in [16_000, 4_000, 12_000, 200_003, 2_000] {
        enc.set_bitrate(kbps);
        for layer in [SPATIAL_LAYER_ALL, SPATIAL_LAYER_0] {
            assert_eq!(read_rate(&enc, ENCODER_OPTION_BITRATE, layer), (kbps * 1000) as f32 as i32);
            assert_eq!(
                read_rate(&enc, ENCODER_OPTION_MAX_BITRATE, layer),
                (kbps * 1000) as f32 as i32
            );
        }
        assert_eq!(enc.kbps(), kbps);
    }
}
#[test]
fn bitrate_retarget_clamps_oversized_requests_without_corrupting_codec_state() {
    let cfg =
        EncCfg { width: 640, height: 480, fps: 60, kbps: 8000, threads: 1, screen_content: true };
    let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
    for (requested, expected) in [(u32::MAX, 288_000), (8_000, 8_000), (0, 100)] {
        enc.set_bitrate(requested);
        assert_eq!(enc.kbps(), expected);
        for layer in [SPATIAL_LAYER_ALL, SPATIAL_LAYER_0] {
            assert_eq!(read_rate(&enc, ENCODER_OPTION_BITRATE, layer), (expected * 1000) as i32);
            assert_eq!(
                read_rate(&enc, ENCODER_OPTION_MAX_BITRATE, layer),
                (expected * 1000) as i32
            );
        }
    }
}

#[test]
fn bitrate_retarget_repairs_a_partial_update_even_at_the_cached_target() {
    let cfg =
        EncCfg { width: 640, height: 480, fps: 60, kbps: 8000, threads: 1, screen_content: true };
    let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
    let mut rate = SBitrateInfo { iLayer: SPATIAL_LAYER_ALL, iBitrate: 16_000_000 };
    let set = enc.vtbl().SetOption.expect("SetOption");
    // SAFETY: live codec and the documented bitrate payload. The old setter
    // mutates the target before failing validation against the layer cap.
    assert_ne!(
        unsafe { set(enc.enc, ENCODER_OPTION_BITRATE, (&mut rate as *mut SBitrateInfo).cast()) },
        0
    );
    assert_eq!(enc.kbps(), 8000);
    assert_eq!(read_rate(&enc, ENCODER_OPTION_BITRATE, SPATIAL_LAYER_0), 16_000_000);
    enc.set_bitrate(8000);
    for layer in [SPATIAL_LAYER_ALL, SPATIAL_LAYER_0] {
        assert_eq!(read_rate(&enc, ENCODER_OPTION_BITRATE, layer), 8_000_000);
        assert_eq!(read_rate(&enc, ENCODER_OPTION_MAX_BITRATE, layer), 8_000_000);
    }
}
