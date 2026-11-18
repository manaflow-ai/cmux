//! `project-serve`: each rule of the trust boundary, then the whole path without FUSE: the
//! machine's read path (`cmux_projfs::Core`) asking through the real rendezvous, and this serve
//! loop answering over a socket.

use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_projfs::{ChunkCache, Config, Core, Got, ReadError, Source, Want};
use cmux_tui_core::projfs_rendezvous::{Caller, Rendezvous, answer_line};
use serde_json::{Value, json};

use super::super::projected::{Record, build, stage};
use super::*;

const MOUNT: &str = "p-test";

fn write(top: &Path, relative: &str, bytes: &[u8]) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

/// A Mac folder, its projection kept as `start-chat project` keeps it, and the place outside.
struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    kept: PathBuf,
    outside: PathBuf,
}

impl Fixture {
    fn new(files: &[(&str, &[u8])]) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(dir.path()).unwrap();
        let (root, kept, outside) = (base.join("mac"), base.join("kept"), base.join("outside"));
        for (path, bytes) in files {
            write(&root, path, bytes);
        }
        write(&outside, "secret.txt", b"outside the folder");
        write(&outside, "f.txt", b"outside the folder");
        let listing = sync_cli::stat_listing(&root).unwrap();
        let (manifest, rewritten) = build(&root, &listing, 1).unwrap();
        stage(&kept, &manifest.encode().unwrap(), &rewritten).unwrap();
        let record = Record {
            mount: MOUNT.into(),
            account: "u1".into(),
            machine: "m1".into(),
            local_root: root.display().to_string(),
            machine_path: "/home/cmux/w".into(),
            folder: "/home/cmux/w".into(),
            state_dir: "/home/cmux/.projfs".into(),
            socket: "/nowhere.sock".into(),
            made_at: 1,
        };
        std::fs::write(kept.join(RECORD), serde_json::to_vec(&record).unwrap()).unwrap();
        Self { _dir: dir, root, kept, outside }
    }

    fn served(&self) -> Served {
        Served::load(&self.kept).unwrap().1
    }
}

/// A want for `path` at the version `served`'s manifest lists.
fn want(served: &Served, path: &str, offset: u64, len: u64) -> Value {
    let manifest = served.manifest();
    let stat = manifest.resolve(path).and_then(|i| manifest.entry(i)).map(|e| e.stat.clone());
    let stat = stat.unwrap_or_else(|| Stat::file(0o644, 1, 0, 0));
    json!({ "path": path, "size": stat.size, "mtime_ns": stat.mtime_ns, "ctime_ns": stat.ctime_ns,
            "offset": offset, "len": len })
}

fn bytes_of(result: &Value) -> Vec<u8> {
    assert_eq!(result["status"], "bytes", "{result}");
    base64::engine::general_purpose::STANDARD.decode(result["data_b64"].as_str().unwrap()).unwrap()
}

#[test]
fn an_unlisted_path_is_gone_and_a_withheld_one_withheld() {
    let fixture = Fixture::new(&[("a.txt", b"a"), (".env", b"KEY=1")]);
    let mut served = fixture.served();
    write(&fixture.root, "new.txt", b"made after the manifest");
    assert_eq!(served.answer(&want(&served, "new.txt", 0, 4))["status"], "gone");
    assert_eq!(served.answer(&want(&served, ".env", 0, 4))["status"], "withheld");
    assert_eq!(bytes_of(&served.answer(&want(&served, "a.txt", 0, 4))), b"a");
}

#[test]
fn absolute_climbing_empty_and_nul_paths_fail_without_touching_the_disk() {
    let fixture = Fixture::new(&[("a.txt", b"a"), ("d/b.txt", b"b")]);
    let mut served = fixture.served();
    let base = want(&served, "a.txt", 0, 4);
    for path in ["/etc/passwd", "../outside/secret.txt", "d/../a.txt", "d//b.txt", "./a.txt", "a\0"]
    {
        let mut asked = base.clone();
        asked["path"] = json!(path);
        assert_eq!(served.answer(&asked)["status"], "failed", "{path:?}");
    }
    for len in [0, cmux_projfs::CHUNK + 1] {
        assert_eq!(served.answer(&want(&served, "a.txt", 0, len))["status"], "failed", "{len}");
    }
    assert_eq!(served.answer(&want(&served, "d", 0, 4))["status"], "failed", "a folder");
}

