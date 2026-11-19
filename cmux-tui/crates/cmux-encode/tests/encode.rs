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

/// Standard: a big change after a still screen stays near one frame interval's share of the
/// rate, so it leaves a paced sender within about one frame interval instead of queueing
/// behind itself. The low-latency encoder refuses DataRateLimits (videotoolbox.rs
/// frame_budget), so the frame-size guard (frame_guard.rs) sets each frame's QP floor from its
/// damage and budget: base without the guard measured 257/199/148 KB against the 8.3 KB
/// budget. The guard sizes the change after a still screen from what the session has sent,
/// so the bar is on the session's second still-to-change transition: frame 1 under 2
/// budgets, frames 2-3 under 1.5. The first transition is the stated exemption (nothing
/// learned yet: it starts from the noise figure) and is only printed. The first still period
/// sends frames with no damage, the second sends nothing for a second (as the engine does).
/// Prints the guard-off sizes beside. Runs on a fleet Mac.
#[cfg(target_os = "macos")]
#[test]
fn videotoolbox_a_change_after_a_still_screen_fits_one_frame_budget() {
    use cmux_encode::H264Encoder;
    use cmux_encode::videotoolbox::VideoToolbox;
    const W: usize = 512;
    const H: usize = 256;
    const FPS: u32 = 30;
    const KBPS: u32 = 2_000;
    // (first transition's changed frames, second transition's) in bytes.
    let run = |guard: bool| -> (Vec<usize>, Vec<usize>) {
        let mut enc =
            VideoToolbox::new(W as u32, H as u32, FPS, KBPS, false).expect("hardware encoder");
        enc.set_guard(guard);
        let still = I420::new(W, H);
        let mut au = Vec::new();
        let mut pts = 0i64;
        for i in 0..30 {
            if i > 0 {
                enc.set_changed_pixels(0);
            }
            enc.encode(&still, i == 0, pts, &mut au).expect("encode");
            pts += 1_000_000 / i64::from(FPS);
        }
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut pic = I420::new(W, H);
        let mut change = |pts: &mut i64, enc: &mut VideoToolbox, au: &mut Vec<u8>| -> Vec<usize> {
            let mut sizes = Vec::new();
            for _ in 0..3 {
                for px in pic.y.iter_mut().chain(pic.u.iter_mut()).chain(pic.v.iter_mut()) {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    *px = 16 + (seed % 220) as u8;
                }
                enc.set_changed_pixels((W * H) as u64);
                enc.encode(&pic, false, *pts, au).expect("encode");
                *pts += 1_000_000 / i64::from(FPS);
                sizes.push(au.len());
            }
            sizes
        };
        let first = change(&mut pts, &mut enc, &mut au);
        // Still for a second: the engine sends nothing.
        pts += 1_000_000;
        let second = change(&mut pts, &mut enc, &mut au);
        (first, second)
    };
    let (unguarded_first, unguarded) = run(false);
    let (first, sizes) = run(true);
    let budget = (KBPS as usize * 1000 / 8) / FPS as usize;
    eprintln!(
        "per-frame budget {budget} B; first transition {first:?} B (guard off \
         {unguarded_first:?} B); second {sizes:?} B (guard off {unguarded:?} B)"
    );
    assert!(sizes[0] <= budget * 2, "frame 1 after a still screen {sizes:?} over 2x {budget} B");
    assert!(
        sizes[1..].iter().all(|&s| s <= budget * 3 / 2),
        "frames 2-3 after a still screen {sizes:?} over 1.5x the {budget} B budget"
    );
}

