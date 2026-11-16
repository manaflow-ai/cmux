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

/// Screen usage makes an IDR of every frame that moves most of the picture, whatever the
/// settings say; the adapter moves to camera usage for that motion and back when it ends.
#[cfg(feature = "openh264-source")]
#[test]
fn openh264_full_screen_motion_is_not_all_idrs() {
    use cmux_encode::openh264::{CALM_FRAMES_TO_SCREEN, OpenH264, OpenH264Api};
    use cmux_encode::{EncCfg, H264Encoder};
    let cfg =
        EncCfg { width: 320, height: 192, fps: 30, kbps: 4000, threads: 1, screen_content: true };
    let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
    let mut pic = I420::new(320, 192);
    let mut seed = 1u32;
    let mut au = Vec::new();
    let mut idrs = 0;
    let mut pts = 0;
    for i in 0..60 {
        for y in &mut pic.y {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            *y = 16 + (seed >> 24) as u8 % 200;
        }
        pts += 33_000;
        idrs += u32::from(enc.encode(&pic, i == 0, pts, &mut au).expect("encode"));
    }
    assert!(idrs <= 3, "{idrs} IDRs in 60 frames of full-screen motion");
    assert!(enc.name().contains("camera-for-motion"), "{}", enc.name());
    for _ in 0..=CALM_FRAMES_TO_SCREEN {
        pts += 33_000;
        enc.encode(&pic, false, pts, &mut au).expect("encode");
    }
    assert!(!enc.name().contains("camera"), "{}", enc.name());
}

#[cfg(feature = "openh264-runtime")]
mod runtime {
    use cmux_encode::openh264::{CiscoBinary, LoadError, Platform, load_verified};

    #[test]
    fn every_platform_names_a_cisco_url_and_a_sha256() {
        for platform in Platform::ALL {
            let bin = CiscoBinary::for_platform(platform);
            assert!(bin.url.starts_with("https://ciscobinary.openh264.org/"), "{platform:?}");
            assert!(bin.url.ends_with(".bz2"), "Cisco serves bzip2 files: {platform:?}");
            assert_eq!(bin.sha256.len(), 64, "{platform:?}");
            assert!(bin.sha256.bytes().all(|b| b.is_ascii_hexdigit()), "{platform:?}");
        }
        let linux = CiscoBinary::for_platform(Platform::LinuxX64);
        assert_eq!(
            linux.url,
            "https://ciscobinary.openh264.org/libopenh264-2.6.0-linux64.8.so.bz2"
        );
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

/// The host installer's OpenH264 step: download from Cisco, pinned SHA-256,
/// per-user storage, atomic write (feature `openh264-download`).
#[cfg(feature = "openh264-download")]
mod cisco_install {
    use std::cell::Cell;
    use std::ffi::OsString;
    use std::io::Write;
    use std::path::{Path, PathBuf};

    use cmux_encode::cisco::{self, InstallError, dir_from, install_with};
    use cmux_encode::openh264::{CiscoBinary, Platform};
    use sha2::Digest;

    fn bz2(bytes: &[u8]) -> Vec<u8> {
        let mut enc = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::best());
        enc.write_all(bytes).expect("compress");
        enc.finish().expect("finish")
    }

    fn fake(library: &[u8]) -> CiscoBinary {
        let sha: String =
            sha2::Sha256::digest(library).iter().map(|b| format!("{b:02x}")).collect();
        CiscoBinary {
            url: "https://ciscobinary.openh264.org/libfake.so.bz2",
            file_name: "libfake.so",
            sha256: Box::leak(sha.into_boxed_str()),
        }
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-cisco-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn files(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        names.sort();
        names
    }

    #[test]
    fn installs_the_verified_library_from_ciscos_url() {
        let dir = temp("ok");
        let library = b"pretend this is libopenh264".repeat(100);
        let bin = fake(&library);
        let asked = Cell::new(None);
        let path = install_with(&dir, &bin, |url| {
            asked.set(Some(url.to_owned()));
            Ok(bz2(&library))
        })
        .expect("install");
        assert_eq!(asked.take().as_deref(), Some(bin.url), "downloads Cisco's URL");
        assert_eq!(path, dir.join("libfake.so"));
        assert_eq!(std::fs::read(&path).expect("read"), library);
        assert_eq!(files(&dir), vec!["libfake.so"], "no temporary file is left");
        // Installed: a second run does not download again.
        let again = install_with(&dir, &bin, |_| panic!("no second download")).expect("again");
        assert_eq!(again, path);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_wrong_hash_writes_nothing() {
        let dir = temp("hash");
        let bin = fake(b"the pinned library");
        match install_with(&dir, &bin, |_| Ok(bz2(b"something else"))) {
            Err(InstallError::HashMismatch { expected, .. }) => assert_eq!(expected, bin.sha256),
            other => panic!("expected a hash mismatch, got {other:?}"),
        }
        assert!(files(&dir).is_empty(), "nothing written: {:?}", files(&dir));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_corrupt_or_oversized_download_is_refused() {
        let dir = temp("bad");
        let bin = fake(b"lib");
        assert!(matches!(
            install_with(&dir, &bin, |_| Ok(b"not bzip2".to_vec())),
            Err(InstallError::Decompress(_))
        ));
        let huge = vec![0u8; cisco::MAX_COMPRESSED_BYTES + 1];
        assert!(matches!(install_with(&dir, &bin, |_| Ok(huge)), Err(InstallError::TooLarge)));
        let bomb = bz2(&vec![0u8; cisco::MAX_LIBRARY_BYTES + 1]);
        assert!(matches!(install_with(&dir, &bin, |_| Ok(bomb)), Err(InstallError::TooLarge)));
        assert!(files(&dir).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_tampered_installed_file_is_replaced() {
        let dir = temp("tamper");
        let library = b"cisco".repeat(50);
        let bin = fake(&library);
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(dir.join(bin.file_name), b"tampered").expect("write");
        let path = install_with(&dir, &bin, |_| Ok(bz2(&library))).expect("reinstall");
        assert_eq!(std::fs::read(path).expect("read"), library);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_library_lives_in_a_per_user_data_directory() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| OsString::from(*v))
        };
        assert_eq!(
            dir_from("linux", env(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "/data")])),
            Some(PathBuf::from("/data/cmux/openh264"))
        );
        assert_eq!(
            dir_from("linux", env(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "rel")])),
            Some(PathBuf::from("/home/u/.local/share/cmux/openh264")),
            "a relative XDG_DATA_HOME is ignored"
        );
        assert_eq!(
            dir_from("macos", env(&[("HOME", "/Users/u")])),
            Some(PathBuf::from("/Users/u/Library/Application Support/cmux-next/openh264"))
        );
        assert_eq!(dir_from("linux", env(&[])), None);
        assert_eq!(
            cisco::library_path(Path::new("/d"), Platform::LinuxX64),
            PathBuf::from("/d/libopenh264-2.6.0-linux64.8.so")
        );
    }

