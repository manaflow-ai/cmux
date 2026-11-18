//! What kind of device a machine is, and the one glyph each kind draws.
//!
//! Leo, 2026-11-14: "i recall lawrence asked lucas to add nicer icons for stuff i think we can have
//! them too for these? if we don't already... across all the remote related areas". Every place
//! the app shows a machine (Screen Sharing's devices, the sidebar's machines, Add a Device, the
//! location picker, a remote chat's header) draws the glyph [`DeviceKind::symbol`] names: native
//! views draw that SF Symbol, and the web views draw the same symbol's vector paths
//! (`webviews/src/ui/deviceGlyphs.ts`, keyed by the table [`glyph_table_json`] writes).
//!
//! A machine says what it is itself ([`this_device`]): acpmux puts it in its `host_health` reply,
//! so a peer's row carries its kind. On macOS that is the hardware model (`sysctl hw.model`, read
//! once); on Linux whether a desktop is installed or running, whether a cmux screen host is set up
//! for the user acpmux runs as, the DMI chassis and whether it is a virtual machine. A Cloud machine is one by where its record comes from ([`DeviceKind::Cloud`]),
//! not by anything it reports. A kind nothing tells is [`DeviceKind::Generic`].

use serde::{Deserialize, Serialize};

/// What a device is, as a person names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceKind {
    #[serde(rename = "macbook")]
    MacBook,
    MacMini,
    #[serde(rename = "imac")]
    IMac,
    MacStudio,
    MacPro,
    /// A Linux machine with a desktop (installed or running, or the virtual display a cmux screen
    /// host starts on demand), or a Linux laptop or desktop chassis.
    LinuxDesktop,
    /// A Linux machine with no desktop: a server, a VM or a container.
    LinuxServer,
    /// A cmux Cloud machine (or another machine reached as a Cloud peer).
    Cloud,
    #[serde(rename = "iphone")]
    IPhone,
    #[serde(rename = "ipad")]
    IPad,
    /// Nothing says what it is.
    Generic,
}

impl DeviceKind {
    /// Every kind, in the order a gallery shows them.
    pub const ALL: [DeviceKind; 11] = [
        DeviceKind::MacBook,
        DeviceKind::MacMini,
        DeviceKind::IMac,
        DeviceKind::MacStudio,
        DeviceKind::MacPro,
        DeviceKind::LinuxDesktop,
        DeviceKind::LinuxServer,
        DeviceKind::Cloud,
        DeviceKind::IPhone,
        DeviceKind::IPad,
        DeviceKind::Generic,
    ];

    /// The wire name (`mac-mini`), as records and the web carry it.
    pub const fn as_str(self) -> &'static str {
        match self {
            DeviceKind::MacBook => "macbook",
            DeviceKind::MacMini => "mac-mini",
            DeviceKind::IMac => "imac",
            DeviceKind::MacStudio => "mac-studio",
            DeviceKind::MacPro => "mac-pro",
            DeviceKind::LinuxDesktop => "linux-desktop",
            DeviceKind::LinuxServer => "linux-server",
            DeviceKind::Cloud => "cloud",
            DeviceKind::IPhone => "iphone",
            DeviceKind::IPad => "ipad",
            DeviceKind::Generic => "generic",
        }
    }

    /// The kind a wire name names; an unknown name (a newer peer's kind) is [`DeviceKind::Generic`].
    pub fn parse(name: &str) -> DeviceKind {
        DeviceKind::ALL.into_iter().find(|k| k.as_str() == name).unwrap_or(DeviceKind::Generic)
    }

    /// The SF Symbol this kind draws: the one mapping from kind to glyph. Native views draw the
    /// symbol by this name; the web draws its vector paths, exported under the same name.
    pub const fn symbol(self) -> &'static str {
        match self {
            DeviceKind::MacBook => "macbook.gen2",
            DeviceKind::MacMini => "macmini",
            DeviceKind::IMac => "desktopcomputer",
            DeviceKind::MacStudio => "macstudio",
            DeviceKind::MacPro => "macpro.gen3",
            DeviceKind::LinuxDesktop => "pc",
            DeviceKind::LinuxServer => "server.rack",
            DeviceKind::Cloud => "cloud",
            DeviceKind::IPhone => "iphone",
            DeviceKind::IPad => "ipad",
            DeviceKind::Generic => "display",
        }
    }

    /// The kind an OS name alone tells (a network node's or a joined machine's `platform`): a
    /// phone or tablet OS says so; a computer's OS says nothing of its model.
    pub fn from_os(os: &str) -> DeviceKind {
        match os.to_ascii_lowercase().as_str() {
            "ios" => DeviceKind::IPhone,
            "ipados" => DeviceKind::IPad,
            _ => DeviceKind::Generic,
        }
    }

    /// The kind a Mac's hardware model identifier (`sysctl hw.model`: `MacBookAir10,1`,
    /// `Mac14,3`) names. Apple silicon models after the M1 are all `MacNN,M`, so those are read
    /// from [`APPLE_SILICON_MODELS`]; a model not in it is [`DeviceKind::Generic`].
    pub fn from_mac_model(model: &str) -> DeviceKind {
        let model = model.trim();
        if let Some((_, kind)) = APPLE_SILICON_MODELS.iter().find(|(id, _)| *id == model) {
            return *kind;
        }
        // The older names say their line before the digits.
        let line = model.trim_end_matches(|c: char| c.is_ascii_digit() || c == ',');
        match line {
            "MacBook" | "MacBookAir" | "MacBookPro" => DeviceKind::MacBook,
            "Macmini" => DeviceKind::MacMini,
            "iMac" | "iMacPro" => DeviceKind::IMac,
            "MacPro" => DeviceKind::MacPro,
            _ => DeviceKind::Generic,
        }
    }
}

