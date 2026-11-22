use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, Sender};

struct Hold {
    folder: PathBuf,
    reached: Sender<()>,
    release: Receiver<()>,
}

static HOLDS: Mutex<Vec<Hold>> = Mutex::new(Vec::new());

/// The seed of `folder` stops at its head until `release` sends or drops; `reached`
/// hears when it gets there.
pub(in super::super) fn at(folder: &Path, reached: Sender<()>, release: Receiver<()>) {
    let hold = Hold { folder: folder.to_path_buf(), reached, release };
    HOLDS.lock().unwrap().push(hold);
}

pub(super) fn at_head(folder: &Path) {
    let hold = {
        let mut holds = HOLDS.lock().unwrap();
        let at = holds.iter().position(|hold| hold.folder == folder);
        at.map(|at| holds.remove(at))
    };
    if let Some(hold) = hold {
        let _ = hold.reached.send(());
        let _ = hold.release.recv();
    }
}
