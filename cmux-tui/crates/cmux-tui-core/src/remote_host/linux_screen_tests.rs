use super::linux_screen::{device_id_in, host_dir};
use std::path::PathBuf;

const ID: &str = "550e8400-e29b-41d4-a716-446655440000";

/// A screen host folder of its own, removed when dropped.
struct Host(PathBuf);

impl Host {
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn host(files: &[(&str, &str)]) -> Host {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("cmux-linux-screen-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (name, body) in files {
        std::fs::write(dir.join(name), body).unwrap();
    }
    Host(dir)
}

#[test]
fn a_signed_in_linux_host_names_its_device_as_the_screen() {
    let upper = ID.to_uppercase();
    let dir = host(&[
        ("device.json", &format!(r#"{{"id":"{upper}","name":"box"}}"#)),
        ("account.json", "{}"),
    ]);
    assert_eq!(device_id_in(dir.path()).as_deref(), Some(ID));
}

#[test]
fn a_host_that_never_signed_in_or_signed_out_names_no_screen() {
    let device = format!(r#"{{"id":"{ID}"}}"#);
    assert_eq!(device_id_in(host(&[("device.json", &device)]).path()), None);
    assert_eq!(device_id_in(host(&[("account.json", "{}")]).path()), None);
    assert_eq!(device_id_in(host(&[]).path()), None);
}

#[test]
fn a_device_record_that_is_not_a_uuid_names_no_screen() {
    for body in [r#"{"id":"studio-mac"}"#, r#"{"id":7}"#, "not json", "{}"] {
        assert_eq!(
            device_id_in(host(&[("device.json", body), ("account.json", "{}")]).path()),
            None,
            "{body}"
        );
    }
}

#[test]
fn the_host_folder_follows_cmux_rd_config_dir() {
    assert_eq!(
        host_dir(Some("/x/cfg".into()), Some("/home/u".into())),
        Some(PathBuf::from("/x/cfg/cmux/screen-host"))
    );
    assert_eq!(
        host_dir(None, Some("/home/u".into())),
        Some(PathBuf::from("/home/u/.config/cmux/screen-host"))
    );
    // An empty XDG_CONFIG_HOME counts as unset, as cmux-rd reads it.
    assert_eq!(
        host_dir(Some("".into()), Some("/home/u".into())),
        Some(PathBuf::from("/home/u/.config/cmux/screen-host"))
    );
    assert_eq!(host_dir(None, None), None);
}
