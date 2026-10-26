//! End-to-end sessions against an in-process RFB server that speaks the
//! way each guest OS's server does: macOS Screen Sharing (3.889, Apple
//! DH), Windows (VNC password, and an RFB 3.3 server), Linux TigerVNC
//! (no auth, ExtendedDesktopSize resize, VeNCrypt plain). Each test drives
//! connect, render, keyboard and pointer input, resize and reconnect.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use aes::Aes128;
use aes::cipher::{BlockDecrypt, KeyInit};
use cmux_vnc::auth::{des, md5};
use cmux_vnc::decode::encoding;
use cmux_vnc::keysym::{Key, keysym};
use cmux_vnc::message::button;
use cmux_vnc::pixel::PixelFormat;
use cmux_vnc::{Backoff, Credentials, Event, Session, SessionOptions, Transport, VncError};
use num_bigint::BigUint;

const TIMEOUT: Duration = Duration::from_secs(10);

struct Server {
    stream: TcpStream,
}

impl Server {
    fn read(&mut self, len: usize) -> Vec<u8> {
        let mut buf = vec![0; len];
        self.stream.read_exact(&mut buf).unwrap();
        buf
    }

    fn u8(&mut self) -> u8 {
        self.read(1)[0]
    }

    fn u16(&mut self) -> u16 {
        u16::from_be_bytes(self.read(2).try_into().unwrap())
    }

    fn u32(&mut self) -> u32 {
        u32::from_be_bytes(self.read(4).try_into().unwrap())
    }

    fn send(&mut self, bytes: &[u8]) {
        self.stream.write_all(bytes).unwrap();
    }

    fn send_reason(&mut self, reason: &str) {
        self.send(&(reason.len() as u32).to_be_bytes());
        self.send(reason.as_bytes());
    }

    /// Sends ServerInit with a big-endian native format (as macOS does).
    fn server_init(&mut self, width: u16, height: u16, name: &str) {
        self.send(&width.to_be_bytes());
        self.send(&height.to_be_bytes());
        let mut native = PixelFormat::RGBX;
        native.big_endian = true;
        native.red_shift = 16;
        native.blue_shift = 0;
        self.send(&native.encode());
        self.send_reason(name);
    }

    /// Reads SetPixelFormat, SetEncodings and the first update request;
    /// returns the requested format and encodings.
    fn client_setup(&mut self) -> (PixelFormat, Vec<i32>) {
        assert_eq!(self.u8(), 0, "SetPixelFormat");
        self.read(3);
        let format = PixelFormat::parse(&self.read(16).try_into().unwrap());
        assert_eq!(self.u8(), 2, "SetEncodings");
        self.read(1);
        let count = self.u16();
        let encodings = (0..count).map(|_| self.u32() as i32).collect();
        let request = self.read(10);
        assert_eq!(request[..2], [3, 0], "a full, non-incremental first request");
        (format, encodings)
    }

    /// One FramebufferUpdate rectangle header.
    fn rect(&mut self, x: u16, y: u16, w: u16, h: u16, encoding: i32) {
        for value in [x, y, w, h] {
            self.send(&value.to_be_bytes());
        }
        self.send(&encoding.to_be_bytes());
    }

    fn update_header(&mut self, count: u16) {
        self.send(&[0, 0]);
        self.send(&count.to_be_bytes());
    }

    /// A solid raw rectangle in the RGBX format the client asked for.
    fn raw_fill(&mut self, x: u16, y: u16, w: u16, h: u16, rgb: [u8; 3]) {
        self.rect(x, y, w, h, encoding::RAW);
        let pixel = [rgb[0], rgb[1], rgb[2], 0];
        let bytes: Vec<u8> = (0..usize::from(w) * usize::from(h)).flat_map(|_| pixel).collect();
        self.send(&bytes);
    }

    fn extended_desktop_size(&mut self, reason: u16, status: u16, w: u16, h: u16) {
        self.rect(reason, status, w, h, encoding::EXTENDED_DESKTOP_SIZE);
        self.send(&[1, 0, 0, 0]);
        self.send(&9u32.to_be_bytes());
        for value in [0, 0, w, h] {
            self.send(&value.to_be_bytes());
        }
        self.send(&0u32.to_be_bytes());
    }

    /// The incremental request the client sends after each update.
    fn expect_update_request(&mut self, incremental: bool) -> (u16, u16) {
        let request = self.read(10);
        assert_eq!(request[0], 3);
        assert_eq!(request[1], u8::from(incremental));
        (u16::from_be_bytes([request[6], request[7]]), u16::from_be_bytes([request[8], request[9]]))
    }
}

