//! The root's identity files (`machine-id`, `resource-effect-pepper`) are
//! written once, on the first open of a state root. A first open that dies
//! or hits a full disk part way through that write must not leave a torn
//! file: every later open reads it as corrupt and refuses the root, so no
//! session on the Mac starts until the person deletes the file by hand.
//!
//! The child test below opens a root with `RLIMIT_FSIZE` set (writes past
//! the limit fail with `EFBIG`, as on a full disk); the parent then opens
//! the same root without a limit.

use super::*;

const CHILD_ROOT_ENV: &str = "CMUX_TEST_IDENTITY_TORN_ROOT";
const CHILD_LIMIT_ENV: &str = "CMUX_TEST_IDENTITY_TORN_FSIZE";

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-registry-{label}-{}", new_uuid_v4()))
}

/// Run in a child process by [`open_in_child_with_file_size_limit`]: opens
/// the root under a file-size limit. Does nothing in an ordinary test run.
#[test]
fn identity_file_torn_write_child() {
    let (Ok(root), Ok(limit)) = (std::env::var(CHILD_ROOT_ENV), std::env::var(CHILD_LIMIT_ENV))
    else {
        return;
    };
    let limit: libc::rlim_t = limit.parse().expect("a byte limit");
    // SAFETY: plain libc calls on this single-threaded child before any
    // file is written; SIGXFSZ ignored makes an over-limit write fail
    // with EFBIG instead of ending the process.
    unsafe {
        libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
        let rlimit = libc::rlimit { rlim_cur: limit, rlim_max: limit };
        assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &rlimit), 0);
    }
    let opened = WorkspaceRegistry::open(Path::new(&root), "alpha");
    println!("identity_file_torn_write_child opened={}", opened.is_ok());
}

fn open_in_child_with_file_size_limit(root: &Path, limit: u64) {
    let module = module_path!().split_once("::").map_or(module_path!(), |(_, path)| path);
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([&format!("{module}::identity_file_torn_write_child"), "--exact", "--test-threads=1"])
        .args(["--nocapture"])
        .env(CHILD_ROOT_ENV, root)
        .env(CHILD_LIMIT_ENV, limit.to_string())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("identity_file_torn_write_child opened="),
        "the child ran no test: {stdout}"
    );
    assert!(
        stdout.contains("opened=false"),
        "the limit must make the child's first open fail: {stdout}"
    );
}

#[test]
fn a_failed_first_machine_id_write_leaves_no_torn_file() {
    for limit in [0, 16] {
        let root = temp_root("machine-id-torn");
        open_in_child_with_file_size_limit(&root, limit);
        let registry = WorkspaceRegistry::open(&root, "alpha");
        assert!(
            registry.is_ok(),
            "an open after a failed first write (limit {limit} bytes) must succeed: {:?}",
            registry.err()
        );
        let written = fs::read(root.join(MACHINE_ID_FILE)).unwrap();
        assert!(parse_machine_id_file(&root.join(MACHINE_ID_FILE), &written).is_ok());
        drop(registry);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn a_failed_first_pepper_write_leaves_no_torn_file() {
    let root = temp_root("pepper-torn");
    fs::create_dir_all(&root).unwrap();
    // A whole machine id already there, so the child's limit tears only the pepper.
    let machine_id = MachinePublicId::random().unwrap();
    fs::write(root.join(MACHINE_ID_FILE), format!("{}\n", machine_id.as_str())).unwrap();
    open_in_child_with_file_size_limit(&root, (RESOURCE_EFFECT_PEPPER_BYTES / 2) as u64);
    let registry = WorkspaceRegistry::open(&root, "alpha");
    assert!(
        registry.is_ok(),
        "an open after a failed first pepper write must succeed: {:?}",
        registry.err()
    );
    assert_eq!(
        fs::read(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap().len(),
        RESOURCE_EFFECT_PEPPER_BYTES
    );
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
