use super::*;

#[test]
fn a_bare_program_name_is_tried_in_each_path_entry_and_a_path_as_it_is() {
    let env = vec![b"HOME=/".to_vec(), b"PATH=/nonexistent-cmux-dir::bin:/usr/bin".to_vec()];
    let tried = program_candidates(b"sh", &env).unwrap();
    let tried: Vec<&[u8]> = tried.iter().map(|path| path.to_bytes()).collect();
    assert_eq!(tried, [&b"/nonexistent-cmux-dir/sh"[..], b"./sh", b"bin/sh", b"/usr/bin/sh"]);
    let default = program_candidates(b"sh", &[]).unwrap();
    let default: Vec<&[u8]> = default.iter().map(|path| path.to_bytes()).collect();
    assert_eq!(default, [&b"/usr/bin/sh"[..], b"/bin/sh"]);
    let named = program_candidates(b"/bin/sh", &env).unwrap();
    assert_eq!(named.len(), 1);
    assert_eq!(named[0].to_bytes(), b"/bin/sh");
    assert!(program_candidates(b"", &env).is_err());
}

#[test]
fn a_pty_open_that_fails_names_the_open_ptys_and_the_limit() {
    let table = pty_table();
    assert!(table.contains(" PTYs open of "), "{table}");
    let refused = [libc::ENXIO, libc::EAGAIN, -6];
    assert_eq!(PTY_OPEN_REFUSED_FOR_A_MOMENT, refused);
    // The waits sum to about 0.3 s: 1+2+4+8+16+32 ms, then 64 ms each.
    let waited: u64 = (0..PTY_OPEN_SECOND_TRIES).map(|try_| 1u64 << try_.min(6)).sum();
    assert_eq!(waited, 319);
}

#[test]
fn many_ptys_opened_in_a_row_all_open() {
    let mut kept = Vec::new();
    for _ in 0..32 {
        let (mut master, mut slave) = (-1, -1);
        let mut size = libc::winsize { ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0 };
        open_pty(&mut master, &mut slave, &mut size).expect("a PTY opens");
        // SAFETY: open_pty returned two fresh descriptors this test owns.
        kept.push(unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) });
    }
    assert_eq!(kept.len(), 32);
}
