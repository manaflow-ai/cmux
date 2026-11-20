use super::*;

/// zsh passes preexec a `$2` that drops every word that does not fit its
/// 80-byte job text, and oh-my-zsh titles the terminal with it
/// (`/usr/bin/python3 /long/a.py /long/b.json 60` became
/// `/usr/bin/python3   60`). Ghostty's title feature runs after the
/// user's hooks and titles the running command with the full line.
#[cfg(unix)]
#[test]
fn a_daemon_integrated_zsh_titles_a_long_command_with_every_argument() {
    use std::io::Read;
    let Some(zsh) = ["/bin/zsh", "/usr/bin/zsh"].into_iter().find(|p| Path::new(p).is_file())
    else {
        eprintln!("skipped: zsh is not installed");
        return;
    };
    let base = std::env::temp_dir().join(format!(
        "cmux-tui-shell-title-test-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let user = base.join("user");
    fs::create_dir_all(&user).unwrap();
    let base = fs::canonicalize(&base).unwrap();
    let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
    // No system rc files: a distribution's global zshrc can stop at an
    // interactive compinit question.
    fs::write(user.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
    // The title hook oh-my-zsh's termsupport installs, reduced to its use
    // of zsh's `$2`.
    fs::write(user.join(".zshrc"), "PS1='$ '\npreexec() { print -rn -- $'\\e]2;'\"$2\"$'\\a' }\n")
        .unwrap();
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("ZDOTDIR".to_string(), fs::canonicalize(&user).unwrap().to_string_lossy().into_owned()),
    ];
    let lookup = {
        let env = env.clone();
        move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
    };
    let launched =
        apply(Shell::Zsh, &root, vec![zsh.into()], env, &lookup, &ghostty_files::read(&lookup));

    let pty =
        cmux_pty::open(cmux_pty::PtySize { rows: 24, cols: 200, pixel_width: 0, pixel_height: 0 })
            .unwrap();
    let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
    command.args(launched.command[1..].iter().cloned());
    command.env("TERM", "xterm-256color");
    for (key, value) in &launched.env {
        command.env(key.clone(), value.clone());
    }
    let mut spawned = pty.spawn(command).unwrap();
    let mut reader = spawned.master.try_clone_reader().unwrap();
    let mut writer = spawned.master.take_writer().unwrap();
    let (chunks, received) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut chunk = [0u8; 4096];
        // EOF, or EIO once the child side closes (Linux).
        while let Ok(n) = reader.read(&mut chunk) {
            if n == 0 || chunks.send(chunk[..n].to_vec()).is_err() {
                break;
            }
        }
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut output = Vec::new();
    let read_until = |output: &mut Vec<u8>, needle: &[u8]| {
        while !output.windows(needle.len()).any(|window| window == needle) {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            match received.recv_timeout(left) {
                Ok(chunk) => output.extend_from_slice(&chunk),
                Err(_) => panic!(
                    "no {:?} from zsh: {:?}",
                    String::from_utf8_lossy(needle),
                    String::from_utf8_lossy(output)
                ),
            }
        }
    };
    // Type the command at the prompt, as a user does: input typed before
    // the line editor starts can lose characters.
    read_until(&mut output, b"$ ");
    // The command's first output (`r92-42`) differs from its echoed
    // text (`r92-$((40+2))`), so it marks the moment it runs.
    let line = "print -r -- r92-$((40+2)) \
                        /Users/someone/nx-jobs/jobs/r92cb-live-final/artifacts/osc52-reader.py \
                        /Users/someone/nx-jobs/jobs/r92cb-live-final/artifacts/deny-reply.json 60";
    writer.write_all(format!("{line}\n").as_bytes()).unwrap();
    read_until(&mut output, b"r92-42");
    writer.write_all(b"exit\n").unwrap();
    drop(writer);
    while spawned.child.try_wait().unwrap().is_none() {
        assert!(std::time::Instant::now() < deadline, "zsh did not exit");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    drop(spawned);

    // The title while the command runs: everything the shell wrote
    // before the command's own output (after every preexec hook),
    // parsed by the terminal the daemon reads titles from.
    let start = output.windows(6).position(|window| window == b"r92-42").unwrap();
    let mut terminal =
        ghostty_vt::Terminal::new(200, 24, 0, ghostty_vt::Callbacks::default()).unwrap();
    terminal.vt_write(&output[..start]);
    assert_eq!(terminal.title().as_deref(), Some(line));
    fs::remove_dir_all(&base).unwrap();
}
