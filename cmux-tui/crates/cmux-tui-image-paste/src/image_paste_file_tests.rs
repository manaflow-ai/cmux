use super::*;

#[test]
fn cloud_image_paste_crash_receipt_recovers_exact_owned_bytes() {
    let mut file = ImagePasteFile::create("png").unwrap();
    file.append(b"private image bytes").unwrap();
    let path = file.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    // Model process death: descriptors close, but Drop cannot unlink anything.
    file.cleanup = false;
    drop(file);
    let (deadline, recovered) =
        ImagePasteFile::recover_one(directory.clone(), WallClock::default().now()).unwrap();
    assert!(deadline <= Instant::now() + Duration::from_secs(720));
    assert_eq!(fs::read(&path).unwrap(), b"private image bytes");
    assert!(recovered.remove_owned());
    drop(recovered);
    assert!(!path.exists());
    assert!(!directory.exists());
}

#[test]
fn cloud_image_paste_recovery_rejects_replaced_files() {
    let mut file = ImagePasteFile::create("png").unwrap();
    let path = file.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    let original = directory.join("moved.png");
    fs::rename(&path, &original).unwrap();
    fs::write(&path, "user replacement").unwrap();
    file.cleanup = false;
    drop(file);
    assert!(ImagePasteFile::recover_one(directory.clone(), WallClock::default().now()).is_none());
    assert_eq!(fs::read_to_string(&path).unwrap(), "user replacement");
    for name in ["clipboard.png", ".receipt", "moved.png"] {
        fs::remove_file(directory.join(name)).unwrap();
    }
    fs::remove_dir(directory).unwrap();
}

#[test]
fn cloud_image_paste_recovery_does_not_own_an_active_daemons_file_before_expiry() {
    let file = ImagePasteFile::create("png").unwrap();
    let path = file.path().unwrap();
    let (_, recovered) =
        ImagePasteFile::recover_one(path.parent().unwrap().to_owned(), WallClock::default().now())
            .unwrap();
    drop(recovered);
    assert!(path.exists());
    drop(file);
    assert!(!path.exists());
}

#[test]
fn cloud_image_paste_recovery_requires_a_marker_even_when_inode_metadata_matches() {
    let mut original = ImagePasteFile::create("png").unwrap();
    let path = original.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    original.cleanup = false;
    drop(original);
    fs::remove_file(&path).unwrap();
    fs::write(&path, "replacement user file").unwrap();
    let receipt_path = directory.join(".receipt");
    let mut receipt: Receipt = serde_json::from_reader(File::open(&receipt_path).unwrap()).unwrap();
    let replacement = fs::metadata(&path).unwrap();
    // Model an allocator reusing the recorded inode without depending on a
    // particular filesystem's inode allocator. Keep the original ownership token.
    receipt.file_device = replacement.dev();
    receipt.file_inode = replacement.ino();
    serde_json::to_writer(File::create(&receipt_path).unwrap(), &receipt).unwrap();
    assert!(ImagePasteFile::recover_one(directory.clone(), WallClock::default().now()).is_none());
    assert_eq!(fs::read_to_string(&path).unwrap(), "replacement user file");
    fs::remove_file(path).unwrap();
    fs::remove_file(receipt_path).unwrap();
    fs::remove_dir(directory).unwrap();
}

#[test]
fn cloud_image_paste_recovery_retries_an_interrupted_quarantine() {
    let mut file = ImagePasteFile::create("png").unwrap();
    file.append(b"private image").unwrap();
    let path = file.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    let quarantine = directory.join(".cleanup-image");
    fs::rename(&path, &quarantine).unwrap();
    file.cleanup = false;
    drop(file);
    let (_, recovered) =
        ImagePasteFile::recover_one(directory.clone(), WallClock::default().now()).unwrap();
    assert!(recovered.remove_owned());
    drop(recovered);
    assert!(!quarantine.exists());
    assert!(!directory.exists());
}

