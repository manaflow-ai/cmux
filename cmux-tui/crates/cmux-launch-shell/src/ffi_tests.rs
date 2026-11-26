use super::*;
use cmux_launch_record::{LaunchRecordData, WindowRecord, write_atomic};
use std::ffi::CString;
use std::path::PathBuf;

const BUILD: &str = "4294.abc123";

/// A support folder for one test, removed on drop.
struct Support(PathBuf);
impl Support {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir()
            .join(format!("cmux-launch-shell-ffi-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("launch-images")).unwrap();
        Self(dir)
    }
}
impl Drop for Support {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn window(id: &str) -> WindowRecord {
    WindowRecord {
        id: id.into(),
        frame: cmux_launch_record::Frame { x: 100.0, y: 80.0, width: 1100.0, height: 720.0 },
        display_id: 1,
        background_rgba: [20, 20, 24, 255],
        bar_rgba: [30, 30, 36, 255],
        image_key: format!("{BUILD}/{id}/7"),
        image_pixel_width: 2200,
        image_pixel_height: 1440,
        backing_scale: 2.0,
        appearance: 1,
        appearance_follows_system: 1,
        fullscreen: 0,
        screen_frame: cmux_launch_record::Frame { x: 0.0, y: 0.0, width: 1512.0, height: 982.0 },
        visible_workspace_id: "ws".into(),
        visible_tab_ids: vec![],
        sidebar_width: 0.0,
    }
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let mut b = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    b.extend(width.to_be_bytes());
    b.extend(height.to_be_bytes());
    b.extend([8, 6, 0, 0, 0]);
    b
}

fn plan_in(support: &Support) -> (bool, CmuxLaunchShellPlan) {
    let s = |p: PathBuf| CString::new(p.to_str().unwrap()).unwrap();
    let (record, images, dir) = (
        s(support.0.join("launch-record.bin")),
        s(support.0.join("launch-images")),
        s(support.0.clone()),
    );
    let build = CString::new(BUILD).unwrap();
    let session = CString::new("cmux-app").unwrap();
    let displays =
        [CmuxLaunchShellDisplay { x: 0.0, y: 0.0, width: 1512.0, height: 982.0, scale: 2.0 }];
    // The support folder doubles as Application Support: the registry file is under cmux-next/.
    let now = CmuxLaunchShellNow {
        build: build.as_ptr(),
        appearance: 1,
        displays: displays.as_ptr(),
        display_count: displays.len(),
        support_dir: dir.as_ptr(),
        app_support: dir.as_ptr(),
        daemon_session: session.as_ptr(),
    };
    let mut out = CmuxLaunchShellPlan::default();
    let ok = unsafe { cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), &now, &mut out) };
    (ok, out)
}

fn text(field: &[c_char]) -> String {
    let bytes: Vec<u8> = field.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    String::from_utf8(bytes).unwrap()
}

#[test]
fn a_record_with_a_current_image_plans_the_image_at_its_frame() {
    let support = Support::new("image");
    let data = LaunchRecordData {
        windows: vec![window("w1")],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
        session_registry_id: String::new(),
        written_at_ms: 0,
    };
    write_atomic(support.0.join("launch-record.bin"), &data).unwrap();
    std::fs::write(support.0.join("launch-images/w1.7.png"), png(2200, 1440)).unwrap();
    let (ok, p) = plan_in(&support);
    assert!(ok);
    assert_eq!((p.reason, p.shows_window, p.uses_default_frame), (0, true, false));
    assert_eq!((p.frame_x, p.frame_width), (100.0, 1100.0));
    assert_eq!(text(&p.window_id), "w1");
    assert_eq!(text(&p.image_path), support.0.join("launch-images/w1.7.png").to_str().unwrap());
}

