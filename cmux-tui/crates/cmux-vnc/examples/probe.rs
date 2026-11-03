//! Checks a live VNC server end to end: connect, first frame, typing,
//! a pointer click, a desktop resize, and a reconnect after the server
//! goes away. Used by hand against macOS Screen Sharing, Windows and
//! TigerVNC; every step prints one `probe:` line.
//!
//! ```text
//! cargo run -p cmux-vnc --example probe -- HOST[:DISPLAY] \
//!     [--type TEXT] [--click X,Y] [--resize WxH] [--reconnect]
//! ```
//! Credentials come from `CMUX_VNC_USERNAME` and `CMUX_VNC_PASSWORD`.

use std::time::{Duration, Instant};

use cmux_vnc::keysym::{Key, char_keysym, keysym};
use cmux_vnc::message::button;
use cmux_vnc::{Backoff, Credentials, Endpoint, Event, Session, SessionOptions, Transport};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let endpoint = Endpoint::parse(args.first().ok_or("usage: probe HOST[:DISPLAY] [options]")?)?;
    let flag =
        |name: &str| args.iter().position(|arg| arg == name).and_then(|i| args.get(i + 1)).cloned();
    let credentials = Credentials {
        username: std::env::var("CMUX_VNC_USERNAME").ok(),
        password: std::env::var("CMUX_VNC_PASSWORD").ok(),
    };
    let options = SessionOptions { credentials, ..SessionOptions::default() };
    let connect = || -> cmux_vnc::Result<Session> {
        Session::start(
            Transport::tcp(&endpoint.host, endpoint.port, Duration::from_secs(10))?,
            &options,
        )
    };

    let started = Instant::now();
    let mut session = connect()?;
    let init = session.server_init().clone();
    println!(
        "probe: connected {:?} security {} name {:?} {}x{} in {:?}",
        init.version,
        init.security,
        init.name,
        init.width,
        init.height,
        started.elapsed()
    );
    let first = Instant::now();
    loop {
        if let Event::Update(update) = session.next_event()?
            && !update.damage.is_empty()
        {
            let fb = session.framebuffer();
            let lit = fb.pixels().chunks_exact(4).filter(|p| p[..3] != [0, 0, 0]).count();
            println!(
                "probe: first frame {:?} after {:?}, {lit} non-black pixels",
                update.damage,
                first.elapsed()
            );
            break;
        }
    }
    let input = session.input();

    if let Some(at) = flag("--click") {
        let (x, y) = at.split_once(',').ok_or("--click X,Y")?;
        let (x, y): (u16, u16) = (x.parse()?, y.parse()?);
        input.pointer(x, y, 0)?;
        input.pointer(x, y, button::LEFT)?;
        input.pointer(x, y, 0)?;
        println!("probe: clicked {x},{y}");
    }
    if let Some(text) = flag("--type") {
        for c in text.chars() {
            let sym = if c == '\n' { keysym(Key::Enter).unwrap_or(0xFF0D) } else { char_keysym(c) };
            input.key(sym, true)?;
            input.key(sym, false)?;
        }
        println!("probe: typed {} characters", text.chars().count());
    }
    if let Some(size) = flag("--resize") {
        let (w, h) = size.split_once('x').ok_or("--resize WxH")?;
        let (w, h): (u16, u16) = (w.parse()?, h.parse()?);
        // The server says it supports resizing in its first update's ExtendedDesktopSize.
        if session.resize_supported() {
            let id = session.screens().first().map_or(0, |s| s.id);
            input.resize(w, h, id)?;
            loop {
                if let Event::Update(update) = session.next_event()? {
                    if let Some(status) = update.resize_refused {
                        println!("probe: resize refused, status {status}");
                        break;
                    }
                    if update.resized {
                        let fb = session.framebuffer();
                        println!("probe: resized to {}x{}", fb.width(), fb.height());
                        break;
                    }
                }
            }
        } else {
            println!("probe: server does not support SetDesktopSize (the viewer scales instead)");
        }
    }

    if args.iter().any(|arg| arg == "--reconnect") {
        println!("probe: waiting for the server to go away");
        let lived = Instant::now();
        let error = loop {
            if let Err(error) = session.next_event() {
                break error;
            }
        };
        println!("probe: session ended: {error}");
        let mut backoff = Backoff::default();
        let mut delay = backoff.after_failure(lived.elapsed(), &error).ok_or("not retryable")?;
        let deadline = Instant::now() + Duration::from_secs(120);
        loop {
            std::thread::sleep(delay);
            match connect() {
                Ok(mut again) => {
                    loop {
                        if let Event::Update(update) = again.next_event()?
                            && !update.damage.is_empty()
                        {
                            break;
                        }
                    }
                    println!(
                        "probe: reconnected, frame {}x{}",
                        again.framebuffer().width(),
                        again.framebuffer().height()
                    );
                    break;
                }
                Err(error) if Instant::now() < deadline => {
                    delay = backoff.after_failure(Duration::ZERO, &error).ok_or("not retryable")?;
                    println!("probe: retry in {delay:?} ({error})");
                }
                Err(error) => return Err(error.into()),
            }
        }
    }
    println!("probe: ok");
    Ok(())
}
