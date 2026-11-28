//! `cmux-next-linux`: run the launch plan (lib.rs) and show the agent pane in a window.

use std::ffi::OsString;
use std::net::TcpStream;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::process::CommandExt;
use std::process::{Child, ExitCode};
use std::time::{Duration, Instant};

use cmux_next_linux::{Command, ParseError, Plan, USAGE, Env, free_port, fresh_token, parse_args, plan};

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let options = match parse_args(&args, &Env::from_process()) {
        Ok(o) => o,
        Err(ParseError::Help) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(ParseError::Message(m)) => {
            eprintln!("cmux-next-linux: {m}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match run(options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cmux-next-linux: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(options: cmux_next_linux::Options) -> std::io::Result<()> {
    let plan = plan(&options, free_port()?, free_port()?, fresh_token()?);
    if options.dry_run {
        println!("daemon: {}", show(&plan.daemon));
        println!("pane:   {}", show(&plan.pane));
        println!("url:    {}", plan.url.split("&token=").next().unwrap_or_default());
        return Ok(());
    }
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&options.home)?;
    let mut children = Children(Vec::new());
    children.0.push(spawn(&plan.daemon)?);
    children.0.push(spawn(&plan.pane)?);
    wait_for_port(plan.daemon_port, &mut children, "acpmux daemon")?;
    wait_for_port(plan.pane_port, &mut children, "webviews dev server")?;
    open_window(&plan, children)
}

fn show(c: &Command) -> String {
    let mut s = c.program.display().to_string();
    let mut redact = false;
    for a in &c.args {
        let a = a.to_string_lossy();
        s.push(' ');
        s.push_str(if redact { "<token>" } else { &a });
        redact = a == "--token";
    }
    s
}

fn spawn(c: &Command) -> std::io::Result<Child> {
    let mut cmd = std::process::Command::new(&c.program);
    cmd.args(&c.args).current_dir(&c.cwd).envs(c.env.iter().map(|(k, v)| (k, v)));
    for k in &c.env_remove {
        cmd.env_remove(k);
    }
    // Its own process group, so closing the window stops `bun run dev` and the Vite it starts.
    cmd.process_group(0);
    cmd.spawn()
        .map_err(|e| std::io::Error::new(e.kind(), format!("start {}: {e}", c.program.display())))
}

/// The processes this window started; stopped (their whole groups) when it goes away.
struct Children(Vec<Child>);

impl Drop for Children {
    fn drop(&mut self) {
        for child in &mut self.0 {
            if let Ok(None) = child.try_wait() {
                // The group id is the child's pid (process_group(0) above), so this reaches only
                // what this window started.
                let _ = std::process::Command::new("kill")
                    .args(["-TERM", "--", &format!("-{}", child.id())])
                    .status();
                let _ = child.wait();
            }
        }
    }
}

fn wait_for_port(port: u16, children: &mut Children, what: &str) -> std::io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Ok(());
        }
        for child in &mut children.0 {
            if let Some(status) = child.try_wait()? {
                return Err(std::io::Error::other(format!("a child exited ({status}) before the {what} listened")));
            }
        }
        if Instant::now() > deadline {
            return Err(std::io::Error::other(format!("the {what} did not listen on {port} in 90 s")));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[cfg(feature = "window")]
fn open_window(plan: &Plan, children: Children) -> std::io::Result<()> {
    use tao::event::{Event, WindowEvent};
    use tao::event_loop::{ControlFlow, EventLoop};
    use tao::platform::unix::WindowExtUnix;
    use tao::window::WindowBuilder;
    use wry::{WebViewBuilder, WebViewBuilderExtUnix};

    let event_loop = EventLoop::new();
    let window = WindowBuilder::new()
        .with_title("cmux NEXT (Linux preview)")
        .with_inner_size(tao::dpi::LogicalSize::new(1100.0, 780.0))
        .build(&event_loop)
        .map_err(std::io::Error::other)?;
    let vbox = window
        .default_vbox()
        .ok_or_else(|| std::io::Error::other("the window has no GTK box"))?;
    let webview = WebViewBuilder::new()
        .with_url(&plan.url)
        .build_gtk(vbox)
        .map_err(std::io::Error::other)?;
    let mut held = Some((window, webview, children));
    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        if let Event::WindowEvent { event: WindowEvent::CloseRequested, .. } = event {
            held.take(); // drops the webview, then stops the daemon and dev server
            *flow = ControlFlow::Exit;
        }
    })
}

#[cfg(not(feature = "window"))]
fn open_window(plan: &Plan, children: Children) -> std::io::Result<()> {
    println!("{}", plan.url);
    eprintln!("built without the window feature: open the URL above in a browser; Ctrl-C stops");
    loop {
        std::thread::sleep(Duration::from_secs(3600));
        let _ = &children;
    }
}
