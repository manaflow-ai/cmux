//! The settings owner's watch (p04-input-084): a hint's reload runs on the
//! mux's Files lane, never on the utility `cmux-config-watch` thread, which
//! must not hold the store lock a request waits for.

use std::sync::Mutex;
use std::sync::mpsc::{Sender, channel};
use std::time::Duration;

use cmux_config::ManagedReader;
use cmux_config::managed::ManagedPreferences;

use super::SettingsPaths;
use crate::{Mux, SurfaceOptions};

/// Sends the name of every thread that reads the managed values: the
/// store's open, then each reload.
struct ReaderThreads(Mutex<Sender<String>>);

impl ManagedReader for ReaderThreads {
    fn read(&self) -> ManagedPreferences {
        let name = std::thread::current().name().unwrap_or_default().to_owned();
        let _ = self.0.lock().unwrap().send(name);
        ManagedPreferences::default()
    }
}

#[test]
fn a_watch_hint_reloads_on_the_files_lane_not_the_watch_thread() {
    let directory = cmux_unix_socket::short_test_dir("settings-watch-lane");
    let (sender, threads) = channel();
    let reader = ReaderThreads(Mutex::new(sender));
    let mux = Mux::new_for_test("settings-watch-lane", SurfaceOptions::default());
    assert!(mux.start_settings_owner(SettingsPaths {
        config: directory.path().join("cmux-next.json"),
        seed: None,
        state_dir: Some(directory.path().to_path_buf()),
        reader: Box::new(reader),
        watch: true,
    }));
    let open = threads.recv().expect("the store's open read");
    assert_ne!(open, "cmux-config-watch");
    // The watcher hints once as it starts.
    let reload = threads.recv_timeout(Duration::from_secs(10)).expect("the first hint's reload");
    assert!(reload.starts_with("mux-files-"), "the reload ran on {reload:?}");
    mux.shutdown();
}