/// Ultra (videotoolbox.rs set_ultra) holds frame rate first. A big change after a still screen:
/// the frame-size guard (frame_guard.rs) seeds the first changed frame's QP floor from its
/// damage and budget (under 2 frame budgets) and holds the rest to 1.5 budgets from the third
/// on; an uncapped target stops at the per-pixel ceiling (3 bits per pixel). Once the change
/// gets small the floor clears within 3 frames (text sharpens), and a refinement frame of the
/// still picture encodes. Prints frames 1-3, frames to clear and encode ms next to standard's.
/// Runs on a fleet Mac.
#[cfg(target_os = "macos")]
#[test]
fn videotoolbox_ultra_holds_frame_rate_first_and_refines_a_still_screen() {
    use cmux_encode::H264Encoder;
    use cmux_encode::videotoolbox::VideoToolbox;
    use std::time::Instant;
    const W: usize = 512;
    const H: usize = 256;
    const FPS: u32 = 30;
    // Changed frames in a row, then small changes (a 64x16 block) until the floor clears.
    const CHANGED: usize = 8;
    const SMALL: usize = 10;
    let noise = |seed: &mut u64, pic: &mut I420| {
        for px in pic.y.iter_mut().chain(pic.u.iter_mut()).chain(pic.v.iter_mut()) {
            *seed ^= *seed << 13;
            *seed ^= *seed >> 7;
            *seed ^= *seed << 17;
            *px = 16 + (*seed % 220) as u8;
        }
    };
    struct Run {
        sizes: Vec<usize>,
        refined: usize,
        ms: f64,
        /// Small-change frames until the guard set no floor (`SMALL + 1`: never).
        to_clear: usize,
    }
    let run = |ultra: bool, kbps: u32| -> Run {
        let mut enc =
            VideoToolbox::new(W as u32, H as u32, FPS, kbps, false).expect("hardware encoder");
        enc.set_ultra(ultra);
        assert_eq!(enc.min_qp(), None, "no configured QP floor by default");
        assert_eq!(enc.name().ends_with(" ultra"), ultra, "{}", enc.name());
        let still = I420::new(W, H);
        let mut au = Vec::new();
        let mut pts = 0i64;
        for i in 0..30 {
            // The engine sends a still screen's frames with no damage.
            if i > 0 {
                enc.set_changed_pixels(0);
            }
            enc.encode(&still, i == 0, pts, &mut au).expect("encode");
            pts += 1_000_000 / i64::from(FPS);
        }
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut pic = I420::new(W, H);
        let mut sizes = Vec::new();
        let mut ms = 0.0;
        for _ in 0..CHANGED {
            noise(&mut seed, &mut pic);
            enc.set_changed_pixels((W * H) as u64);
            let t = Instant::now();
            enc.encode(&pic, false, pts, &mut au).expect("encode");
            ms += t.elapsed().as_secs_f64() * 1e3;
            pts += 1_000_000 / i64::from(FPS);
            sizes.push(au.len());
        }
        let mut to_clear = SMALL + 1;
        for i in 0..SMALL {
            for row in 0..16 {
                for px in &mut pic.y[row * W..row * W + 64] {
                    *px = if i % 2 == 0 { 235 } else { 16 };
                }
            }
            enc.set_changed_pixels(64 * 16);
            enc.encode(&pic, false, pts, &mut au).expect("encode");
            pts += 1_000_000 / i64::from(FPS);
            if enc.guard().floor() == 0 {
                to_clear = i + 1;
                break;
            }
        }
        // The screen goes still: one refinement frame of it.
        enc.set_refine(true);
        enc.encode(&pic, false, pts, &mut au).expect("refinement encode");
        Run { sizes, refined: au.len(), ms: ms / CHANGED as f64, to_clear }
    };
    const KBPS: u32 = 2_000;
    let standard = run(false, KBPS);
    let ultra = run(true, KBPS);
    // An uncapped target: far over what the picture can use.
    let uncapped = run(true, 2_000_000);
    let budget = (KBPS as usize * 1000 / 8) / FPS as usize;
    let ceiling = W * H * 3 / 8;
    let show = |name: &str, r: &Run| {
        eprintln!(
            "{name}: frames 1-3 {:?} B, all {:?} B, encode {:.2} ms, floor clear after {} small \
             frames, refinement {} B",
            &r.sizes[..3],
            r.sizes,
            r.ms,
            r.to_clear,
            r.refined
        );
    };
    eprintln!("budget {budget} B, ceiling {ceiling} B");
    show("standard", &standard);
    show("ultra", &ultra);
    show("uncapped ultra", &uncapped);
    let after_second = |v: &[usize]| v.iter().skip(2).copied().max().unwrap_or(0);
    assert!(
        ultra.sizes[0] <= budget * 2,
        "ultra's first changed frame {:?} over 2x {budget} B",
        ultra.sizes
    );
    assert!(
        after_second(&ultra.sizes) <= budget * 3 / 2,
        "ultra changed frame {:?} over 1.5x {budget} B from the third on",
        ultra.sizes
    );
    assert!(
        after_second(&uncapped.sizes) <= ceiling * 3 / 2,
        "uncapped ultra frame {:?} over the {ceiling} B per-pixel ceiling",
        uncapped.sizes
    );
    assert!(ultra.to_clear <= 3, "ultra's floor took {} small frames to clear", ultra.to_clear);
    assert!(ultra.refined > 0 && uncapped.refined > 0, "the refinement encodes");
}

