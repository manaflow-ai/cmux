//! One controller at a time: when several viewers watch one desktop, at most one of them holds
//! control and every other one gets frames only. The floor is an exclusive lock on
//! [`FLOOR_FILE`] in the host's directory, so it holds across the threads of `cmux-rd
//! linux-host` and across the session processes of the acpmux share host alike: a lock belongs
//! to its open file description, and each [`Seat`] opens its own.
//!
//! - A control session takes a seat that asks for control: the first to ask holds it; the
//!   rest are view only and are told who holds it (its holder writes its name in the file).
//! - The kernel lets go of the lock however the holder ends (a viewer leaving, a crash), so a
//!   waiting seat takes control at its next [`Seat::poll`]. No viewer is ever left holding
//!   control it cannot use.
//! - [`Seat::hand_over`] gives control up for a waiting viewer: the seat stops asking until
//!   [`Seat::ask`] asks again (and then waits like any other).
//! - A view session's seat never asks; it only reads who holds control.
//!
//! The session (`session::serve`) tells its helper the seat's state (`{"floor": ..}`), and the
//! helper applies no input of a seat that does not hold control: input is dropped at the host.

use cmux_file_lock::{FileLock, Kind, LockError};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// In the host's directory: locked by the viewer that holds control, which writes its name there.
pub const FLOOR_FILE: &str = "control.lock";

/// The longest holder name read back.
const MAX_NAME: u64 = 256;

/// What a seat may do now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FloorState {
    /// This seat holds control: its input is applied.
    Control,
    /// Frames only. `holder` names the viewer that holds control, None when nobody does.
    ViewOnly { holder: Option<String> },
}

impl FloorState {
    /// The `{"control": .., "holder": ..}` the helper reads (`cmux-rd serve`'s `floor`).
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Self::Control => serde_json::json!({ "control": true }),
            Self::ViewOnly { holder } => serde_json::json!({ "control": false, "holder": holder }),
        }
    }
}

/// One viewer's place at the floor of `dir`.
#[derive(Debug)]
pub struct Seat {
    path: PathBuf,
    name: String,
    wants: bool,
    held: Option<FileLock>,
}

impl Seat {
    /// A seat for viewer `name`; `wants` when it asks for control (a control session).
    pub fn new(dir: &Path, name: &str, wants: bool) -> Self {
        Self { path: dir.join(FLOOR_FILE), name: name.to_owned(), wants, held: None }
    }

    /// Whether this seat holds control.
    pub fn holds(&self) -> bool {
        self.held.is_some()
    }

    /// Takes control when this seat asks and nobody holds it; what this seat may do now. An
    /// error reading the floor is view only: control is never given on a failure.
    pub fn poll(&mut self) -> FloorState {
        if self.held.is_some() {
            return FloorState::Control;
        }
        let file = match self.open() {
            Ok(file) => file,
            Err(e) => {
                eprintln!("floor: {}: {e}", self.path.display());
                return FloorState::ViewOnly { holder: None };
            }
        };
        if self.wants {
            match FileLock::try_take(file, Kind::Exclusive) {
                Ok(mut held) => {
                    let named = write_name(held.file_mut(), &self.name);
                    if let Err(e) = named {
                        eprintln!("floor: holder not written: {e}");
                    }
                    self.held = Some(held);
                    return FloorState::Control;
                }
                Err(LockError::Busy(mut file)) => {
                    return FloorState::ViewOnly { holder: read_name(&mut file) };
                }
                Err(LockError::Io(e)) => {
                    eprintln!("floor: {}: {e}", self.path.display());
                    return FloorState::ViewOnly { holder: None };
                }
            }
        }
        let mut file = file;
        match FileLock::held_elsewhere(&file, Kind::Exclusive) {
            Ok(true) => FloorState::ViewOnly { holder: read_name(&mut file) },
            Ok(false) | Err(_) => FloorState::ViewOnly { holder: None },
        }
    }

    /// Gives control up for a viewer that waits for it; this seat asks no more until [`Self::ask`].
    pub fn hand_over(&mut self) {
        self.wants = false;
        self.held = None;
    }

    /// Asks for control again; it is taken at the next [`Self::poll`] once nobody holds it.
    pub fn ask(&mut self) {
        self.wants = true;
    }

