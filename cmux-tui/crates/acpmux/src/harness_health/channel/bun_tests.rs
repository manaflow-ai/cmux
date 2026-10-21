use super::*;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "bun-roots-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path.canonicalize().unwrap())
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn bun_installation_binding_resolves_xdg_and_environment_before_defaults() {
    let f = Fixture::new();
    let home = f.0.join("home");
    let xdg = f.0.join("config");
    std::fs::create_dir(&home).unwrap();
    std::fs::create_dir(&xdg).unwrap();
    std::fs::write(
        home.join(".bunfig.toml"),
        "[install]\nglobalDir = '/wrong/global'\nglobalBinDir = '/wrong/bin'\n",
    )
    .unwrap();
    let bin = f.0.join("configured bin");
    std::fs::write(
        xdg.join(".bunfig.toml"),
        format!(
            "[install]\nglobalDir = '/config/global'\nglobalBinDir = {}\n",
            serde_json::to_string(&bin).unwrap()
        ),
    )
    .unwrap();
    let global = f.0.join("selected global");
    let env = BTreeMap::from([
        ("XDG_CONFIG_HOME", xdg.to_str().unwrap()),
        ("BUN_INSTALL_GLOBAL_DIR", global.to_str().unwrap()),
    ]);
    let roots = Roots::read(&home, |key| env.get(key).map(|v| v.to_string())).unwrap();
    assert_eq!(roots.global, global);
    assert_eq!(roots.bin, bin);
}

#[test]
fn bun_installation_binding_uses_tilde_paths_and_refuses_invalid_config_instead_of_falling_back() {
    let f = Fixture::new();
    let read = || Roots::read(&f.0, |_| None);
    let defaults = read().unwrap();
    assert_eq!(defaults.global, f.0.join(".bun/install/global"));
    std::fs::write(
        f.0.join(".bunfig.toml"),
        "[install]\nglobalDir = '~/packages'\nglobalBinDir = '~/commands'\n",
    )
    .unwrap();
    let roots = read().unwrap();
    assert_eq!(roots.global, f.0.join("packages"));
    assert_eq!(roots.bin, f.0.join("commands"));
    for text in
        ["[install]\nglobalDir = 'relative'\n", "[install]\nglobalBinDir = 12\n", "not valid toml"]
    {
        std::fs::write(f.0.join(".bunfig.toml"), text).unwrap();
        assert!(read().is_none(), "invalid binding silently selected default globals");
    }
}
