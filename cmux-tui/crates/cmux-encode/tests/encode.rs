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
            Some(PathBuf::from("/Users/u/Library/Application Support/cmux/openh264"))
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
