//! Linux desktops: Xvfb + openbox + a browser, all in one cgroup v2 (a
//! systemd user scope with `Delegate=yes`, so no root). Suspend is
//! `cgroup.freeze` then `memory.reclaim` into zswap with
//! `memory.zswap.writeback=0` (pages stay compressed in RAM; on kernel 7.0 a
//! reclaim shrinks zswap to disk otherwise). Eviction turns writeback on and
//! reclaims again, so the pages go to the swap device. Input and screenshots
//! (xdotool, ImageMagick `import`) run outside the cgroup.
//!
//! Prior art: research/computer-use-density-2026-11-10.md (leo-workspace),
//! cmuxterm-hq#8741 (harness, numbers).

use crate::backend::{ActOutput, Action, Backend, Desktop, SlotSpec, SuspendReport};
use anyhow::{Context, Result, anyhow, bail};
use cmux_process::{Child, Command, Stdio};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MB: f64 = 1024.0 * 1024.0;
/// How long an input action lets the app repaint before its screenshot.
const INPUT_SETTLE: Duration = Duration::from_millis(300);

/// The display numbers this process holds, so two spawns never pick the same.
static DISPLAYS: Mutex<Option<HashSet<u32>>> = Mutex::new(None);

pub struct LinuxXvfb {
    /// Per-slot folders (browser profile, logs) live under it.
    pub state_dir: PathBuf,
    /// The browser binary (`google-chrome`, `chromium`).
    pub browser: String,
    /// The first display number tried.
    pub display_base: u32,
}

impl LinuxXvfb {
    pub fn new(state_dir: PathBuf) -> Self {
        let browser = std::env::var("DESKTOP_LEASE_BROWSER").unwrap_or_else(|_| {
            ["google-chrome", "chromium", "chromium-browser"]
                .into_iter()
                .find(|b| which(b).is_some())
                .unwrap_or("google-chrome")
                .to_owned()
        });
        LinuxXvfb { state_dir, browser, display_base: 300 }
    }

    fn take_display(&self) -> Result<u32> {
        let mut held = DISPLAYS.lock().map_err(|_| anyhow!("display lock poisoned"))?;
        let held = held.get_or_insert_with(HashSet::new);
        for n in self.display_base..self.display_base + 2000 {
            let free = !held.contains(&n)
                && !Path::new(&format!("/tmp/.X11-unix/X{n}")).exists()
                && !Path::new(&format!("/tmp/.X{n}-lock")).exists();
            if free {
                held.insert(n);
                return Ok(n);
            }
        }
        bail!("no free X display number")
    }
}

fn give_display(n: u32) {
    if let Ok(mut held) = DISPLAYS.lock()
        && let Some(held) = held.as_mut()
    {
        held.remove(&n);
    }
}

fn which(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")?
        .to_str()?
        .split(':')
        .map(|dir| Path::new(dir).join(name))
        .find(|p| p.is_file())
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

impl Backend for LinuxXvfb {
    fn kind(&self) -> &'static str {
        "linux-xvfb"
    }

    fn spawn(&self, id: &str, spec: &SlotSpec) -> Result<Box<dyn Desktop>> {
        let display = self.take_display()?;
        match spawn_desktop(self, id, spec, display) {
            Ok(d) => Ok(Box::new(d)),
            Err(e) => {
                give_display(display);
                Err(e)
            }
        }
    }
}

/// The slot's X authority file, inside its private state directory.
const XAUTHORITY: &str = "Xauthority";

/// Writes a fresh MIT-MAGIC-COOKIE-1 for `:display` into the slot's
/// `Xauthority` (mode 0600, in a 0700 directory) and returns its path.
/// Xvfb reads it through `-auth`; every client of the slot gets it as
/// `XAUTHORITY`.
fn write_xauthority(dir: &Path, display: u32) -> Result<PathBuf> {
    use std::io::{Read, Write};
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .with_context(|| format!("chmod 700 {}", dir.display()))?;
    let mut cookie = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut cookie))
        .context("read a cookie from /dev/urandom")?;
    let path = dir.join(XAUTHORITY);
    let _ = std::fs::remove_file(&path);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .with_context(|| format!("create {}", path.display()))?;
    file.write_all(&xauthority_entry(display, &cookie))
        .with_context(|| format!("write {}", path.display()))?;
    Ok(path)
}