#[test]
fn a_symlinked_folder_on_the_way_is_never_crossed() {
    let fixture = Fixture::new(&[("d/f.txt", b"inside")]);
    let mut served = fixture.served();
    let asked = want(&served, "d/f.txt", 0, 64);
    std::fs::rename(fixture.root.join("d"), fixture.root.join("d-old")).unwrap();
    std::os::unix::fs::symlink(&fixture.outside, fixture.root.join("d")).unwrap();
    assert_eq!(served.answer(&asked)["status"], "gone");
    assert!(served.manifest().resolve("d/f.txt").is_none(), "the manifest copy took it");
}

#[test]
fn a_file_replaced_by_a_symlink_is_gone_and_never_read_through() {
    let fixture = Fixture::new(&[("a.txt", b"inside")]);
    let mut served = fixture.served();
    let asked = want(&served, "a.txt", 0, 64);
    std::fs::remove_file(fixture.root.join("a.txt")).unwrap();
    std::os::unix::fs::symlink(fixture.outside.join("secret.txt"), fixture.root.join("a.txt"))
        .unwrap();
    assert_eq!(served.answer(&asked)["status"], "gone");
}

#[test]
fn a_changed_file_answers_its_new_stat_then_serves_the_new_version() {
    let fixture = Fixture::new(&[("c.txt", b"old")]);
    let mut served = fixture.served();
    let old = want(&served, "c.txt", 0, 64);
    write(&fixture.root, "c.txt", b"new and longer");
    let result = served.answer(&old);
    assert_eq!(result["status"], "changed", "{result}");
    assert_eq!(result["size"], 14);
    let new = want(&served, "c.txt", 0, 64);
    assert_eq!(new["size"], 14, "the manifest copy took the new version");
    assert_eq!(bytes_of(&served.answer(&new)), b"new and longer");
    let reloaded = fixture.served();
    assert_eq!(want(&reloaded, "c.txt", 0, 64), new, "and kept it on disk");
}

#[test]
fn a_deleted_file_is_gone_and_stays_gone() {
    let fixture = Fixture::new(&[("d.txt", b"gone soon")]);
    let mut served = fixture.served();
    let asked = want(&served, "d.txt", 0, 64);
    std::fs::remove_file(fixture.root.join("d.txt")).unwrap();
    assert_eq!(served.answer(&asked)["status"], "gone");
    write(&fixture.root, "d.txt", b"back");
    assert_eq!(served.answer(&asked)["status"], "gone", "only a new manifest lists it again");
}

#[test]
fn ranges_are_cut_at_the_end_and_empty_past_it() {
    let fixture = Fixture::new(&[("r.txt", b"0123456789")]);
    let mut served = fixture.served();
    assert_eq!(bytes_of(&served.answer(&want(&served, "r.txt", 2, 3))), b"234");
    assert_eq!(bytes_of(&served.answer(&want(&served, "r.txt", 6, 10))), b"6789");
    assert_eq!(bytes_of(&served.answer(&want(&served, "r.txt", 10, 4))), b"");
    assert_eq!(bytes_of(&served.answer(&want(&served, "r.txt", 99, 4))), b"");
    let batch = [want(&served, "r.txt", 0, 4 << 20), want(&served, "r.txt", 0, 4 << 20)];
    let third = want(&served, "r.txt", 0, 1);
    let results = served.answer_batch(&[batch[0].clone(), batch[1].clone(), third]);
    assert_eq!(results.iter().filter(|r| r["status"] == "bytes").count(), 2);
    assert_eq!(results[2]["status"], "failed", "past the answer's bound");
}

/// The machine's side: `projfs.fetch` on the rendezvous, as the helper sends it.
struct Machine {
    rendezvous: Arc<Rendezvous>,
}

impl Source for Machine {
    fn fetch(&self, wants: &[Want]) -> Vec<Got> {
        wants.iter().map(|w| self.one(w)).collect()
    }
}

impl Machine {
    fn one(&self, w: &Want) -> Got {
        let line = json!({ "id": 1, "cmd": "projfs.fetch", "mount": MOUNT, "wait_ms": 300,
            "wants": [{ "path": w.path, "size": w.version.size, "mtime_ns": w.version.mtime_ns,
                        "ctime_ns": w.version.ctime_ns, "offset": w.offset, "len": w.len }] });
        let answer = answer_line(Some(&self.rendezvous), Caller::Local, &line.to_string());
        let result = &answer["data"]["results"][0];
        let int = |k: &str| result[k].as_i64().unwrap_or_default();
        match result["status"].as_str() {
            Some("bytes") => Got::Bytes(bytes_of(result)),
            Some("changed") => Got::Changed(Stat::file(
                u32::try_from(int("mode")).unwrap(),
                u64::try_from(int("size")).unwrap(),
                int("mtime_ns"),
                int("ctime_ns"),
            )),
            Some("gone") => Got::Gone,
            Some("withheld") => Got::Withheld,
            Some("away") => Got::Away,
            _ => Got::Failed(answer.to_string()),
        }
    }
}