fn listen() -> (TcpListener, u16) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    (listener, port)
}

fn serve(
    listener: TcpListener,
    script: impl FnOnce(&mut Server) + Send + 'static,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(TIMEOUT)).unwrap();
        script(&mut Server { stream });
    })
}

fn connect(port: u16, credentials: Credentials) -> cmux_vnc::Result<Session> {
    let transport = Transport::tcp("127.0.0.1", port, TIMEOUT)?;
    Session::start(transport, &SessionOptions { credentials, ..SessionOptions::default() })
}

fn update(session: &mut Session) -> cmux_vnc::Update {
    match session.next_event().unwrap() {
        Event::Update(update) => update,
        other => panic!("expected an update, got {other:?}"),
    }
}

fn pixel(session: &Session, x: usize, y: usize) -> [u8; 4] {
    let fb = session.framebuffer();
    let at = (y * usize::from(fb.width()) + x) * 4;
    fb.pixels()[at..at + 4].try_into().unwrap()
}

fn password(text: &str) -> Credentials {
    Credentials { username: None, password: Some(text.into()) }
}

#[test]
fn linux_tigervnc_renders_takes_input_resizes_and_reconnects() {
    let (listener, port) = listen();
    let server = serve(listener.try_clone().unwrap(), |server| {
        server.send(b"RFB 003.008\n");
        assert_eq!(server.read(12), b"RFB 003.008\n");
        server.send(&[1, 1]); // one type: None
        assert_eq!(server.u8(), 1);
        server.send(&0u32.to_be_bytes()); // 3.8 always sends SecurityResult
        assert_eq!(server.u8(), 1, "shared");
        server.server_init(64, 48, "cmux devbox");
        let (format, encodings) = server.client_setup();
        assert_eq!(format, PixelFormat::RGBX);
        assert!(encodings.contains(&encoding::ZRLE));
        assert!(encodings.contains(&encoding::EXTENDED_DESKTOP_SIZE));
        assert!(!encodings.iter().any(|e| (-32..=-23).contains(e)), "no JPEG quality level");

        // First frame: layout, then a red background and a green square.
        server.update_header(3);
        server.extended_desktop_size(0, 0, 64, 48);
        server.raw_fill(0, 0, 64, 48, [255, 0, 0]);
        server.raw_fill(8, 8, 4, 4, [0, 255, 0]);
        assert_eq!(server.expect_update_request(true), (64, 48));

        // Keyboard: "a" down and up, then Return.
        assert_eq!(server.read(8), [4, 1, 0, 0, 0, 0, 0, 0x61]);
        assert_eq!(server.read(8), [4, 0, 0, 0, 0, 0, 0, 0x61]);
        assert_eq!(server.read(8), [4, 1, 0, 0, 0, 0, 0xff, 0x0d]);
        // Pointer: left button at (10, 12).
        assert_eq!(server.read(6), [5, button::LEFT, 0, 10, 0, 12]);

        // SetDesktopSize to 80x60 keeps the server's screen id.
        let resize = server.read(24);
        assert_eq!(resize[..8], [251, 0, 0, 80, 0, 60, 1, 0]);
        assert_eq!(resize[8..12], 9u32.to_be_bytes());
        server.update_header(1);
        server.extended_desktop_size(1, 0, 80, 60);
        assert_eq!(server.expect_update_request(false), (80, 60), "a full frame after a resize");

        // A refused resize leaves the size alone.
        server.read(24);
        server.update_header(1);
        server.extended_desktop_size(1, 3, 4000, 4000);
        server.expect_update_request(true);
        // Then the server goes away (a VM reboot).
    });

    let mut session = connect(port, Credentials::default()).unwrap();
    assert_eq!(session.name(), "cmux devbox");
    let first = update(&mut session);
    assert!(!first.resized);
    assert_eq!(first.damage, cmux_vnc::Rect::new(0, 0, 64, 48));
    assert!(session.resize_supported());
    assert_eq!(pixel(&session, 0, 0), [255, 0, 0, 255]);
    assert_eq!(pixel(&session, 9, 9), [0, 255, 0, 255]);

    let input = session.input();
    let a = keysym(Key::Char('a')).unwrap();
    input.key(a, true).unwrap();
    input.key(a, false).unwrap();
    input.key(keysym(Key::Enter).unwrap(), true).unwrap();
    input.pointer(10, 12, button::LEFT).unwrap();
    input.resize(80, 60, session.screens()[0].id).unwrap();
    let resized = update(&mut session);
    assert!(resized.resized);
    assert_eq!((session.framebuffer().width(), session.framebuffer().height()), (80, 60));
    input.resize(4000, 4000, 9).unwrap();
    let refused = update(&mut session);
    assert_eq!(refused.resize_refused, Some(3));
    assert_eq!(session.framebuffer().width(), 80);
    server.join().unwrap();

    // The server closed: the session ends with an I/O error, the backoff
    // retries, and a new session on the same address works.
    let error = session.next_event().unwrap_err();
    assert!(matches!(error, VncError::Io(_)), "{error}");
    let mut backoff = Backoff::default();
    assert!(backoff.after_failure(Duration::from_secs(1), &error).is_some());
    let again = serve(listener, |server| {
        server.send(b"RFB 003.008\n");
        server.read(12);
        server.send(&[1, 1]);
        server.read(1);
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(32, 32, "cmux devbox");
        server.client_setup();
        server.update_header(1);
        server.raw_fill(0, 0, 32, 32, [0, 0, 255]);
        server.expect_update_request(true);
    });
    let mut session = connect(port, Credentials::default()).unwrap();
    update(&mut session);
    assert_eq!(pixel(&session, 31, 31), [0, 0, 255, 255]);
    again.join().unwrap();
}