impl std::fmt::Display for DeviceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Apple silicon `MacNN,M` model identifiers (Apple's own lists, M1 Mac Studio through M4).
pub const APPLE_SILICON_MODELS: &[(&str, DeviceKind)] = &[
    ("Mac13,1", DeviceKind::MacStudio),
    ("Mac13,2", DeviceKind::MacStudio),
    ("Mac14,2", DeviceKind::MacBook),
    ("Mac14,3", DeviceKind::MacMini),
    ("Mac14,5", DeviceKind::MacBook),
    ("Mac14,6", DeviceKind::MacBook),
    ("Mac14,7", DeviceKind::MacBook),
    ("Mac14,8", DeviceKind::MacPro),
    ("Mac14,9", DeviceKind::MacBook),
    ("Mac14,10", DeviceKind::MacBook),
    ("Mac14,12", DeviceKind::MacMini),
    ("Mac14,13", DeviceKind::MacStudio),
    ("Mac14,14", DeviceKind::MacStudio),
    ("Mac14,15", DeviceKind::MacBook),
    ("Mac15,3", DeviceKind::MacBook),
    ("Mac15,4", DeviceKind::IMac),
    ("Mac15,5", DeviceKind::IMac),
    ("Mac15,6", DeviceKind::MacBook),
    ("Mac15,7", DeviceKind::MacBook),
    ("Mac15,8", DeviceKind::MacBook),
    ("Mac15,9", DeviceKind::MacBook),
    ("Mac15,10", DeviceKind::MacBook),
    ("Mac15,11", DeviceKind::MacBook),
    ("Mac15,12", DeviceKind::MacBook),
    ("Mac15,13", DeviceKind::MacBook),
    ("Mac15,14", DeviceKind::MacStudio),
    ("Mac16,1", DeviceKind::MacBook),
    ("Mac16,2", DeviceKind::IMac),
    ("Mac16,3", DeviceKind::IMac),
    ("Mac16,5", DeviceKind::MacBook),
    ("Mac16,6", DeviceKind::MacBook),
    ("Mac16,7", DeviceKind::MacBook),
    ("Mac16,8", DeviceKind::MacBook),
    ("Mac16,9", DeviceKind::MacStudio),
    ("Mac16,10", DeviceKind::MacMini),
    ("Mac16,11", DeviceKind::MacMini),
    ("Mac16,12", DeviceKind::MacBook),
    ("Mac16,13", DeviceKind::MacBook),
];

/// What a Linux machine says of itself, read by [`linux_facts`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LinuxFacts {
    /// A desktop session is installed (`/usr/share/xsessions`, `/usr/share/wayland-sessions`).
    pub desktop_installed: bool,
    /// A display server is up now (an X11 socket in `/tmp/.X11-unix`, a Wayland socket).
    pub display_running: bool,
    /// `/sys/class/dmi/id/chassis_type` (SMBIOS 3.0 7.4.1), when there is one.
    pub chassis_type: Option<u8>,
    /// A hypervisor or container runs it (the `hypervisor` CPU flag, a VM's DMI vendor, `/.dockerenv`).
    pub virtual_machine: bool,
    /// A cmux screen host is set up for this user ([`screen_host_installed`]): `cmux-rd linux-host
    /// enable` wrote its user unit. On a machine with no graphical session the host makes its
    /// virtual display (Xvfb) when a share starts, so before that there is no X socket to see;
    /// the unit is what says the screen can be shared.
    pub screen_host: bool,
}