    fn open(&self) -> std::io::Result<File> {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&self.path)
    }
}

fn write_name(file: &mut File, name: &str) -> std::io::Result<()> {
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    file.write_all(crate::printable(name).as_bytes())?;
    file.flush()
}

fn read_name(file: &mut File) -> Option<String> {
    let mut name = String::new();
    file.seek(SeekFrom::Start(0)).ok()?;
    file.take(MAX_NAME).read_to_string(&mut name).ok()?;
    let name = name.trim();
    (!name.is_empty()).then(|| name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn floor_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-floor-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn view_only(holder: &str) -> FloorState {
        FloorState::ViewOnly { holder: Some(holder.to_owned()) }
    }

    #[test]
    fn the_first_viewer_gets_control_and_the_second_sees_who_has_it() {
        let dir = floor_dir("first");
        let mut ann = Seat::new(&dir, "Ann's Mac", true);
        let mut bob = Seat::new(&dir, "Bob's Mac", true);
        assert_eq!(ann.poll(), FloorState::Control);
        assert_eq!(bob.poll(), view_only("Ann's Mac"));
        // Bob waits: asking again changes nothing while Ann holds it.
        assert_eq!(bob.poll(), view_only("Ann's Mac"));
        assert_eq!(ann.poll(), FloorState::Control);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn control_passes_to_the_waiting_viewer_when_the_controller_leaves() {
        let dir = floor_dir("leave");
        let mut ann = Seat::new(&dir, "Ann's Mac", true);
        let mut bob = Seat::new(&dir, "Bob's Mac", true);
        assert_eq!(ann.poll(), FloorState::Control);
        assert_eq!(bob.poll(), view_only("Ann's Mac"));
        drop(ann);
        assert_eq!(bob.poll(), FloorState::Control);
        // A viewer that comes later waits behind Bob.
        let mut cy = Seat::new(&dir, "Cy's PC", true);
        assert_eq!(cy.poll(), view_only("Bob's Mac"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_hand_over_gives_control_to_the_waiting_viewer_and_does_not_take_it_back() {
        let dir = floor_dir("hand-over");
        let mut ann = Seat::new(&dir, "Ann's Mac", true);
        let mut bob = Seat::new(&dir, "Bob's Mac", true);
        assert_eq!(ann.poll(), FloorState::Control);
        assert_eq!(bob.poll(), view_only("Ann's Mac"));
        ann.hand_over();
        assert_eq!(ann.poll(), FloorState::ViewOnly { holder: None });
        assert_eq!(bob.poll(), FloorState::Control);
        assert_eq!(ann.poll(), view_only("Bob's Mac"));
        // Ann asks again: she waits until Bob leaves.
        ann.ask();
        assert_eq!(ann.poll(), view_only("Bob's Mac"));
        drop(bob);
        assert_eq!(ann.poll(), FloorState::Control);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_view_session_never_takes_control() {
        let dir = floor_dir("view");
        let mut watcher = Seat::new(&dir, "Dee's iPad", false);
        assert_eq!(watcher.poll(), FloorState::ViewOnly { holder: None });
        assert!(!watcher.holds());
        let mut ann = Seat::new(&dir, "Ann's Mac", true);
        assert_eq!(ann.poll(), FloorState::Control);
        assert_eq!(watcher.poll(), view_only("Ann's Mac"));
        drop(ann);
        // Free, and still the view session does not take it.
        assert_eq!(watcher.poll(), FloorState::ViewOnly { holder: None });
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_hostile_name_is_written_printable() {
        let dir = floor_dir("name");
        let mut ann = Seat::new(&dir, "Ann\u{1b}[2J\nMac", true);
        assert_eq!(ann.poll(), FloorState::Control);
        let FloorState::ViewOnly { holder: Some(holder) } = Seat::new(&dir, "b", true).poll()
        else {
            panic!("not view only")
        };
        assert!(!holder.chars().any(char::is_control), "{holder:?}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_helper_reads_the_state_as_control_and_holder() {
        assert_eq!(FloorState::Control.to_json(), serde_json::json!({ "control": true }));
        assert_eq!(
            view_only("Ann").to_json(),
            serde_json::json!({ "control": false, "holder": "Ann" })
        );
    }
}
