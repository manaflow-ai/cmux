//! `rdhost testapp`: one undecorated full-screen X11 window with the marker and a workload.
//! The marker counter increments on every KeyPress and is redrawn inside the event loop at once.

use crate::args::Opts;
use crate::clock::now_ns;
use crate::fdwait::wait_readable;
use crate::workload::{Kind, Painter};
use crate::Res;
use std::io::Write;
use std::os::fd::AsRawFd;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    ConnectionExt as _, CreateWindowAux, EventMask, InputFocus, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::CURRENT_TIME;

/// `WxH+X+Y`, as X geometry strings are written.
fn parse_geometry(text: &str) -> Result<(i16, i16, u16, u16), String> {
    let bad = || format!("--geometry {text}: WxH+X+Y");
    let (size, at) = text.split_once('+').ok_or_else(bad)?;
    let (w, h) = size.split_once('x').ok_or_else(bad)?;
    let (x, y) = at.split_once('+').ok_or_else(bad)?;
    let num = |s: &str| s.trim().parse::<u16>().map_err(|_| bad());
    let (w, h, x, y) = (num(w)?, num(h)?, num(x)?, num(y)?);
    if w == 0 || h == 0 || x > i16::MAX as u16 || y > i16::MAX as u16 {
        return Err(bad());
    }
    Ok((x as i16, y as i16, w, h))
}

pub fn run(opts: &Opts) -> Res<()> {
    let display = opts.str_or("display", ":99");
    let kind = Kind::parse(&opts.str_or("workload", "marker"))?;
    if opts.get("die-with-parent") == Some("1") {
        // SAFETY: prctl with a signal number; affects only this process.
        unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) };
    }

    let (conn, screen_num) = x11rb::connect(Some(&display))?;
    let screen = conn.setup().roots[screen_num].clone();
    // `--geometry WxH+X+Y`: a titled, managed window there (a window share's test); else an
    // undecorated window from `--origin X,Y` (default 0,0) to the screen's far corner, which puts
    // the marker on one monitor of several (the host's monitor pick).
    let geometry = opts.get("geometry").map(parse_geometry).transpose()?;
    let (x, y, w, h) = match geometry {
        Some(g) => g,
        None => {
            let (x, y) = match opts.get("origin") {
                Some(v) => parse_origin(v)?,
                None => (0, 0),
            };
            if x >= screen.width_in_pixels || y >= screen.height_in_pixels {
                return Err(format!(
                    "--origin {x},{y} is off the {}x{} screen",
                    screen.width_in_pixels, screen.height_in_pixels
                )
                .into());
            }
            (x as i16, y as i16, screen.width_in_pixels - x, screen.height_in_pixels - y)
        }
    };
    let win = conn.generate_id()?;
    let aux = CreateWindowAux::new()
        .override_redirect(u32::from(geometry.is_none()))
        .background_pixel(crate::workload::GRAY)
        .event_mask(EventMask::KEY_PRESS | EventMask::BUTTON_PRESS | EventMask::EXPOSURE);
    conn.create_window(
        screen.root_depth,
        win,
        screen.root,
        x,
        y,
        w,
        h,
        0,
        WindowClass::INPUT_OUTPUT,
        screen.root_visual,
        &aux,
    )?;
    if geometry.is_some() {
        use x11rb::protocol::xproto::{AtomEnum, PropMode};
        use x11rb::wrapper::ConnectionExt as _;
        conn.change_property8(
            PropMode::REPLACE,
            win,
            AtomEnum::WM_NAME,
            AtomEnum::STRING,
            b"cmux-rd testapp",
        )?;
    }
    conn.map_window(win)?;
    conn.set_input_focus(InputFocus::POINTER_ROOT, win, CURRENT_TIME)?;

    let mut painter = Painter::new(&conn, &screen, win, kind)?;
    let mut counter: u32 = 0;
    painter.full_redraw(counter)?;
    // Round trip: the server has processed the map, focus, and first frame.
    conn.get_input_focus()?.reply()?;
    println!("ready {w}x{h} {} window {win:#x}", kind.name());
    std::io::stdout().flush()?;

    let fd = conn.stream().as_raw_fd();
    let interval = painter.interval_ns();
    let mut next_tick = interval.map(|iv| now_ns() + iv);
    // `--wander-ms N` (with `--geometry`): the window moves 40,30 pixels and back every N ms,
    // so a window share's follow is seen live.
    let wander_ns = opts.num_or::<u64>("wander-ms", 0)? * 1_000_000;
    let mut next_wander = (wander_ns > 0 && geometry.is_some()).then(|| now_ns() + wander_ns);
    let mut wandered = false;
    loop {
        if let Some(t) = next_wander.filter(|&t| now_ns() >= t) {
            use x11rb::protocol::xproto::ConfigureWindowAux;
            wandered = !wandered;
            let d = i32::from(wandered);
            let aux = ConfigureWindowAux::new().x(i32::from(x) + 40 * d).y(i32::from(y) + 30 * d);
            conn.configure_window(win, &aux)?;
            conn.flush()?;
            next_wander = Some(t + wander_ns);
        }
        let mut dirty_marker = false;
        let mut redraw = false;
        while let Some(ev) = conn.poll_for_event()? {
            match ev {
                // A click counts too: a click bumps only the window it lands on, which proves
                // where the host put the pointer (a monitor pick maps it through its origin).
                Event::KeyPress(_) | Event::ButtonPress(_) => {
                    counter = counter.wrapping_add(1);
                    dirty_marker = true;
                }
                Event::Expose(e) if e.count == 0 => redraw = true,
                _ => {}
            }
        }
        if redraw {
            painter.full_redraw(counter)?;
        } else if dirty_marker {
            painter.marker(counter)?;
        }
        if redraw || dirty_marker {
            conn.flush()?;
        }
        if let (Some(iv), Some(t)) = (interval, next_tick) {
            let now = now_ns();
            if now >= t {
                painter.tick(counter)?;
                conn.flush()?;
                // Keep cadence; if we fell behind by more than a tick, resynchronize.
                next_tick = Some(if now - t > iv { now + iv } else { t + iv });
                continue;
            }
        }
        let timeout = [next_tick, next_wander]
            .into_iter()
            .flatten()
            .min()
            .map(|t| t.saturating_sub(now_ns()));
        wait_readable(&[fd], timeout)?;
    }
}

/// `X,Y` in screen pixels.
fn parse_origin(value: &str) -> Res<(u16, u16)> {
    let bad = || format!("--origin wants X,Y in pixels, got {value:?}");
    let (x, y) = value.split_once(',').ok_or_else(bad)?;
    let (x, y): (u16, u16) =
        (x.trim().parse().map_err(|_| bad())?, y.trim().parse().map_err(|_| bad())?);
    if x > i16::MAX as u16 || y > i16::MAX as u16 {
        return Err(bad().into());
    }
    Ok((x, y))
}

#[cfg(test)]
mod tests {
    #[test]
    fn origin_is_two_pixel_numbers() {
        assert_eq!(super::parse_origin("1920,0").unwrap(), (1920, 0));
        assert_eq!(super::parse_origin(" 8 , 16 ").unwrap(), (8, 16));
        assert!(super::parse_origin("1920").is_err());
        assert!(super::parse_origin("-1,0").is_err());
    }

    #[test]
    fn geometry_reads_as_x_writes_it() {
        assert_eq!(super::parse_geometry("800x600+200+150"), Ok((200, 150, 800, 600)));
        assert!(super::parse_geometry("800x600").is_err());
        assert!(super::parse_geometry("0x600+0+0").is_err());
    }
}