impl LinuxFacts {
    /// The kind these facts tell: a desktop installed or running, or a screen host set up (its
    /// virtual display is a desktop the hub shares), is a desktop; else a laptop or desktop
    /// chassis on bare metal is; everything else (a VM, a rack, no DMI) is a server.
    pub fn kind(&self) -> DeviceKind {
        if self.desktop_installed || self.display_running || self.screen_host {
            return DeviceKind::LinuxDesktop;
        }
        // SMBIOS chassis types of a machine a person sits at: desktop, low profile, pizza box,
        // mini tower, tower, portable, laptop, notebook, hand held, all in one, sub notebook,
        // space-saving, lunch box, tablet, convertible, detachable, mini PC, stick PC.
        const PERSONAL: [u8; 18] =
            [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 30, 31, 32, 35, 36];
        match self.chassis_type {
            Some(t) if !self.virtual_machine && PERSONAL.contains(&t) => DeviceKind::LinuxDesktop,
            _ => DeviceKind::LinuxServer,
        }
    }
}

/// DMI vendor or product words of a virtual machine.
const VM_WORDS: [&str; 14] = [
    "qemu",
    "kvm",
    "vmware",
    "virtualbox",
    "innotek",
    "xen",
    "bochs",
    "parallels",
    "virtual machine",
    "amazon ec2",
    "google compute engine",
    "digitalocean",
    "openstack",
    "hetzner",
];

/// The screen host's user unit, as `cmux-rd linux-host enable` writes it under the user's
/// systemd unit directory (`cmux-rd-host`'s `linux_host/setup.rs`, `HOST_UNIT`).
pub const SCREEN_HOST_UNIT: &str = "cmux-screen-host.service";

/// Whether a cmux screen host is set up under `config_home` (`$XDG_CONFIG_HOME`, else
/// `$HOME/.config`): its user unit `systemd/user/cmux-screen-host.service` is there. One stat.
pub fn screen_host_installed(config_home: &std::path::Path) -> bool {
    config_home.join("systemd").join("user").join(SCREEN_HOST_UNIT).is_file()
}

/// This user's config home (`$XDG_CONFIG_HOME`, else `$HOME/.config`), as `cmux-rd` resolves it.
#[cfg(target_os = "linux")]
fn user_config_home() -> Option<std::path::PathBuf> {
    match std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        Some(dir) => Some(dir.into()),
        None => std::env::var_os("HOME")
            .filter(|v| !v.is_empty())
            .map(|home| std::path::PathBuf::from(home).join(".config")),
    }
}

/// Reads [`LinuxFacts`] from `root` (`/` on a real machine; a fixture directory in tests), with no
/// screen host. Only small files and directory listings: no process is started.
pub fn linux_facts(root: &std::path::Path) -> LinuxFacts {
    linux_facts_for(root, None)
}