#[test]
fn cloud_image_paste_receipt_rewrite_removes_only_an_owned_leftover() {
    let mut file = ImagePasteFile::create("png").unwrap();
    let directory = file.directory().to_owned();
    let receipt = || -> Receipt {
        serde_json::from_reader(File::open(directory.join(".receipt")).unwrap()).unwrap()
    };
    // A crash between writing the next receipt and renaming it leaves an
    // owned copy at the private write name; the next rewrite replaces it.
    fs::copy(directory.join(".receipt"), directory.join(".receipt-next")).unwrap();
    file.set_expiry(42).unwrap();
    assert_eq!(receipt().expires, 42);
    assert!(!directory.join(".receipt-next").exists());
    // A file at that name without this upload's token is never removed.
    fs::write(directory.join(".receipt-next"), "user file").unwrap();
    assert!(file.set_expiry(43).is_err());
    assert_eq!(receipt().expires, 42);
    assert!(file.remove_owned());
    assert_eq!(fs::read_to_string(directory.join(".receipt-next")).unwrap(), "user file");
    fs::remove_file(directory.join(".receipt-next")).unwrap();
    fs::remove_dir(&directory).unwrap();
    file.cleanup = false;
}

/// A child forked from this test process that keeps a copy of every descriptor this process has
/// at the fork, as a child another daemon thread forks keeps them until it execs. Dropping this
/// kills and reaps the child.
///
/// Fork safety: a test binary runs many threads, so the child of `fork` may make only
/// async-signal-safe calls. It calls `pause` in a loop and nothing else: it never returns from
/// [`Keeper::fork`], allocates, takes a lock, unwinds or calls `_exit` or `exit` itself. The
/// parent's drop ends it with SIGKILL (from outside the child) and reaps it with `waitpid`.
struct Keeper(libc::pid_t);

impl Keeper {
    fn fork() -> Keeper {
        // SAFETY: the child runs only async-signal-safe `pause` until SIGKILL ends it.
        let child = unsafe { libc::fork() };
        assert!(child >= 0, "fork failed");
        if child == 0 {
            loop {
                // SAFETY: as above.
                unsafe { libc::pause() };
            }
        }
        Keeper(child)
    }
}

impl Drop for Keeper {
    fn drop(&mut self) {
        let mut status = 0;
        // SAFETY: `self.0` is this test's own child and `status` outlives the call.
        unsafe {
            libc::kill(self.0, libc::SIGKILL);
            libc::waitpid(self.0, &mut status, 0);
        }
    }
}

/// An upload that its daemon drops without removing it lets go of its lease, also while a child
/// the daemon forked meanwhile has the descriptor: else the recovery sweep cannot claim the
/// expired file and keeps it for another round.
#[test]
fn a_dropped_upload_frees_its_lease_while_a_forked_child_keeps_its_descriptor() {
    let mut file = ImagePasteFile::create("png").unwrap();
    file.append(b"private image bytes").unwrap();
    let path = file.path().unwrap();
    let directory = path.parent().unwrap().to_owned();
    // Kept on disk (as when its removal failed), so the sweep finds it.
    file.cleanup = false;
    let keeper = Keeper::fork();
    drop(file);
    let (_, recovered) =
        ImagePasteFile::recover_one(directory.clone(), WallClock::default().now()).unwrap();
    let claimed = recovered.claim_for_removal();
    drop(keeper);
    assert!(claimed, "a dropped upload left its lease held");
    assert!(recovered.remove_owned());
    drop(recovered);
    assert!(!directory.exists());
}

/// A sweep that claimed a file and could not remove it lets go of its claim, also while a child
/// the daemon forked meanwhile has the descriptor: else the next sweep cannot claim it.
#[test]
fn a_dropped_claim_is_free_while_a_forked_child_keeps_its_descriptor() {
    let mut file = ImagePasteFile::create("png").unwrap();
    file.append(b"private image bytes").unwrap();
    let directory = file.path().unwrap().parent().unwrap().to_owned();
    file.cleanup = false;
    drop(file);
    let (_, first) =
        ImagePasteFile::recover_one(directory.clone(), WallClock::default().now()).unwrap();
    assert!(first.claim_for_removal(), "the first sweep claims the file");
    let keeper = Keeper::fork();
    drop(first);
    let (_, next) =
        ImagePasteFile::recover_one(directory.clone(), WallClock::default().now()).unwrap();
    let claimed = next.claim_for_removal();
    drop(keeper);
    assert!(claimed, "a dropped claim left the file locked");
    assert!(next.remove_owned());
    drop(next);
    assert!(!directory.exists());
}