#[test]
fn a_record_whose_image_is_gone_plans_the_plain_shell() {
    let support = Support::new("plain");
    let data = LaunchRecordData {
        windows: vec![window("w1")],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
        session_registry_id: String::new(),
        written_at_ms: 0,
    };
    write_atomic(support.0.join("launch-record.bin"), &data).unwrap();
    let (_, p) = plan_in(&support);
    assert_eq!((p.reason, p.shows_window), (7, true));
    assert_eq!(text(&p.image_path), "");
}

#[test]
fn no_record_is_a_fresh_install_unless_an_earlier_run_left_launch_times() {
    let support = Support::new("fresh");
    let (ok, p) = plan_in(&support);
    assert!(ok);
    assert_eq!((p.reason, p.shows_window, p.uses_default_frame), (1, true, true));
    std::fs::write(support.0.join("launch-times.jsonl"), b"{}\n").unwrap();
    let (_, p) = plan_in(&support);
    assert_eq!((p.reason, p.shows_window), (10, false));
}

#[test]
fn a_missing_argument_makes_no_window() {
    let mut out = CmuxLaunchShellPlan::default();
    assert!(!unsafe {
        cmux_launch_shell_plan(std::ptr::null(), std::ptr::null(), std::ptr::null(), &mut out)
    });
    assert!(!out.shows_window);
}

#[test]
fn a_failed_call_clears_a_reused_plan_that_showed_a_window() {
    // A plan reused from an earlier call that drew the image: a null `now` must not leave it.
    let support = Support::new("reused");
    let data = LaunchRecordData {
        windows: vec![window("w1")],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
        session_registry_id: String::new(),
        written_at_ms: 0,
    };
    write_atomic(support.0.join("launch-record.bin"), &data).unwrap();
    std::fs::write(support.0.join("launch-images/w1.7.png"), png(2200, 1440)).unwrap();
    let (ok, mut out) = plan_in(&support);
    assert!(ok && out.shows_window && !text(&out.image_path).is_empty());
    let record = CString::new(support.0.join("launch-record.bin").to_str().unwrap()).unwrap();
    assert!(!unsafe {
        cmux_launch_shell_plan(record.as_ptr(), record.as_ptr(), std::ptr::null(), &mut out)
    });
    assert!(!out.shows_window);
    assert_eq!(text(&out.image_path), "");
    assert_eq!(text(&out.window_id), "");
}

#[test]
fn the_plan_struct_has_the_headers_layout() {
    // cmux_launch_shell.h's CmuxLaunchShellPlan; launch_shell_header.rs asserts the same size in C.
    assert_eq!(std::mem::size_of::<CmuxLaunchShellPlan>(), 1200);
    assert_eq!(std::mem::offset_of!(CmuxLaunchShellPlan, shows_bare), 44);
    assert_eq!(std::mem::offset_of!(CmuxLaunchShellPlan, window_id), 45);
    assert_eq!(std::mem::offset_of!(CmuxLaunchShellPlan, image_path), 174);
}

#[test]
fn a_record_of_another_session_plans_the_plain_shell_at_the_default_frame() {
    let support = Support::new("session");
    let data = LaunchRecordData {
        windows: vec![window("w1")],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
        session_registry_id: "reg-old".into(),
        written_at_ms: 0,
    };
    write_atomic(support.0.join("launch-record.bin"), &data).unwrap();
    std::fs::write(support.0.join("launch-images/w1.7.png"), png(2200, 1440)).unwrap();
    // No registry file yet: unknown, so the image is drawn as before.
    assert_eq!(plan_in(&support).1.reason, 0);
    std::fs::create_dir_all(support.0.join("cmux-next")).unwrap();
    let registry = support.0.join("cmux-next/launch-snapshot-registry.cmux-app");
    std::fs::write(&registry, "reg-new").unwrap();
    let (_, p) = plan_in(&support);
    assert_eq!(
        (p.reason, p.shows_window, p.uses_default_frame, p.shows_bare),
        (11, true, true, false)
    );
    assert_eq!(text(&p.image_path), "");
    std::fs::write(&registry, "reg-old\n").unwrap();
    assert_eq!(plan_in(&support).1.reason, 0);
}