/// The machine's daemon as the Mac's link reaches it: every connection a remote client.
fn daemon(rendezvous: Arc<Rendezvous>, socket: &Path) {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let rendezvous = rendezvous.clone();
            std::thread::spawn(move || {
                use std::io::{BufRead as _, Write as _};
                let mut out = stream.try_clone().unwrap();
                for line in BufReader::new(stream).lines().map_while(Result::ok) {
                    let mac = Caller::Remote("remote_mac".into());
                    let answer = answer_line(Some(&rendezvous), mac, &line);
                    if out.write_all(format!("{answer}\n").as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
}

fn start_serving(kept: &Path, socket: &Path) -> (mpsc::Sender<()>, std::thread::JoinHandle<Value>) {
    let (stop, stopped) = mpsc::channel();
    let (kept, socket) = (kept.to_path_buf(), socket.to_path_buf());
    let handle = std::thread::spawn(move || {
        let mut served = Served::load(&kept).unwrap().1;
        let options = Options { wait_ms: 200, once: false, max_pause: Duration::from_millis(200) };
        serve(&mut served, &socket, &options, &stopped)
    });
    (stop, handle)
}

fn read_all(core: &Arc<Core>, path: &str) -> Result<Vec<u8>, ReadError> {
    let idx = core.manifest().resolve(path).unwrap();
    let mut out = Vec::new();
    loop {
        let offset = u64::try_from(out.len()).unwrap();
        let part = core.read(idx, offset, u32::try_from(cmux_projfs::CHUNK).unwrap())?;
        if part.is_empty() {
            return Ok(out);
        }
        out.extend(part);
    }
}

#[test]
fn the_machine_reads_through_the_rendezvous_from_the_serve_loop() {
    let big: Vec<u8> = (0..9u32 << 20).map(|i| u8::try_from(i % 251).unwrap()).collect();
    // Each file a folder of its own: a fault batches its folder's other small files, which
    // would cache `b.txt` and `c.txt` before the steps below ask for them.
    let fixture = Fixture::new(&[
        ("small.txt", b"small"),
        ("big.bin", &big),
        ("changed/b.txt", b"before"),
        ("restart/c.txt", b"read after a restart"),
    ]);
    let rendezvous = Arc::new(Rendezvous::new());
    let socket = fixture.kept.parent().unwrap().join("d.sock");
    daemon(rendezvous.clone(), &socket);
    let manifest = Manifest::decode(&std::fs::read(fixture.kept.join(MANIFEST)).unwrap()).unwrap();
    let cache_dir = fixture.kept.parent().unwrap().join("cache");
    let cache = ChunkCache::open(&cache_dir, 1 << 30).unwrap();
    let config = Config { away_wait: Duration::from_secs(1), ..Config::default() };
    let core = Core::new(manifest, cache, Arc::new(Machine { rendezvous }), config);
    let (stop, serving) = start_serving(&fixture.kept, &socket);
    assert_eq!(read_all(&core, "small.txt").unwrap(), b"small");
    assert!(read_all(&core, "big.bin").unwrap() == big, "the 9 MiB file arrived intact");
    write(&fixture.root, "changed/b.txt", b"after, and longer");
    assert_eq!(read_all(&core, "changed/b.txt").unwrap(), b"after, and longer");
    stop.send(()).unwrap();
    assert_eq!(serving.join().unwrap()["ok"], true);
    let asked = Instant::now();
    assert_eq!(read_all(&core, "restart/c.txt"), Err(ReadError::HostDown));
    assert!(asked.elapsed() < Duration::from_secs(5), "away within its bound");
    let (stop, serving) = start_serving(&fixture.kept, &socket);
    assert_eq!(read_all(&core, "restart/c.txt").unwrap(), b"read after a restart");
    stop.send(()).unwrap();
    assert!(serving.join().unwrap()["batches"].as_u64().unwrap() >= 1);
}
