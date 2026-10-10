//! Resize replay and kitty image alias state.

use {super::*, crate::local_actor::TuiMuxOps};

#[cfg(unix)]
#[test]
fn real_server_attach_and_resize_preserve_kitty_number_aliases() {
    let mux = cmux_tui_core::Mux::new(
        format!("remote-kitty-aliases-{}", std::process::id()),
        cmux_tui_core::SurfaceOptions {
            command: Some(vec!["/bin/cat".to_string()]),
            ..Default::default()
        },
    );
    let authoritative = mux.new_workspace(None, Some((20, 4))).unwrap();
    authoritative
        .try_with_terminal(|terminal| {
            terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,I=77,s=1,v=1,q=2;/wAA\x1b\\");
        })
        .unwrap();
    let image_id = authoritative
        .try_with_terminal(|terminal| terminal.kitty_graphics_snapshot().unwrap().images[0].id)
        .unwrap();

    let socket = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let remote = RemoteSession::connect(&socket).unwrap();
    let mirror = attached_surface(
        remote
            .try_ensure_surface_with_kind(authoritative.id, SurfaceKind::Pty, Some((20, 4)))
            .unwrap(),
    );

    let wait_for = |mut predicate: Box<dyn FnMut() -> bool>| {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !predicate() {
            assert!(Instant::now() < deadline, "remote mirror did not converge");
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    wait_for(Box::new({
        let mirror = mirror.clone();
        move || {
            mirror
                .term
                .lock()
                .unwrap()
                .kitty_graphics_snapshot()
                .unwrap()
                .image(image_id)
                .is_some_and(|image| image.number == 77)
        }
    }));

    mux.resize_surface(authoritative.id, 21, 4).unwrap();
    wait_for(Box::new({
        let mirror = mirror.clone();
        move || {
            let terminal = mirror.term.lock().unwrap();
            terminal.cols() == 21
                && terminal
                    .kitty_graphics_snapshot()
                    .unwrap()
                    .image(image_id)
                    .is_some_and(|image| image.number == 77)
        }
    }));

    authoritative.write_bytes(b"\x1b_Ga=p,I=77,p=12,c=1,r=1,q=2;\x1b\\\n").unwrap();
    wait_for(Box::new({
        move || {
            mirror
                .term
                .lock()
                .unwrap()
                .kitty_graphics_snapshot()
                .unwrap()
                .placements
                .iter()
                .any(|placement| placement.image_id == image_id && placement.placement_id == 12)
        }
    }));

    remote.begin_shutdown();
    let _ = mux.close_surface(authoritative.id);
    cmux_tui_core::server::cleanup(&socket);
}
