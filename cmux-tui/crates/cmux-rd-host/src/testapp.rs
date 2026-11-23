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

pub fn run(opts: &Opts) -> Res<()> {
    let display = opts.str_or("display", ":99");
    let kind = Kind::parse(&opts.str_or("workload", "marker"))?;
    if opts.get("die-with-parent") == Some("1") {
        // SAFETY: prctl with a signal number; affects only this process.
        unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) };
    }

    let (conn, screen_num) = x11rb::connect(Some(&display))?;
    let screen = conn.setup().roots[screen_num].clone();
    // `--origin X,Y` puts the window's corner (and the marker) there, filling the rest of the
    // screen: a marker on one monitor of several (the host's monitor pick).
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
    let (w, h) = (screen.width_in_pixels - x, screen.height_in_pixels - y);
    let win = conn.generate_id()?;
    let aux = CreateWindowAux::new()
        .override_redirect(1)
        .background_pixel(crate::workload::GRAY)
        .event_mask(EventMask::KEY_PRESS | EventMask::BUTTON_PRESS | EventMask::EXPOSURE);
    conn.create_window(
        screen.root_depth,
        win,
        screen.root,
        x as i16,
        y as i16,
        w,
        h,
        0,
        WindowClass::INPUT_OUTPUT,
        screen.root_visual,
        &aux,
    )?;
    conn.map_window(win)?;
    conn.set_input_focus(InputFocus::POINTER_ROOT, win, CURRENT_TIME)?;

    let mut painter = Painter::new(&conn, &screen, win, kind)?;
    let mut counter: u32 = 0;
    painter.full_redraw(counter)?;
    // Round trip: the server has processed the map, focus, and first frame.
    conn.get_input_focus()?.reply()?;
    println!("ready {w}x{h} {}", kind.name());
    std::io::stdout().flush()?;

    let fd = conn.stream().as_raw_fd();
    let interval = painter.interval_ns();
    let mut next_tick = interval.map(|iv| now_ns() + iv);
    loop {
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
        let timeout = next_tick.map(|t| t.saturating_sub(now_ns()));
        wait_readable(&[fd], timeout)?;
    }
}

/// `X,Y` in screen pixels.
fn parse_origin(value: &str) -> Res<(u16, u16)> {
    let bad = || format!("--origin wants X,Y in pixels, got {value:?}");
    let (x, y) = value.split_once(',').ok_or_else(bad)?;
    Ok((x.trim().parse().map_err(|_| bad())?, y.trim().parse().map_err(|_| bad())?))
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
}
