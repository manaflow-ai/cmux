//! The encoders behind `H264Encoder` and the rules for OpenH264 binaries
//! (plans/cmux-next/remote-desktop-c7.md section 4).

use cmux_encode::I420;

#[test]
fn an_i420_picture_starts_black_in_video_range() {
    let pic = I420::new(4, 2);
    assert_eq!(pic.y, vec![16; 8]);
    assert_eq!(pic.u, vec![128; 2]);
}

#[cfg(feature = "openh264-source")]
#[test]
fn openh264_from_source_encodes_an_idr_on_request() {
    use cmux_encode::openh264::{OpenH264, OpenH264Api};
    use cmux_encode::{EncCfg, H264Encoder};
    let cfg =
        EncCfg { width: 64, height: 64, fps: 30, kbps: 500, threads: 1, screen_content: true };
    let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
    let pic = I420::new(64, 64);
    let mut au = Vec::new();
    let idr = enc.encode(&pic, true, 0, &mut au).expect("encode");
    assert!(idr, "a forced IDR");
    assert!(au.starts_with(&[0, 0, 0, 1]), "Annex-B");
    assert!(enc.name().starts_with("openh264 2.6"));
}

#[cfg(feature = "openh264-runtime")]
mod runtime {
    use cmux_encode::openh264::{CiscoBinary, LoadError, Platform, load_verified};

    #[test]
    fn every_platform_names_a_cisco_url_and_a_sha256() {
        for platform in Platform::ALL {
            let bin = CiscoBinary::for_platform(platform);
            assert!(bin.url.starts_with("http://ciscobinary.openh264.org/"), "{platform:?}");
            assert!(bin.url.ends_with(".bz2"), "Cisco serves bzip2 files: {platform:?}");
            assert_eq!(bin.sha256.len(), 64, "{platform:?}");
            assert!(bin.sha256.bytes().all(|b| b.is_ascii_hexdigit()), "{platform:?}");
        }
        let linux = CiscoBinary::for_platform(Platform::LinuxX64);
        assert_eq!(linux.url, "http://ciscobinary.openh264.org/libopenh264-2.6.0-linux64.8.so.bz2");
        assert_eq!(
            linux.sha256,
            "2f0cde7c6a6abcf5cae76942894ea42897fa677bce4ed6c91a24dd1b041d5f04"
        );
    }

    #[test]
    fn a_library_with_another_hash_is_refused_before_loading() {
        let dir = std::env::temp_dir().join(format!("cmux-encode-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let fake = dir.join("libopenh264.so");
        std::fs::write(&fake, b"not cisco's library").expect("write");
        match load_verified(&fake, Platform::LinuxX64) {
            Err(LoadError::HashMismatch { expected, actual }) => {
                assert_eq!(expected, CiscoBinary::for_platform(Platform::LinuxX64).sha256);
                assert_ne!(actual, expected);
            }
            Err(other) => panic!("expected a hash mismatch, got {other:?}"),
            Ok(_) => panic!("a foreign library was loaded"),
        }
        assert!(matches!(
            load_verified(dir.join("missing.so"), Platform::LinuxX64),
            Err(LoadError::Io(_))
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Real check with Cisco's library, downloaded from Cisco by the person
    /// running it: CMUX_OPENH264_LIB=<decompressed library> cargo test --features
    /// openh264-runtime -- --ignored. Not in CI (no download there).
    #[test]
    #[ignore = "needs Cisco's library downloaded on this machine"]
    fn ciscos_library_loads_and_encodes_an_idr() {
        use cmux_encode::openh264::OpenH264;
        use cmux_encode::{EncCfg, H264Encoder, I420};
        let path = std::env::var("CMUX_OPENH264_LIB").expect("CMUX_OPENH264_LIB");
        let api =
            load_verified(&path, Platform::current().expect("platform")).expect("verified load");
        let cfg =
            EncCfg { width: 64, height: 64, fps: 30, kbps: 500, threads: 1, screen_content: true };
        let mut enc = OpenH264::new(&cfg, api).expect("encoder");
        let mut au = Vec::new();
        assert!(enc.encode(&I420::new(64, 64), true, 0, &mut au).expect("encode"));
        assert!(au.starts_with(&[0, 0, 0, 1]));
    }
}