/// [`linux_facts`], and whether a screen host is set up under `config_home` (the user's config
/// home; a fixture directory in tests).
pub fn linux_facts_for(
    root: &std::path::Path,
    config_home: Option<&std::path::Path>,
) -> LinuxFacts {
    let read = |path: &str| std::fs::read_to_string(root.join(path)).unwrap_or_default();
    let listed = |path: &str| {
        std::fs::read_dir(root.join(path)).is_ok_and(|mut entries| {
            entries.any(|e| e.is_ok_and(|e| e.file_name().to_string_lossy().ends_with(".desktop")))
        })
    };
    let has_entry = |path: &str, prefix: &str| {
        std::fs::read_dir(root.join(path)).is_ok_and(|mut entries| {
            entries.any(|e| e.is_ok_and(|e| e.file_name().to_string_lossy().starts_with(prefix)))
        })
    };
    let wayland = std::fs::read_dir(root.join("run/user")).is_ok_and(|users| {
        users.filter_map(Result::ok).any(|user| {
            std::fs::read_dir(user.path()).is_ok_and(|mut entries| {
                entries.any(|e| {
                    e.is_ok_and(|e| {
                        let name = e.file_name();
                        let name = name.to_string_lossy();
                        name.starts_with("wayland-") && !name.ends_with(".lock")
                    })
                })
            })
        })
    });
    let dmi = format!(
        "{} {}",
        read("sys/class/dmi/id/sys_vendor"),
        read("sys/class/dmi/id/product_name")
    )
    .to_ascii_lowercase();
    let cpu_flags_hypervisor = read("proc/cpuinfo")
        .lines()
        .find(|l| l.starts_with("flags"))
        .is_some_and(|l| l.split_whitespace().any(|f| f == "hypervisor"));
    LinuxFacts {
        desktop_installed: listed("usr/share/xsessions") || listed("usr/share/wayland-sessions"),
        display_running: has_entry("tmp/.X11-unix", "X") || wayland,
        chassis_type: read("sys/class/dmi/id/chassis_type").trim().parse().ok(),
        virtual_machine: cpu_flags_hypervisor
            || VM_WORDS.iter().any(|w| dmi.contains(w))
            || root.join(".dockerenv").exists()
            || !read("sys/hypervisor/type").trim().is_empty(),
        screen_host: config_home.is_some_and(screen_host_installed),
    }
}

/// This machine's own kind and, on a Mac, its model identifier. The hardware is read once per
/// process; whether a Linux machine's screen host is set up is checked on every ask (one stat),
/// so a host enabled after acpmux started makes the machine viewable without a restart.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ThisDevice {
    pub kind: DeviceKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

/// This machine's [`ThisDevice`]: the model read the first time it is asked.
#[cfg(target_os = "macos")]
pub fn this_device() -> ThisDevice {
    static THIS: std::sync::OnceLock<ThisDevice> = std::sync::OnceLock::new();
    THIS.get_or_init(|| {
        let model = mac_model();
        ThisDevice {
            kind: model.as_deref().map(DeviceKind::from_mac_model).unwrap_or(DeviceKind::Generic),
            model,
        }
    })
    .clone()
}

/// This machine's [`ThisDevice`]: the hardware and desktop read the first time it is asked,
/// the screen host on every ask.
#[cfg(target_os = "linux")]
pub fn this_device() -> ThisDevice {
    static FACTS: std::sync::OnceLock<LinuxFacts> = std::sync::OnceLock::new();
    let facts = LinuxFacts {
        screen_host: user_config_home().is_some_and(|home| screen_host_installed(&home)),
        ..FACTS.get_or_init(|| linux_facts(std::path::Path::new("/"))).clone()
    };
    ThisDevice { kind: facts.kind(), model: None }
}

/// This machine's [`ThisDevice`]: nothing tells the kind here.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn this_device() -> ThisDevice {
    ThisDevice { kind: DeviceKind::Generic, model: None }
}

/// `sysctl hw.model` (`Mac14,3`).
#[cfg(target_os = "macos")]
fn mac_model() -> Option<String> {
    let mut buffer = [0u8; 64];
    let mut size = buffer.len();
    // SAFETY: a NUL-terminated name, and sysctl writes at most `size` bytes into the live buffer.
    let rc = unsafe {
        libc::sysctlbyname(
            c"hw.model".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return None;
    }
    let text = std::ffi::CStr::from_bytes_until_nul(&buffer).ok()?.to_str().ok()?.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// The kind-to-symbol table as JSON (`{"macbook": "macbook.gen2", …}`, in [`DeviceKind::ALL`]'s
/// order): the web's copy, `webviews/src/ui/deviceGlyphKinds.json`, is this text, and a test here
/// keeps it so.
pub fn glyph_table_json() -> String {
    let rows: Vec<String> = DeviceKind::ALL
        .iter()
        .map(|k| format!("  \"{}\": \"{}\"", k.as_str(), k.symbol()))
        .collect();
    format!("{{\n{}\n}}\n", rows.join(",\n"))
}

/// What the Screen Sharing page offers for a machine of each kind.
pub mod screen;

#[cfg(test)]
mod tests;
