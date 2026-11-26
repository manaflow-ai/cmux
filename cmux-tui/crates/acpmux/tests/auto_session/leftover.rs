//! The changes a laptop kept aside when the Cloud took a chat, and the pane's Apply and Discard
//! of them (`_acpmux/auto_session/leftover`): Apply works in a folder with uncommitted work
//! and never touches the person's index, a conflict changes nothing, and two requests for one
//! chat take turns.

use std::io::Write as _;
use std::os::unix::ffi::OsStrExt as _;

use super::client::Client;
use super::*;

pub const LEFTOVER: &str = "_acpmux/auto_session/leftover";

/// `a.txt` as the chat's last copy has it.
const COPIED: &str = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
/// `a.txt` as the laptop left it after that copy: line 1 changed. This is what is kept aside.
const KEPT: &str = "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\n";

/// A chat the Auto machine took while this laptop was away with a change the Cloud's copy does
/// not have. The laptop is back and stands by, with that change kept aside. Answers the chat.
pub async fn taken_with_kept_changes(rig: &mut Rig) -> String {
    std::fs::write(rig.work.join("a.txt"), COPIED).unwrap();
    let setting = MachineSetting { team: TEAM.into(), machine: MACHINE.into() };
    rig.store.set_machine(&setting).await.unwrap();
    let id = rig.auto_chat().await;
    let (_ticks, pid) = rig.start_shell(&id).await;

    rig.cloud.set_offline(true);
    std::fs::write(rig.work.join("a.txt"), KEPT).unwrap();
    rig.cloud.advance(LEASE_MS + 1_000);
    rig.cloud.set_offline(false);
    rig.clock.advance(RENEW_MS);
    until("the laptop stands by with its changes kept", || {
        rig.record(&id).is_some_and(|record| !record.here && record.leftover.is_some())
    })
    .await;
    until("the tool's shell is gone", || !daemon_env::alive(pid)).await;
    assert_eq!(rig.row(&id)["leftover"]["files"], 1);
    id
}

fn action(id: &str, action: &str) -> Value {
    json!({"sessionId": id, "action": action})
}

fn a_txt(rig: &Rig) -> String {
    std::fs::read_to_string(rig.work.join("a.txt")).unwrap()
}

/// What the person has in the checkout: every file at its top, and the index, as bytes.
fn folder_state(work: &Path) -> (Vec<(String, Vec<u8>)>, Vec<u8>) {
    let mut files: Vec<(String, Vec<u8>)> = std::fs::read_dir(work)
        .unwrap()
        .map(|entry| entry.unwrap())
        .filter(|entry| entry.file_name() != ".git")
        .map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            (name, std::fs::read(entry.path()).unwrap())
        })
        .collect();
    files.sort();
    (files, std::fs::read(work.join(".git").join("index")).unwrap())
}

#[tokio::test]
async fn apply_takes_kept_changes_that_are_still_uncommitted_in_the_folder() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = taken_with_kept_changes(&mut rig).await;

    // Nothing moved the folder since the laptop lost the chat: the kept change is still its
    // uncommitted work, which is how the folder is from the wake until the chat comes home.
    let before = folder_state(&rig.work);
    let settled = rig.call(LEFTOVER, action(&id, "apply")).await;
    assert!(settled["autoSession"].get("leftover").is_none(), "{settled}");
    assert_eq!(a_txt(&rig), KEPT);
    assert_eq!(folder_state(&rig.work), before, "the change was there: nothing is written");
    let shown = rig.call(LEFTOVER, action(&id, "show")).await;
    assert_eq!(shown["files"], json!([]), "{shown}");
}

#[tokio::test]
async fn apply_merges_kept_changes_into_other_uncommitted_work_on_the_same_file() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = taken_with_kept_changes(&mut rig).await;

    // The folder as after the Cloud's copy came home: the kept change is gone from it and
    // the same file has other uncommitted work, on its last line.
    let a = rig.work.join("a.txt");
    std::fs::write(&a, COPIED.replace("seven", "SEVEN")).unwrap();
    let index = std::fs::read(rig.work.join(".git").join("index")).unwrap();

    let settled = rig.call(LEFTOVER, action(&id, "apply")).await;
    assert!(settled["autoSession"].get("leftover").is_none(), "{settled}");
    assert_eq!(a_txt(&rig), KEPT.replace("seven", "SEVEN"), "both changes are in the file");
    let after = std::fs::read(rig.work.join(".git").join("index")).unwrap();
    assert!(after == index, "the person's index is as it was");
}

