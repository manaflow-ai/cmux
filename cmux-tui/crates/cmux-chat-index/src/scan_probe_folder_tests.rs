use super::is_probe_folder;

/// The temp fallback, by its name with this user's uid and by the older name without it.
#[test]
fn the_probe_folders_are_known_by_their_names() {
    for probe in [
        "/var/folders/xy/T/acpmux-unattended",
        "/private/var/folders/xy/T/acpmux-unattended-501",
        "/tmp/acpmux-unattended-0",
    ] {
        assert!(is_probe_folder(probe), "{probe} is a probe folder");
    }
    for person in [
        "/Users/a/code/unattended",
        "/Users/a/acpmux-unattended-notes",
        "/tmp/acpmux-unattended-",
        "/tmp/acpmux-unattended-501/app",
    ] {
        assert!(!is_probe_folder(person), "{person} is a person's folder");
    }
}
