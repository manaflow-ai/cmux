//! Drives the real Linux desktop of this session (X11, Xvfb, Sway, GNOME,
//! ...) through `platform::linux`, for live verification on a VM:
//!
//! ```text
//! cargo run -p cmux-computer-use --example linux_live -- OUT_DIR CMD [ARGS] [; CMD ...]
//!   info | windows | apps
//!   shot NAME                      display screenshot -> OUT_DIR/NAME.png
//!   wshot TITLE NAME               window screenshot  -> OUT_DIR/NAME.png
//!   tree TITLE                     accessibility tree -> stdout (and OUT_DIR/tree.json)
//!   press TITLE ELEMENT_NAME       click the element named ELEMENT_NAME
//!   click TITLE X Y [fg]           click at a global point
//!   type TITLE TEXT [fg]           type into the window (focused / only editable element)
//!   typeel TITLE ELEMENT_NAME TEXT type into a named element
//!   setval TITLE ELEMENT_NAME TEXT set an element's value
//!   keys TITLE COMBO [fg]          press a key combo
//!   scroll TITLE X Y DY            scroll at a global point
//!   cursor X Y                     show the agent cursor there (then wait 0.5 s)
//!   launch APP_ID
//!   a11y                           list AT-SPI top-level frames
//!   perm input|screen_capture      ask the OS for a grant (portal dialogs)
//!   wait MS
//! ```
//! TITLE matches a window whose title contains it (case-insensitive), or
//! its app id.

#[cfg(target_os = "linux")]
fn main() {
    live::main();
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("linux_live runs on Linux only");
}

#[cfg(target_os = "linux")]
mod live {
    use std::path::{Path, PathBuf};
    use std::sync::Arc;

    use cmux_computer_use::cursor::{CursorEvent, CursorSink};
    use cmux_computer_use::desktop::*;
    use cmux_computer_use::keys::KeyCombo;
    use cmux_computer_use::platform::linux;

    pub fn main() {
        let args: Vec<String> = std::env::args().skip(1).collect();
        let Some((out, rest)) = args.split_first() else {
            eprintln!("usage: linux_live OUT_DIR CMD [ARGS] [; CMD ...]");
            std::process::exit(2);
        };
        let out = PathBuf::from(out);
        std::fs::create_dir_all(&out).expect("out dir");
        let desktop = linux::open().unwrap_or_else(|e| {
            eprintln!("open: {e}");
            std::process::exit(1);
        });
        let cursor = linux::cursor_overlay();
        let mut failed = false;
        for cmd in rest.split(|a| a == ";") {
            if cmd.is_empty() {
                continue;
            }
            println!("$ {}", cmd.join(" "));
            match run(&*desktop, &cursor, &out, cmd) {
                Ok(text) => println!("{text}"),
                Err(e) => {
                    failed = true;
                    println!("ERROR [{}] {e}", e.code());
                }
            }
        }
        std::process::exit(i32::from(failed));
    }