/// One Xauthority record: family Wild (any address), the display number, the
/// MIT-MAGIC-COOKIE-1 name and the cookie, each length-prefixed (u16, big endian).
fn xauthority_entry(display: u32, cookie: &[u8; 16]) -> Vec<u8> {
    let mut out = Vec::with_capacity(64);
    out.extend_from_slice(&0xffff_u16.to_be_bytes());
    let display = display.to_string();
    for field in [&b""[..], display.as_bytes(), b"MIT-MAGIC-COOKIE-1", &cookie[..]] {
        let len = u16::try_from(field.len()).unwrap_or(u16::MAX);
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(field);
    }
    out
}

fn spawn_desktop(b: &LinuxXvfb, id: &str, spec: &SlotSpec, display: u32) -> Result<LinuxDesktop> {
    let dir = b.state_dir.join("slots").join(id);
    std::fs::create_dir_all(&dir).with_context(|| format!("mkdir {}", dir.display()))?;
    let unit = format!("desktop-lease-{}-{id}", std::process::id());
    let (w, h) = (spec.width, spec.height);
    let xauthority = write_xauthority(&dir, display)?;
    let d = shell_quote(&dir.to_string_lossy());
    let xa = shell_quote(&xauthority.to_string_lossy());
    // One shell holds the scope; every process of the desktop is its child,
    // so all of them are in the scope's cgroup. `-auth` turns on X access
    // control: only a client holding this slot's cookie may connect, so
    // another local user cannot read the screen or send input.
    let script = format!(
        "Xvfb :{display} -screen 0 {w}x{h}x24 -nolisten tcp -noreset -auth {xa} >{d}/xvfb.log 2>&1 &\n\
         i=0; while [ ! -S /tmp/.X11-unix/X{display} ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done\n\
         export DISPLAY=:{display}\n\
         export XAUTHORITY={xa}\n\
         openbox >{d}/openbox.log 2>&1 &\n\
         {browser} --user-data-dir={d}/profile --no-first-run --no-default-browser-check \
           --disable-gpu --password-store=basic --disable-background-networking \
           --disable-features=Translate,MediaRouter --window-position=0,0 --window-size={w},{h} \
           {url} >{d}/browser.log 2>&1 &\n\
         wait\n",
        browser = shell_quote(&b.browser),
        url = shell_quote(&spec.url),
    );
    let child = Command::new("systemd-run")
        .args(["--user", "--scope", "--quiet", "-p", "Delegate=yes", "--unit", &unit, "--"])
        .args(["/bin/sh", "-c", &script])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("systemd-run --user --scope")?;
    let mut desk = LinuxDesktop {
        id: id.to_owned(),
        unit: unit.clone(),
        display,
        cgroup: PathBuf::new(),
        child: Some(child),
        dir,
        destroyed: false,
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    // The scope's cgroup, as the user manager names it (no process scan).
    loop {
        let path = Command::new("systemctl")
            .args(["--user", "show", "-P", "ControlGroup", &format!("{unit}.scope")])
            .stdin(Stdio::null())
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
            .unwrap_or_default();
        if path.ends_with(&format!("{unit}.scope")) {
            desk.cgroup = PathBuf::from("/sys/fs/cgroup").join(path.trim_start_matches('/'));
            break;
        }
        if Instant::now() > deadline {
            desk.destroy();
            bail!("slot {id}: the scope {unit} never appeared");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    // Suspended pages stay compressed in RAM until `evict`.
    desk.write("memory.zswap.writeback", "0")?;
    // Ready when the browser has a visible window.
    let deadline = Instant::now() + Duration::from_secs(45);
    while desk.xdotool(&["search", "--onlyvisible", "--class", "chrom"]).is_err() {
        if Instant::now() > deadline {
            desk.destroy();
            bail!("slot {id}: no browser window on :{display} after 45 s");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    // A first page paint before the pool suspends it.
    std::thread::sleep(Duration::from_millis(500));
    Ok(desk)
}

pub struct LinuxDesktop {
    id: String,
    unit: String,
    display: u32,
    cgroup: PathBuf,
    child: Option<Child>,
    dir: PathBuf,
    destroyed: bool,
}

impl LinuxDesktop {
    fn write(&self, file: &str, value: &str) -> Result<()> {
        std::fs::write(self.cgroup.join(file), value)
            .with_context(|| format!("write {value} to {}/{file}", self.cgroup.display()))
    }

    fn read(&self, file: &str) -> String {
        std::fs::read_to_string(self.cgroup.join(file)).unwrap_or_default()
    }

    fn read_u64(&self, file: &str) -> u64 {
        self.read(file).trim().parse().unwrap_or(0)
    }

    fn stat(&self, key: &str) -> u64 {
        self.read("memory.stat")
            .lines()
            .find_map(|l| l.strip_prefix(key)?.strip_prefix(' ')?.trim().parse().ok())
            .unwrap_or(0)
    }

    fn wait_frozen(&self, want: bool) -> Result<()> {
        let want = if want { "frozen 1" } else { "frozen 0" };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.read("cgroup.events").lines().any(|l| l == want) {
            if Instant::now() > deadline {
                bail!("slot {}: cgroup never reached '{want}'", self.id);
            }
            std::thread::sleep(Duration::from_micros(500));
        }
        Ok(())
    }

    fn reclaim(&self) {
        // Ask for everything; the kernel answers EAGAIN when it got less, which is fine.
        let want = self.read_u64("memory.current");
        let _ = self.write("memory.reclaim", &want.to_string());
    }

    fn report(&self, before: u64, freeze_ms: f64, reclaim_ms: f64) -> SuspendReport {
        let swap = self.read_u64("memory.swap.current");
        let zswapped = self.stat("zswapped");
        SuspendReport {
            freeze_ms,
            reclaim_ms,
            resident_before_mb: before as f64 / MB,
            resident_after_mb: self.read_u64("memory.current") as f64 / MB,
            zswap_mb: self.stat("zswap") as f64 / MB,
            swap_mb: swap.saturating_sub(zswapped) as f64 / MB,
        }
    }

    fn xdotool(&self, args: &[&str]) -> Result<String> {
        let out = Command::new("xdotool")
            .args(args)
            .env("DISPLAY", format!(":{}", self.display))
            .env("XAUTHORITY", self.dir.join(XAUTHORITY))
            .stdin(Stdio::null())
            .output()
            .context("xdotool")?;
        if !out.status.success() {
            bail!("xdotool {args:?}: {}", String::from_utf8_lossy(&out.stderr).trim());
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    fn screenshot(&self) -> Result<Vec<u8>> {
        let out = Command::new("import")
            .env("XAUTHORITY", self.dir.join(XAUTHORITY))
            .args([
                "-silent",
                "-window",
                "root",
                "-display",
                &format!(":{}", self.display),
                "png:-",
            ])
            .stdin(Stdio::null())
            .output()
            .context("import (ImageMagick)")?;
        if !out.status.success() || out.stdout.is_empty() {
            bail!("screenshot :{}: {}", self.display, String::from_utf8_lossy(&out.stderr).trim());
        }
        Ok(out.stdout)
    }
}

impl Desktop for LinuxDesktop {
    fn suspend(&mut self) -> Result<SuspendReport> {
        let before = self.read_u64("memory.current");
        let t = Instant::now();
        self.write("memory.zswap.writeback", "0")?;
        self.write("memory.zswap.max", "max")?;
        self.write("cgroup.freeze", "1")?;
        self.wait_frozen(true)?;
        let freeze_ms = ms(t);
        let t = Instant::now();
        self.reclaim();
        Ok(self.report(before, freeze_ms, ms(t)))
    }

    fn resume(&mut self) -> Result<f64> {
        let t = Instant::now();
        self.write("cgroup.freeze", "0")?;
        self.wait_frozen(false)?;
        Ok(ms(t))
    }

    fn act(&mut self, action: &Action) -> Result<ActOutput> {
        let t = Instant::now();
        match action {
            Action::Screenshot => {}
            Action::Click { x, y, button, count } => {
                let (x, y, b, c) =
                    (x.to_string(), y.to_string(), button.to_string(), count.to_string());
                self.xdotool(&["mousemove", "--sync", &x, &y, "click", "--repeat", &c, &b])?;
            }
            Action::TypeText { text } => {
                self.xdotool(&["type", "--delay", "6", "--", text])?;
            }
            Action::PressKey { key } => {
                self.xdotool(&["key", "--", key])?;
            }
            Action::Scroll { x, y, direction, amount } => {
                let button = match direction.as_str() {
                    "up" => "4",
                    "down" => "5",
                    "left" => "6",
                    "right" => "7",
                    other => bail!("scroll direction '{other}' (up, down, left, right)"),
                };
                let (x, y, n) = (x.to_string(), y.to_string(), amount.to_string());
                self.xdotool(&["mousemove", "--sync", &x, &y, "click", "--repeat", &n, button])?;
            }
            Action::OpenUrl { url, wait_ms } => {
                self.xdotool(&["key", "ctrl+l"])?;
                // The omnibox takes focus a moment after ctrl+l; keys typed before it are lost
                // (a run typed "7.0.0.1" for "127.0.0.1").
                std::thread::sleep(Duration::from_millis(150));
                self.xdotool(&["key", "ctrl+a"])?;
                self.xdotool(&["type", "--delay", "4", "--", url])?;
                self.xdotool(&["key", "Return"])?;
                std::thread::sleep(Duration::from_millis((*wait_ms).min(30_000)));
            }
            Action::Wait { ms } => std::thread::sleep(Duration::from_millis((*ms).min(30_000))),
        }
        if matches!(
            action,
            Action::Click { .. }
                | Action::TypeText { .. }
                | Action::PressKey { .. }
                | Action::Scroll { .. }
        ) {
            // The app's repaint after the input, before the screenshot.
            std::thread::sleep(INPUT_SETTLE);
        }
        let act_ms = ms(t);
        let t = Instant::now();
        let png = self.screenshot()?;
        let screenshot_ms = ms(t);
        let title =
            self.xdotool(&["getactivewindow", "getwindowname"]).ok().map(|s| s.trim().to_owned());
        Ok(ActOutput { png, title, act_ms, screenshot_ms })
    }

    fn resident_bytes(&self) -> u64 {
        self.read_u64("memory.current")
    }

    fn evict(&mut self) -> Result<SuspendReport> {
        let before = self.read_u64("memory.current");
        let t = Instant::now();
        // Writeback alone moves little on kernel 7.0; a zero zswap limit makes the reclaim
        // write every compressed page out (measured: 56 -> 21 MB resident, zswap 30 -> 0 MB).
        self.write("memory.zswap.writeback", "1")?;
        self.write("memory.zswap.max", "0")?;
        // Writing a compressed page out first decompresses it into the swap cache, so one pass
        // grows the cgroup (measured 55 -> 83 MB); the next frees the now-clean cache (-> 35 MB).
        let mut last = u64::MAX;
        for _ in 0..4 {
            self.reclaim();
            let now = self.read_u64("memory.current");
            if now >= last {
                break;
            }
            last = now;
        }
        Ok(self.report(before, 0.0, ms(t)))
    }

    fn destroy(&mut self) {
        if self.destroyed {
            return;
        }
        self.destroyed = true;
        if !self.cgroup.as_os_str().is_empty() {
            // Only this slot's own cgroup: everything the desktop started, nothing else.
            let _ = self.write("cgroup.kill", "1");
            let _ = self.write("cgroup.freeze", "0");
        }
        if let Some(mut child) = self.child.take() {
            let _ = child.wait();
        }
        // cgroup.kill is asynchronous: the browser may still write its profile for a moment.
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.read("cgroup.events").lines().any(|l| l == "populated 1")
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = std::fs::remove_dir_all(&self.dir);
        // A killed Xvfb leaves its lock and socket behind; they are this slot's own.
        let _ = std::fs::remove_file(format!("/tmp/.X{}-lock", self.display));
        let _ = std::fs::remove_file(format!("/tmp/.X11-unix/X{}", self.display));
        give_display(self.display);
    }

    fn owner_record(&self) -> serde_json::Value {
        serde_json::json!({
            "slot": self.id,
            "unit": format!("{}.scope", self.unit),
            "cgroup": self.cgroup,
            "display": format!(":{}", self.display),
            "launcher_pid": self.child.as_ref().map(Child::id),
        })
    }
}

impl Drop for LinuxDesktop {
    fn drop(&mut self) {
        self.destroy();
    }
}

#[cfg(test)]
mod xauthority_tests {
    use super::xauthority_entry;

    #[test]
    fn the_entry_is_one_wild_mit_magic_cookie_record_for_the_display() {
        let cookie = [7u8; 16];
        let entry = xauthority_entry(301, &cookie);
        let mut want = vec![0xff, 0xff, 0, 0, 0, 3];
        want.extend_from_slice(b"301");
        want.extend_from_slice(&[0, 18]);
        want.extend_from_slice(b"MIT-MAGIC-COOKIE-1");
        want.extend_from_slice(&[0, 16]);
        want.extend_from_slice(&cookie);
        assert_eq!(entry, want);
    }
}
