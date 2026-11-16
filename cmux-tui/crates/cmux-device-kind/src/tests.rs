use super::*;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Every kind maps to a glyph, no two kinds share one, and the wire names round-trip.
#[test]
fn every_kind_maps_to_its_own_glyph() {
    let mut symbols = HashSet::new();
    for kind in DeviceKind::ALL {
        assert!(!kind.symbol().is_empty(), "{kind} has no glyph");
        assert!(symbols.insert(kind.symbol()), "{kind} shares the glyph {}", kind.symbol());
        assert_eq!(DeviceKind::parse(kind.as_str()), kind);
        let wire = serde_json::to_value(kind).unwrap();
        assert_eq!(
            wire,
            serde_json::json!(kind.as_str()),
            "serde and as_str disagree for {kind:?}"
        );
    }
    assert_eq!(DeviceKind::parse("toaster"), DeviceKind::Generic);
}

/// The web's copy of the table is this crate's table (`CMUX_DEVICE_KIND_WRITE=1` rewrites it).
#[test]
fn web_glyph_table_is_current() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../webviews/src/ui/deviceGlyphKinds.json");
    let want = glyph_table_json();
    if std::env::var_os("CMUX_DEVICE_KIND_WRITE").is_some() {
        std::fs::write(&path, &want).unwrap();
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(have, want, "{} is stale: rerun with CMUX_DEVICE_KIND_WRITE=1", path.display());
}

#[test]
fn mac_models_name_their_line() {
    for (model, kind) in [
        ("MacBookAir10,1", DeviceKind::MacBook),
        ("MacBookPro18,3", DeviceKind::MacBook),
        ("Macmini9,1", DeviceKind::MacMini),
        ("iMac21,1", DeviceKind::IMac),
        ("iMacPro1,1", DeviceKind::IMac),
        ("MacPro7,1", DeviceKind::MacPro),
        ("Mac13,2", DeviceKind::MacStudio),
        ("Mac14,2", DeviceKind::MacBook),
        ("Mac14,3", DeviceKind::MacMini),
        ("Mac14,8", DeviceKind::MacPro),
        ("Mac15,5", DeviceKind::IMac),
        ("Mac16,10", DeviceKind::MacMini),
        ("Mac16,13", DeviceKind::MacBook),
        (" Mac16,9\n", DeviceKind::MacStudio),
        ("Mac99,1", DeviceKind::Generic),
        ("", DeviceKind::Generic),
    ] {
        assert_eq!(DeviceKind::from_mac_model(model), kind, "{model:?}");
    }
}

#[test]
fn an_os_alone_names_only_phones_and_tablets() {
    assert_eq!(DeviceKind::from_os("iOS"), DeviceKind::IPhone);
    assert_eq!(DeviceKind::from_os("iPadOS"), DeviceKind::IPad);
    assert_eq!(DeviceKind::from_os("macOS"), DeviceKind::Generic);
    assert_eq!(DeviceKind::from_os("linux"), DeviceKind::Generic);
}

fn fixture(files: &[(&str, &str)]) -> tempdir::Dir {
    let dir = tempdir::Dir::new();
    for (path, text) in files {
        let path = dir.0.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    dir
}

#[test]
fn linux_reads_desktop_chassis_and_virtualization() {
    let cases: [(&[(&str, &str)], DeviceKind); 6] = [
        // A cloud VM: QEMU DMI, the hypervisor flag, no desktop.
        (
            &[
                ("sys/class/dmi/id/sys_vendor", "QEMU\n"),
                ("sys/class/dmi/id/chassis_type", "1\n"),
                ("proc/cpuinfo", "flags\t: fpu vme hypervisor\n"),
            ],
            DeviceKind::LinuxServer,
        ),
        // A workstation with GNOME installed.
        (
            &[("usr/share/xsessions/gnome.desktop", ""), ("sys/class/dmi/id/chassis_type", "3\n")],
            DeviceKind::LinuxDesktop,
        ),
        // A laptop with a running Wayland session and no session files.
        (&[("run/user/1000/wayland-0", "")], DeviceKind::LinuxDesktop),
        // A bare-metal laptop chassis without a desktop.
        (&[("sys/class/dmi/id/chassis_type", "10\n")], DeviceKind::LinuxDesktop),
        // A rack server.
        (&[("sys/class/dmi/id/chassis_type", "23\n")], DeviceKind::LinuxServer),
        // A container: no DMI at all.
        (&[(".dockerenv", "")], DeviceKind::LinuxServer),
    ];
    for (files, kind) in cases {
        let dir = fixture(files);
        assert_eq!(linux_facts(&dir.0).kind(), kind, "{files:?}");
    }
    assert_eq!(linux_facts(Path::new("/nonexistent-root")).kind(), DeviceKind::LinuxServer);
}

/// A scratch directory removed when dropped (no tempfile dependency).
mod tempdir {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    pub(super) struct Dir(pub PathBuf);

    impl Dir {
        pub(super) fn new() -> Dir {
            static N: AtomicU32 = AtomicU32::new(0);
            let path = std::env::temp_dir().join(format!(
                "cmux-device-kind-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::SeqCst)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Dir(path)
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