#[test]
fn macos_screen_sharing_apple_dh_and_vnc_password() {
    // A toy DH group keeps the test fast; real macOS uses a 128-byte prime.
    let prime: [u8; 4] = 0xFFFF_FFFBu32.to_be_bytes();
    let (listener, port) = listen();
    let server = serve(listener, move |server| {
        server.send(b"RFB 003.889\n");
        assert_eq!(server.read(12), b"RFB 003.008\n", "Apple's 3.889 is answered with 3.8");
        server.send(&[4, 30, 33, 36, 35]);
        assert_eq!(server.u8(), 30, "Apple DH when a user name is known");
        let modulus = BigUint::from_bytes_be(&prime);
        let server_secret = BigUint::from(123_456u32);
        let server_public = BigUint::from(2u8).modpow(&server_secret, &modulus).to_bytes_be();
        let mut padded = vec![0; 4 - server_public.len()];
        padded.extend_from_slice(&server_public);
        server.send(&2u16.to_be_bytes());
        server.send(&4u16.to_be_bytes());
        server.send(&prime);
        server.send(&padded);
        let mut block: [u8; 128] = server.read(128).try_into().unwrap();
        let client_public = BigUint::from_bytes_be(&server.read(4));
        let shared = client_public.modpow(&server_secret, &modulus).to_bytes_be();
        let mut shared_padded = vec![0; 4 - shared.len()];
        shared_padded.extend_from_slice(&shared);
        let cipher = Aes128::new(&md5::digest(&shared_padded).into());
        for chunk in block.chunks_exact_mut(16) {
            cipher.decrypt_block(chunk.into());
        }
        assert_eq!(&block[..4], b"leo\0");
        assert_eq!(&block[64..74], b"s3cret-pw\0");
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(16, 16, "Leo's Mac mini");
        server.client_setup();
        // macOS sends ZRLE; a solid tile.
        let mut zrle = flate2::Compress::new(flate2::Compression::default(), true);
        let mut data = Vec::with_capacity(64);
        zrle.compress_vec(&[1, 10, 20, 30], &mut data, flate2::FlushCompress::Sync).unwrap();
        server.update_header(1);
        server.rect(0, 0, 16, 16, encoding::ZRLE);
        server.send(&(data.len() as u32).to_be_bytes());
        server.send(&data);
        server.expect_update_request(true);
        // Command-Q from the viewer arrives as Super_L + q.
        assert_eq!(server.read(8), [4, 1, 0, 0, 0, 0, 0xff, 0xeb]);
        assert_eq!(server.read(8), [4, 1, 0, 0, 0, 0, 0, b'q']);
    });
    let credentials =
        Credentials { username: Some("leo".into()), password: Some("s3cret-pw".into()) };
    let mut session = connect(port, credentials).unwrap();
    assert_eq!(session.server_init().security, 30);
    update(&mut session);
    assert_eq!(pixel(&session, 15, 15), [10, 20, 30, 255]);
    let input = session.input();
    input.key(keysym(Key::Super).unwrap(), true).unwrap();
    input.key(keysym(Key::Char('q')).unwrap(), true).unwrap();
    server.join().unwrap();

    // Without a user name the client says what it needs, without retrying.
    let (listener, port) = listen();
    let server = serve(listener, |server| {
        server.send(b"RFB 003.889\n");
        server.read(12);
        server.send(&[1, 30]);
    });
    let error = connect(port, password("pw")).err().unwrap();
    assert!(matches!(error, VncError::CredentialsRequired { username: true }), "{error}");
    assert_eq!(Backoff::default().after_failure(Duration::ZERO, &error), None);
    server.join().unwrap();
}