/// Where ultra's encode time goes at the sweep's settings: 1080p, a 120 fps cap, 150 Mbps.
/// Scrolled text (24 rows a frame) and full-screen noise, each through standard and ultra,
/// with the frame-size guard off and on; prints encode ms p50 / p95 and frame bytes
/// p50 / p95 / max (the keyframe apart). Asserts only that ultra with the guard keeps every
/// frame after the keyframe under 1 MB. Runs on a fleet Mac.
#[cfg(target_os = "macos")]
#[test]
fn videotoolbox_ultra_encode_time_at_1080p120() {
    use cmux_encode::H264Encoder;
    use cmux_encode::frame_guard::keyframe_max_bytes;
    use cmux_encode::videotoolbox::VideoToolbox;
    use std::time::Instant;
    const W: usize = 1920;
    const H: usize = 1080;
    const FPS: u32 = 120;
    const KBPS: u32 = 150_000;
    const FRAMES: usize = 240;
    let hash = |a: usize, b: usize| -> u64 {
        let ka = (a as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
        let mut x = ka ^ (b as u64).wrapping_mul(0xc2b2_ae3d_27d4_eb4f);
        x ^= x >> 29;
        x.wrapping_mul(0xbf58_476d_1ce4_e5b9) >> 32
    };
    // Dark glyphs on a light page: 24-row lines of 12-px cells, `scroll` rows up.
    let text = |pic: &mut I420, scroll: usize| {
        for y in 0..H {
            let page_y = y + scroll;
            let (line, row) = (page_y / 24, page_y % 24);
            for x in 0..W {
                let (cell, col) = (x / 12, x % 12);
                let h = hash(line, cell);
                let stroke = (h >> (row % 16)) & 1 == 1 && (h >> (8 + col)) & 1 == 1;
                let ink = (4..20).contains(&row) && (2..10).contains(&col) && h % 5 != 0 && stroke;
                pic.y[y * W + x] = if ink { 30 } else { 230 };
            }
        }
        pic.u.fill(128);
        pic.v.fill(128);
    };
    let mut seed = 0x2545_f491_4f6c_dd1du64;
    let mut noise = |pic: &mut I420| {
        for px in pic.y.iter_mut().chain(pic.u.iter_mut()).chain(pic.v.iter_mut()) {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            *px = 16 + (seed % 220) as u8;
        }
    };
    let pct = |v: &mut Vec<f64>, p: f64| -> f64 {
        v.sort_by(|a, b| a.total_cmp(b));
        v[((v.len() - 1) as f64 * p).round() as usize]
    };
    for scene in ["text", "noise"] {
        let runs = [
            ("standard, guard off", false, false),
            ("standard, guard on", false, true),
            ("ultra, guard off", true, false),
            ("ultra, guard on", true, true),
        ];
        for (name, ultra, guard) in runs {
            let mut enc =
                VideoToolbox::new(W as u32, H as u32, FPS, KBPS, false).expect("hardware encoder");
            enc.set_ultra(ultra);
            enc.set_guard(guard);
            let mut pic = I420::new(W, H);
            let mut au = Vec::new();
            let (mut ms, mut bytes) = (Vec::new(), Vec::new());
            // (frame index, encode ms, bytes) of every frame, keyframes included.
            let mut trace = Vec::new();
            let mut keyframes = Vec::new();
            for i in 0..FRAMES {
                if scene == "text" {
                    text(&mut pic, i * 24);
                } else {
                    noise(&mut pic);
                }
                enc.set_changed_pixels((W * H) as u64);
                let t = Instant::now();
                let pts = i as i64 * 1_000_000 / i64::from(FPS);
                // A second keyframe mid-run: the first sizes its floor.
                let force = i == 0 || i == FRAMES / 2;
                let idr = enc.encode(&pic, force, pts, &mut au).expect("encode");
                let took = t.elapsed().as_secs_f64() * 1e3;
                trace.push((i, took, au.len()));
                if idr {
                    keyframes.push(au.len());
                } else {
                    ms.push(took);
                    bytes.push(au.len() as f64);
                }
            }
            let max = bytes.iter().copied().fold(0.0, f64::max);
            let p50_ms = pct(&mut ms, 0.5);
            eprintln!(
                "1080p120 150 Mbps {scene}, {name}: encode p50 {p50_ms:.2} p95 {:.2} ms; frame \
                 p50 {:.0} p95 {:.0} max {max:.0} B; keyframes {keyframes:?} B; budget 156250 B",
                pct(&mut ms, 0.95),
                pct(&mut bytes, 0.5),
                pct(&mut bytes, 0.95),
            );
            // Encode ms histogram in 2 ms buckets (the last is 20 ms and over).
            let mut histogram = [0usize; 11];
            for &(_, took, _) in &trace {
                histogram[((took / 2.0) as usize).min(10)] += 1;
            }
            eprintln!("  encode ms histogram (2 ms buckets, last 20+): {histogram:?}");
            // The slow frames (over twice the p50): where they fall, the gap since the last
            // slow one, and the size of the frame before.
            let slow: Vec<String> = trace
                .iter()
                .filter(|&&(_, took, _)| took > 2.0 * p50_ms)
                .map(|&(i, took, _)| {
                    let before = if i > 0 { trace[i - 1].2 } else { 0 };
                    format!("#{i} {took:.1}ms (prev {before} B)")
                })
                .collect();
            eprintln!("  slow frames ({}): {}", slow.len(), slow.join(", "));
            if ultra && guard {
                assert!(max <= 1_000_000.0, "{scene}: a frame of {max} B after the keyframe");
                let max_key = keyframe_max_bytes(W * H);
                assert!(
                    keyframes.iter().skip(1).all(|&k| k <= max_key),
                    "{scene}: a keyframe after the first over {max_key} B: {keyframes:?}"
                );
            }
        }
    }
}