    /// The real download from Cisco's server and a verified load (network;
    /// run on a Testbox: cargo test -p cmux-encode --features
    /// openh264-download -- --ignored cisco_install).
    #[test]
    #[ignore = "downloads from ciscobinary.openh264.org"]
    fn downloads_ciscos_library_and_loads_it() {
        let dir = temp("real");
        let platform = Platform::current().expect("a platform Cisco publishes for");
        let path = cisco::install(&dir, platform).expect("download from Cisco");
        let api = cmux_encode::openh264::load_verified(&path, platform).expect("verified load");
        let cfg = cmux_encode::EncCfg {
            width: 64,
            height: 64,
            fps: 30,
            kbps: 500,
            threads: 1,
            screen_content: true,
        };
        use cmux_encode::H264Encoder;
        let mut enc = cmux_encode::openh264::OpenH264::new(&cfg, api).expect("encoder");
        let mut au = Vec::new();
        assert!(enc.encode(&cmux_encode::I420::new(64, 64), true, 0, &mut au).expect("encode"));
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// VideoToolbox (macOS hosts; hardware encoder). Runs on a fleet Mac through
/// cmux-ci (scripts/ci/cmux-tui-rust-check.sh), never on a developer Mac.
#[cfg(target_os = "macos")]
#[test]
fn videotoolbox_encodes_an_idr_on_request() {
    use cmux_encode::H264Encoder;
    use cmux_encode::videotoolbox::VideoToolbox;
    let mut enc = VideoToolbox::new(256, 128, 30, 2_000, false).expect("hardware encoder");
    let mut au = Vec::new();
    let mut idr = false;
    // VideoToolbox may deliver the first frame one call late.
    for i in 0..4 {
        idr |= enc.encode(&I420::new(256, 128), i == 0, i * 33_000, &mut au).expect("encode");
        if !au.is_empty() {
            break;
        }
    }
    assert!(idr, "a forced IDR");
    assert!(au.starts_with(&[0, 0, 0, 1]), "Annex-B");
    assert!(enc.name().starts_with("videotoolbox h264"), "{}", enc.name());
}

/// A big change after a still screen stays within one frame interval's share of the rate
/// (videotoolbox.rs frame_budget: DataRateLimits), so it leaves a paced sender within one
/// frame interval instead of queueing behind itself. Runs on a fleet Mac.
#[cfg(target_os = "macos")]
#[test]
fn videotoolbox_a_change_after_a_still_screen_fits_one_frame_budget() {
    use cmux_encode::H264Encoder;
    use cmux_encode::videotoolbox::VideoToolbox;
    const W: usize = 512;
    const H: usize = 256;
    const FPS: u32 = 30;
    const KBPS: u32 = 2_000;
    let mut enc =
        VideoToolbox::new(W as u32, H as u32, FPS, KBPS, false).expect("hardware encoder");
    let still = I420::new(W, H);
    let mut au = Vec::new();
    let mut pts = 0i64;
    for i in 0..30 {
        enc.encode(&still, i == 0, pts, &mut au).expect("encode");
        pts += 1_000_000 / i64::from(FPS);
    }
    let mut seed = 0x2545_f491_4f6c_dd1du64;
    let mut pic = I420::new(W, H);
    let mut sizes = Vec::new();
    for _ in 0..3 {
        for px in pic.y.iter_mut().chain(pic.u.iter_mut()).chain(pic.v.iter_mut()) {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            *px = 16 + (seed % 220) as u8;
        }
        enc.encode(&pic, false, pts, &mut au).expect("encode");
        pts += 1_000_000 / i64::from(FPS);
        sizes.push(au.len());
    }
    let budget = (KBPS as usize * 1000 / 8) / FPS as usize;
    eprintln!("changed frames {sizes:?} B, per-frame budget {budget} B");
    // Some slack for headers and the encoder's own estimate; without the budget a change
    // after a still screen spends the saved-up rate and comes out many budgets large.
    let worst = sizes.iter().copied().max().unwrap_or(0);
    assert!(worst <= budget * 3 / 2, "a changed frame of {worst} B is over the {budget} B budget");
}

/// Ultra (videotoolbox.rs set_ultra) holds frame rate first: a big change after a still screen
/// stays within one frame interval's share of the target, an uncapped target stops at the
/// per-pixel ceiling (3 bits per pixel), there is no QP floor, and a refinement frame of the
/// still picture encodes. Prints sizes and encode ms next to standard's. Runs on a fleet Mac.
#[cfg(target_os = "macos")]
#[test]
fn videotoolbox_ultra_holds_frame_rate_first_and_refines_a_still_screen() {
    use cmux_encode::H264Encoder;
    use cmux_encode::videotoolbox::VideoToolbox;
    use std::time::Instant;
    const W: usize = 512;
    const H: usize = 256;
    const FPS: u32 = 30;
    let noise = |seed: &mut u64, pic: &mut I420| {
        for px in pic.y.iter_mut().chain(pic.u.iter_mut()).chain(pic.v.iter_mut()) {
            *seed ^= *seed << 13;
            *seed ^= *seed >> 7;
            *seed ^= *seed << 17;
            *px = 16 + (*seed % 220) as u8;
        }
    };
    // (changed frame sizes, refinement size, mean encode ms) at `kbps`.
    let run = |ultra: bool, kbps: u32| -> (Vec<usize>, usize, f64) {
        let mut enc =
            VideoToolbox::new(W as u32, H as u32, FPS, kbps, false).expect("hardware encoder");
        enc.set_ultra(ultra);
        assert_eq!(enc.min_qp(), None, "no QP floor by default");
        assert_eq!(enc.name().ends_with(" ultra"), ultra, "{}", enc.name());
        let still = I420::new(W, H);
        let mut au = Vec::new();
        let mut pts = 0i64;
        for i in 0..30 {
            enc.encode(&still, i == 0, pts, &mut au).expect("encode");
            pts += 1_000_000 / i64::from(FPS);
        }
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut pic = I420::new(W, H);
        let mut sizes = Vec::new();
        let mut ms = 0.0;
        for _ in 0..3 {
            noise(&mut seed, &mut pic);
            let t = Instant::now();
            enc.encode(&pic, false, pts, &mut au).expect("encode");
            ms += t.elapsed().as_secs_f64() * 1e3;
            pts += 1_000_000 / i64::from(FPS);
            sizes.push(au.len());
        }
        // The screen goes still on the last picture: one refinement frame of it.
        enc.set_refine(true);
        enc.encode(&pic, false, pts, &mut au).expect("refinement encode");
        (sizes, au.len(), ms / 3.0)
    };
    const KBPS: u32 = 2_000;
    let (standard, standard_next, standard_ms) = run(false, KBPS);
    let (ultra, ultra_refined, ultra_ms) = run(true, KBPS);
    // An uncapped target: far over what the picture can use.
    let (uncapped, uncapped_refined, uncapped_ms) = run(true, 2_000_000);
    let budget = (KBPS as usize * 1000 / 8) / FPS as usize;
    let ceiling = W * H * 3 / 8;
    eprintln!(
        "budget {budget} B, ceiling {ceiling} B; standard {standard:?} B ({standard_ms:.2} ms), \
         next {standard_next} B; ultra {ultra:?} B ({ultra_ms:.2} ms), refinement \
         {ultra_refined} B; uncapped ultra {uncapped:?} B ({uncapped_ms:.2} ms), refinement \
         {uncapped_refined} B"
    );
    let worst = |v: &[usize]| v.iter().copied().max().unwrap_or(0);
    // Slack for headers and the encoder's own estimate, as the standard budget test.
    assert!(worst(&ultra) <= budget * 3 / 2, "ultra changed frame {ultra:?} over {budget} B");
    assert!(
        worst(&uncapped) <= ceiling * 3 / 2,
        "uncapped ultra frame {uncapped:?} over the {ceiling} B per-pixel ceiling"
    );
    assert!(ultra_refined > 0 && uncapped_refined > 0, "the refinement encodes");
}