#[test]
fn windows_vnc_password_success_and_refusal() {
    for (typed, correct) in [("hunter22", true), ("wrong", false)] {
        let (listener, port) = listen();
        let server = serve(listener, move |server| {
            server.send(b"RFB 003.008\n");
            server.read(12);
            server.send(&[1, 2]);
            assert_eq!(server.u8(), 2);
            let challenge: [u8; 16] = core::array::from_fn(|i| (i * 7) as u8);
            server.send(&challenge);
            let response: [u8; 16] = server.read(16).try_into().unwrap();
            if response == des::vnc_response(b"hunter22", challenge) {
                server.send(&0u32.to_be_bytes());
                server.read(1);
                server.server_init(8, 8, "DESKTOP-WIN11");
                server.client_setup();
                // TightVNC prefers Tight: a fill.
                server.update_header(1);
                server.rect(0, 0, 8, 8, encoding::TIGHT);
                server.send(&[0x80, 1, 2, 3]);
                server.expect_update_request(true);
                // Clipboard both ways.
                server.send(&[3, 0, 0, 0, 0, 0, 0, 5]);
                server.send(b"hello");
                assert_eq!(server.read(8), [6, 0, 0, 0, 0, 0, 0, 3]);
                assert_eq!(server.read(3), b"caf");
            } else {
                server.send(&1u32.to_be_bytes());
                server.send_reason("Authentication failed");
            }
        });
        let result = connect(port, password(typed));
        if correct {
            let mut session = result.unwrap();
            update(&mut session);
            assert_eq!(pixel(&session, 7, 7), [1, 2, 3, 255]);
            assert_eq!(session.next_event().unwrap(), Event::Clipboard("hello".into()));
            session.input().clipboard("caf").unwrap();
        } else {
            let error = result.err().unwrap();
            assert!(
                matches!(&error, VncError::AuthFailed(reason) if reason == "Authentication failed"),
                "{error}"
            );
            assert!(error.is_auth());
        }
        server.join().unwrap();
    }
}

#[test]
fn rfb_3_3_server_picks_the_security_type() {
    let (listener, port) = listen();
    let server = serve(listener, |server| {
        server.send(b"RFB 003.003\n");
        assert_eq!(server.read(12), b"RFB 003.003\n");
        server.send(&2u32.to_be_bytes());
        let challenge = [9u8; 16];
        server.send(&challenge);
        assert_eq!(server.read(16), des::vnc_response(b"pw", challenge));
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(4, 4, "UltraVNC");
        server.client_setup();
        server.update_header(2);
        server.raw_fill(0, 0, 4, 4, [7, 7, 7]);
        server.rect(0, 0, 0, 0, encoding::LAST_RECT);
        server.expect_update_request(true);
        // A bell, then a DesktopSize resize.
        server.send(&[2]);
        server.update_header(1);
        server.rect(0, 0, 6, 5, encoding::DESKTOP_SIZE);
        server.expect_update_request(false);
    });
    let mut session = connect(port, password("pw")).unwrap();
    update(&mut session);
    assert_eq!(pixel(&session, 3, 3), [7, 7, 7, 255]);
    assert_eq!(session.next_event().unwrap(), Event::Bell);
    let resized = update(&mut session);
    assert!(resized.resized);
    assert!(!session.resize_supported(), "no ExtendedDesktopSize: scale locally");
    assert_eq!((session.framebuffer().width(), session.framebuffer().height()), (6, 5));
    server.join().unwrap();
}

#[test]
fn tigervnc_vencrypt_plain() {
    let (listener, port) = listen();
    let server = serve(listener, |server| {
        server.send(b"RFB 003.008\n");
        server.read(12);
        server.send(&[1, 19]);
        assert_eq!(server.u8(), 19);
        server.send(&[0, 2]);
        assert_eq!(server.read(2), [0, 2]);
        server.send(&[0, 3]);
        for subtype in [262u32, 259, 256] {
            server.send(&subtype.to_be_bytes());
        }
        assert_eq!(server.u32(), 256);
        assert_eq!(server.u32(), 3);
        assert_eq!(server.u32(), 2);
        assert_eq!(server.read(5), b"bobpw");
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(2, 2, "x11");
        server.client_setup();
    });
    let credentials = Credentials { username: Some("bob".into()), password: Some("pw".into()) };
    let session = connect(port, credentials).unwrap();
    assert_eq!(session.server_init().security, 19);
    server.join().unwrap();
}