    fn window(d: &dyn Desktop, q: &str) -> DResult<Window> {
        let q = q.to_lowercase();
        d.list_windows()?
            .into_iter()
            .find(|w| w.title.to_lowercase().contains(&q) || w.app_id.to_lowercase() == q)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("no window matching {q:?}")))
    }

    fn find<'a>(e: &'a Element, name: &str) -> Option<&'a Element> {
        if e.name == name {
            return Some(e);
        }
        e.children.iter().find_map(|c| find(c, name))
    }

    fn element(d: &dyn Desktop, w: &Window, name: &str) -> DResult<String> {
        let tree = d.ui_tree(&w.id, TreeOptions::default())?;
        find(&tree.root, name)
            .map(|e| e.id.clone())
            .ok_or_else(|| DesktopError::TargetNotFound(format!("no element named {name:?}")))
    }

    fn delivery(a: Option<&String>) -> Delivery {
        if a.is_some_and(|s| s == "fg") { Delivery::Foreground } else { Delivery::Background }
    }

    fn json(v: &impl serde::Serialize) -> String {
        serde_json::to_string_pretty(v).unwrap_or_default()
    }

    fn save(path: &Path, f: &RawFrame) -> DResult<String> {
        let file = std::fs::File::create(path).map_err(|e| DesktopError::Failed(e.to_string()))?;
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), f.width, f.height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut w = enc.write_header().map_err(|e| DesktopError::Failed(e.to_string()))?;
        w.write_image_data(&f.rgba).map_err(|e| DesktopError::Failed(e.to_string()))?;
        Ok(format!(
            "{} ({}x{}, origin {:?}, scale {})",
            path.display(),
            f.width,
            f.height,
            f.origin,
            f.scale
        ))
    }

    fn arg(cmd: &[String], i: usize) -> DResult<&str> {
        cmd.get(i)
            .map(String::as_str)
            .ok_or_else(|| DesktopError::Failed(format!("{}: missing argument {i}", cmd[0])))
    }

    fn num(cmd: &[String], i: usize) -> DResult<f64> {
        arg(cmd, i)?
            .parse()
            .map_err(|_| DesktopError::Failed(format!("argument {i} is not a number")))
    }

    fn run(
        d: &dyn Desktop,
        cursor: &Arc<dyn CursorSink>,
        out: &Path,
        cmd: &[String],
    ) -> DResult<String> {
        match cmd[0].as_str() {
            "info" => Ok(format!("{}\n{}", json(&d.info()), json(&d.permissions()))),
            "windows" => Ok(json(&d.list_windows()?)),
            "apps" => Ok(json(&d.list_apps()?)),
            "shot" => save(
                &out.join(format!("{}.png", arg(cmd, 1)?)),
                &d.capture(&CaptureTarget::Display(None))?,
            ),
            "wshot" => {
                let w = window(d, arg(cmd, 1)?)?;
                save(
                    &out.join(format!("{}.png", arg(cmd, 2)?)),
                    &d.capture(&CaptureTarget::Window(w.id))?,
                )
            }
            "tree" => {
                let w = window(d, arg(cmd, 1)?)?;
                let t = d.ui_tree(&w.id, TreeOptions::default())?;
                let text = json(&t);
                let _ = std::fs::write(out.join("tree.json"), &text);
                Ok(text.lines().take(120).collect::<Vec<_>>().join("\n"))
            }
            "press" => {
                let w = window(d, arg(cmd, 1)?)?;
                let id = element(d, &w, arg(cmd, 2)?)?;
                let spec = ClickSpec {
                    button: Button::Left,
                    count: 1,
                    modifiers: vec![],
                    delivery: Delivery::Background,
                };
                Ok(json(
                    &d.click(&PointerTarget::Element { window_id: w.id, element_id: id }, &spec)?,
                ))
            }
            "click" => {
                let w = window(d, arg(cmd, 1)?)?;
                let point = Point { x: num(cmd, 2)?, y: num(cmd, 3)? };
                let spec = ClickSpec {
                    button: Button::Left,
                    count: 1,
                    modifiers: vec![],
                    delivery: delivery(cmd.get(4)),
                };
                Ok(json(&d.click(&PointerTarget::Point { window_id: w.id, point }, &spec)?))
            }
            "type" => {
                let w = window(d, arg(cmd, 1)?)?;
                Ok(json(&d.type_text(&w.id, None, arg(cmd, 2)?, delivery(cmd.get(3)))?))
            }
            "typeel" => {
                let w = window(d, arg(cmd, 1)?)?;
                let id = element(d, &w, arg(cmd, 2)?)?;
                Ok(json(&d.type_text(&w.id, Some(&id), arg(cmd, 3)?, Delivery::Background)?))
            }
            "setval" => {
                let w = window(d, arg(cmd, 1)?)?;
                let id = element(d, &w, arg(cmd, 2)?)?;
                Ok(json(&d.set_value(&w.id, &id, arg(cmd, 3)?)?))
            }
            "keys" => {
                let w = window(d, arg(cmd, 1)?)?;
                let combo = KeyCombo::parse(arg(cmd, 2)?).map_err(DesktopError::Failed)?;
                Ok(json(&d.press_keys(&w.id, &combo, delivery(cmd.get(3)))?))
            }
            "scroll" => {
                let w = window(d, arg(cmd, 1)?)?;
                let point = Point { x: num(cmd, 2)?, y: num(cmd, 3)? };
                Ok(json(&d.scroll(
                    &PointerTarget::Point { window_id: w.id, point },
                    0.0,
                    num(cmd, 4)?,
                )?))
            }
            "cursor" => {
                let at = Point { x: num(cmd, 1)?, y: num(cmd, 2)? };
                cursor.show(CursorEvent::Move {
                    session: "live".into(),
                    label: "linux_live".into(),
                    at,
                });
                std::thread::park_timeout(std::time::Duration::from_millis(500));
                Ok(format!("cursor at {at:?}"))
            }
            "launch" => Ok(json(&d.launch_app(arg(cmd, 1)?)?)),
            "a11y" => {
                let a = linux::atspi::Atspi::connect().map_err(DesktopError::Failed)?;
                let frames = a.frames(|_| linux::atspi::Coords::Screen)?;
                Ok(frames
                    .iter()
                    .map(|f| {
                        format!(
                            "pid {} {:?} {} {:?} active={}",
                            f.pid, f.name, f.role, f.extents, f.active
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n"))
            }
            "perm" => {
                d.request_permission(arg(cmd, 1)?)?;
                Ok(format!("granted; {}", json(&d.permissions())))
            }
            "wait" => {
                std::thread::park_timeout(std::time::Duration::from_millis(num(cmd, 1)? as u64));
                Ok(String::new())
            }
            other => Err(DesktopError::Failed(format!("unknown command {other}"))),
        }
    }
}
