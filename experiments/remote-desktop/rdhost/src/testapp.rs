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
    let (w, h) = (screen.width_in_pixels, screen.height_in_pixels);
    let win = conn.generate_id()?;
    let aux = CreateWindowAux::new()
        .override_redirect(1)
        .background_pixel(crate::workload::GRAY)
        .event_mask(EventMask::KEY_PRESS | EventMask::EXPOSURE);
    conn.create_window(screen.root_depth, win, screen.root, 0, 0, w, h, 0, WindowClass::INPUT_OUTPUT, screen.root_visual, &aux)?;
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
                Event::KeyPress(_) => {
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