#[tokio::test]
async fn apply_that_conflicts_changes_nothing_and_keeps_the_changes() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = taken_with_kept_changes(&mut rig).await;

    // The folder changed the same line another way, and the person staged that.
    let a = rig.work.join("a.txt");
    std::fs::write(&a, COPIED.replace("one", "uno")).unwrap();
    git(&rig.work, &["add", "a.txt"]);
    let before = folder_state(&rig.work);

    let refused = rig.reply(LEFTOVER, action(&id, "apply")).await.unwrap_err();
    assert_eq!(refused["data"]["reason"], "auto.leftover_conflict", "{refused}");
    assert!(
        folder_state(&rig.work) == before,
        "the folder and the index are byte for byte as before"
    );
    assert_eq!(rig.row(&id)["leftover"]["files"], 1, "the notice stays");
    let shown = rig.call(LEFTOVER, action(&id, "show")).await;
    assert!(shown["patch"].as_str().unwrap().contains("+ONE"), "the patch is kept: {shown}");

    // The person puts the line back: the same Apply goes through.
    std::fs::write(&a, COPIED).unwrap();
    let settled = rig.call(LEFTOVER, action(&id, "apply")).await;
    assert!(settled["autoSession"].get("leftover").is_none(), "{settled}");
    assert_eq!(a_txt(&rig), KEPT);
}

fn make_pipe(path: &Path) {
    let name = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: `name` is a NUL-terminated path that lives through the call.
    let made = unsafe { libc::mkfifo(name.as_ptr(), 0o600) };
    assert_eq!(made, 0, "mkfifo {}: {}", path.display(), std::io::Error::last_os_error());
}

#[tokio::test]
async fn two_requests_for_one_chats_kept_changes_take_turns() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = taken_with_kept_changes(&mut rig).await;
    // The folder is as the last copy had it, so the Apply has something to write.
    std::fs::write(rig.work.join("a.txt"), COPIED).unwrap();

    // The patch file becomes a pipe: the Apply that reads it waits there, mid-turn, until the
    // test writes the patch into it.
    let path = PathBuf::from(rig.record(&id).unwrap().leftover.unwrap().path);
    let patch = std::fs::read(&path).unwrap();
    std::fs::remove_file(&path).unwrap();
    make_pipe(&path);
    let (reading, apply_reads) = tokio::sync::oneshot::channel();
    let (go, may_write) = std::sync::mpsc::channel::<()>();
    let writer = std::thread::spawn(move || {
        // Opening a pipe to write returns once someone reads it: the Apply has the turn.
        let mut pipe = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        reading.send(()).unwrap();
        may_write.recv().unwrap();
        pipe.write_all(&patch).unwrap();
    });

    let mut first = Client::connect(&rig.hub, Origin::Local);
    let mut second = Client::connect(&rig.hub, Origin::Local);
    let applying = first.send(LEFTOVER, action(&id, "apply")).await;
    tokio::time::timeout(Duration::from_secs(60), apply_reads)
        .await
        .expect("the Apply reads the patch")
        .unwrap();
    let discarding = second.send(LEFTOVER, action(&id, "discard")).await;
    let early = second.answer(discarding, Duration::from_millis(500)).await;
    assert!(early.is_none(), "the Discard went ahead while the Apply ran: {early:?}");

    go.send(()).unwrap();
    writer.join().unwrap();
    let wait = Duration::from_secs(60);
    let applied = first.answer(applying, wait).await.expect("the Apply answers").expect("applied");
    assert!(applied["autoSession"].get("leftover").is_none(), "{applied}");
    // The Discard had its turn after the Apply: it found the changes settled.
    let after = second.answer(discarding, wait).await.expect("the Discard answers").expect("ok");
    assert!(after["autoSession"].get("leftover").is_none(), "{after}");
    assert_eq!(a_txt(&rig), KEPT, "the Apply wrote the kept change");
}