#[test]
fn hostile_servers_end_with_protocol_errors() {
    // A framebuffer far past the limit.
    let (listener, port) = listen();
    let server = serve(listener, |server| {
        server.send(b"RFB 003.008\n");
        server.read(12);
        server.send(&[1, 1]);
        server.read(1);
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(60000, 60000, "huge");
    });
    assert!(matches!(connect(port, Credentials::default()), Err(VncError::Protocol(_))));
    server.join().unwrap();

    // A rectangle outside the framebuffer.
    let (listener, port) = listen();
    let server = serve(listener, |server| {
        server.send(b"RFB 003.008\n");
        server.read(12);
        server.send(&[1, 1]);
        server.read(1);
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(4, 4, "bad");
        server.client_setup();
        server.update_header(1);
        server.rect(2, 2, 4, 4, encoding::RAW);
    });
    let mut session = connect(port, Credentials::default()).unwrap();
    assert!(matches!(session.next_event(), Err(VncError::Protocol(_))));
    server.join().unwrap();

    // Not an RFB server at all.
    let (listener, port) = listen();
    let server = serve(listener, |server| server.send(b"SSH-2.0-Open"));
    assert!(matches!(connect(port, Credentials::default()), Err(VncError::Protocol(_))));
    server.join().unwrap();
}

#[test]
fn close_unblocks_the_reader() {
    let (listener, port) = listen();
    let server = serve(listener, |server| {
        server.send(b"RFB 003.008\n");
        server.read(12);
        server.send(&[1, 1]);
        server.read(1);
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(2, 2, "idle");
        server.client_setup();
        // Then nothing: the client is waiting in next_event.
        let mut rest = Vec::new();
        let _ = server.stream.read_to_end(&mut rest);
    });
    let mut session = connect(port, Credentials::default()).unwrap();
    let input = session.input();
    let reader = thread::spawn(move || session.next_event().is_err());
    input.close();
    assert!(reader.join().unwrap());
    server.join().unwrap();
}

#[test]
fn a_graceful_close_sends_queued_input_first() {
    let (listener, port) = listen();
    let (rest_tx, rest_rx) = std::sync::mpsc::channel();
    let server = serve(listener, move |server| {
        server.send(b"RFB 003.008\n");
        server.read(12);
        server.send(&[1, 1]);
        server.read(1);
        server.send(&0u32.to_be_bytes());
        server.read(1);
        server.server_init(2, 2, "idle");
        server.client_setup();
        let mut rest = Vec::new();
        let _ = server.stream.read_to_end(&mut rest);
        rest_tx.send(rest).unwrap();
    });
    let session = connect(port, Credentials::default()).unwrap();
    let input = session.input();
    input.keys(&[(0xFFE3, true), (0xFFE3, false)]).unwrap();
    input.close_after_pending(Duration::from_secs(5));
    server.join().unwrap();
    let expected =
        [cmux_vnc::message::key_event(0xFFE3, true), cmux_vnc::message::key_event(0xFFE3, false)]
            .concat();
    assert_eq!(rest_rx.recv().unwrap(), expected);
}

/// A proxy command gets stdin's end and time to forward the last input
/// before it is stopped; killing it at once would lose the bytes (the
/// proxy here starts reading only after a delay).
#[cfg(unix)]
#[test]
fn finishing_a_proxy_lets_it_forward_what_was_written() {
    let dir = std::env::temp_dir().join(format!("cmux-vnc-drain-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = dir.join("forwarded");
    let (transport, _stderr) =
        Transport::command(&format!("sleep 0.3; cat > '{}'", out.display())).unwrap();
    let closer = transport.closer();
    let Transport { mut reader, mut writer, .. } = transport;
    writer.write_all(b"key-up").unwrap();
    writer.flush().unwrap();
    drop(writer);
    let drain = thread::spawn(move || {
        let mut rest = Vec::new();
        let _ = reader.read_to_end(&mut rest);
    });
    closer.finish(Duration::from_secs(5));
    drain.join().unwrap();
    assert_eq!(std::fs::read(&out).unwrap(), b"key-up");
    let _ = std::fs::remove_dir_all(&dir);
}
