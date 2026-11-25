//! Reads stage 0's plan from a support folder through the C entry the app calls, and prints it.
//! A readback for the PR and for checking a real folder; it changes nothing it reads.
//!
//! ```text
//! cargo run -p cmux-launch-shell --example plan_readback -- fixture DIR image|plain|fresh|upgrade
//! cargo run -p cmux-launch-shell --example plan_readback -- plan DIR [BUILD]
//! ```
//!
//! `plan DIR` reads `DIR/launch-record.bin` and `DIR/launch-images/` with one 1512x982 @2x display,
//! dark appearance and no session check. `fixture` writes a test folder; it never writes into a
//! folder that already exists.
use std::ffi::{CString, c_char};
use std::path::Path;
use std::process::ExitCode;

use cmux_launch_record::{Frame, LaunchRecordData, WindowRecord, write_atomic};
use cmux_launch_shell::ffi::{
    CmuxLaunchShellDisplay, CmuxLaunchShellNow, CmuxLaunchShellPlan, cmux_launch_shell_plan,
};

const BUILD: &str = "4294.readback";

fn window() -> WindowRecord {
    WindowRecord {
        id: "w1".into(),
        frame: Frame { x: 100.0, y: 80.0, width: 1100.0, height: 720.0 },
        display_id: 1,
        background_rgba: [20, 20, 24, 255],
        bar_rgba: [30, 30, 36, 255],
        image_key: format!("{BUILD}/w1/7"),
        image_pixel_width: 2200,
        image_pixel_height: 1440,
        backing_scale: 2.0,
        appearance: 1,
        appearance_follows_system: 1,
        fullscreen: 0,
        screen_frame: Frame { x: 0.0, y: 0.0, width: 1512.0, height: 982.0 },
        visible_workspace_id: "ws".into(),
        visible_tab_ids: vec![],
    }
}

/// A PNG's signature and IHDR: all the plan reads of an image.
fn png(width: u32, height: u32) -> Vec<u8> {
    let mut b = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    b.extend(width.to_be_bytes());
    b.extend(height.to_be_bytes());
    b.extend([8, 6, 0, 0, 0]);
    b
}

fn fixture(dir: &Path, kind: &str) -> std::io::Result<()> {
    std::fs::create_dir(dir)?;
    std::fs::create_dir(dir.join("launch-images"))?;
    let record = LaunchRecordData {
        windows: vec![window()],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
        session_registry_id: String::new(),
    };
    match kind {
        "image" => {
            write_atomic(dir.join("launch-record.bin"), &record)?;
            std::fs::write(dir.join("launch-images/w1.7.png"), png(2200, 1440))
        }
        "plain" => write_atomic(dir.join("launch-record.bin"), &record),
        "fresh" => Ok(()),
        "upgrade" => std::fs::write(dir.join("launch-times.jsonl"), b"{}\n"),
        _ => Err(std::io::Error::other(format!("unknown fixture {kind}"))),
    }
}

fn text(field: &[c_char]) -> String {
    let bytes: Vec<u8> = field.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn reason_name(reason: u8) -> &'static str {
    match reason {
        0 => "image",
        1 => "fresh install",
        2 => "no windows",
        3 => "build differs",
        4 => "layout differs",
        5 => "scale differs",
        6 => "appearance differs",
        7 => "image unreadable",
        8 => "image size",
        9 => "full screen",
        10 => "upgrade",
        11 => "another session",
        _ => "unknown",
    }
}

fn plan(dir: &Path, build: &str) -> Option<(bool, CmuxLaunchShellPlan)> {
    let c = |p: &Path| CString::new(p.to_str()?).ok();
    let (record, images, support) =
        (c(&dir.join("launch-record.bin"))?, c(&dir.join("launch-images"))?, c(dir)?);
    let build = CString::new(build).ok()?;
    let displays =
        [CmuxLaunchShellDisplay { x: 0.0, y: 0.0, width: 1512.0, height: 982.0, scale: 2.0 }];
    let now = CmuxLaunchShellNow {
        build: build.as_ptr(),
        appearance: 1,
        displays: displays.as_ptr(),
        display_count: displays.len(),
        support_dir: support.as_ptr(),
        app_support: std::ptr::null(),
        daemon_session: std::ptr::null(),
    };
    let mut out = CmuxLaunchShellPlan::default();
    // SAFETY: every pointer is a live NUL-terminated string or the one-element display array.
    let ok = unsafe { cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), &now, &mut out) };
    Some((ok, out))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["fixture", dir, kind] => match fixture(Path::new(dir), kind) {
            Ok(()) => {
                println!("fixture {kind}: {dir}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("fixture {kind}: {e}");
                ExitCode::FAILURE
            }
        },
        ["plan", dir, rest @ ..] => {
            let build = rest.first().copied().unwrap_or(BUILD);
            let Some((ok, p)) = plan(Path::new(dir), build) else {
                eprintln!("plan: {dir} is not a UTF-8 path");
                return ExitCode::FAILURE;
            };
            println!(
                "ok={ok} reason={} ({}) shows_window={} default_frame={} bare={} frame=({}, {}, {}x{}) window={:?} image={:?}",
                p.reason,
                reason_name(p.reason),
                p.shows_window,
                p.uses_default_frame,
                p.shows_bare,
                p.frame_x,
                p.frame_y,
                p.frame_width,
                p.frame_height,
                text(&p.window_id),
                text(&p.image_path),
            );
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!(
                "usage: plan_readback fixture DIR image|plain|fresh|upgrade | plan DIR [BUILD]"
            );
            ExitCode::from(2)
        }
    }
}
