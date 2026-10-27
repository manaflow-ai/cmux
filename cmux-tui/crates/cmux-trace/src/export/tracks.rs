//! The exporter's tracks: each `TrackDescriptor` once, in the order first used, keyed by a uuid
//! that is a hash of what the track is (Perfetto's `perfetto::Track(uuid)`), so the same process,
//! thread or async interval from two rings lands on one track.

use std::collections::HashMap;

use super::field;
use crate::proto::Message;

/// What a track is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TrackKind {
    Process {
        pid: i32,
        name: Option<String>,
        labels: Vec<String>,
    },
    Thread {
        pid: i32,
        tid: i64,
        name: Option<String>,
        description: Option<String>,
    },
    /// An async track, a thread with no thread entry, or a global track.
    Named {
        name: String,
    },
    /// A remote machine's process or thread. trace_processor resolves pid and tid descriptors on
    /// one machine, so a remote pid or tid that equals a local one would join the local process
    /// or thread. A named track keeps it apart and its flows joined to local ones, which a
    /// `TracePacket.machine_id` would not: trace_processor joins flows within one machine.
    Remote {
        name: String,
        description: Option<String>,
    },
    Counter {
        name: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Track {
    pub parent: Option<u64>,
    pub kind: TrackKind,
}

#[derive(Default)]
pub(crate) struct Tracks {
    order: Vec<(u64, Track)>,
    index: HashMap<u64, usize>,
}

impl Tracks {
    /// The track `uuid`, made by `make` the first time.
    pub(crate) fn insert(&mut self, uuid: u64, make: impl FnOnce() -> Track) -> u64 {
        if !self.index.contains_key(&uuid) {
            self.index.insert(uuid, self.order.len());
            self.order.push((uuid, make()));
        }
        uuid
    }

    /// The process track of `pid` on machine `machine_key` (0 local, k remote machine k - 1).
    pub(crate) fn process(
        &mut self,
        machine_key: u64,
        pid: u32,
        make: impl FnOnce() -> TrackKind,
    ) -> u64 {
        let uuid = uuid_of(&[b"process", &machine_key.to_le_bytes(), &pid.to_le_bytes()]);
        self.insert(uuid, || Track { parent: None, kind: make() })
    }

    pub(crate) fn get_mut(&mut self, uuid: u64) -> Option<&mut Track> {
        self.index.get(&uuid).map(|&at| &mut self.order[at].1)
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = (u64, &Track)> {
        self.order.iter().map(|(uuid, track)| (*uuid, track))
    }
}

/// A track uuid: FNV-1a over each part with its length, then the splitmix64 finalizer. Never 0
/// (Perfetto's "no track").
pub(crate) fn uuid_of(parts: &[&[u8]]) -> u64 {
    let mut hash: u64 = 0xCBF2_9CE4_8422_2325;
    let mut eat = |byte: u8| {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
    };
    for part in parts {
        for byte in (part.len() as u64).to_le_bytes() {
            eat(byte);
        }
        for &byte in *part {
            eat(byte);
        }
    }
    let mut mixed = hash;
    mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    mixed ^= mixed >> 31;
    mixed.max(1)
}

/// Writes a `TrackDescriptor`'s fields.
pub(crate) fn encode(descriptor: &mut Message, uuid: u64, track: &Track) {
    descriptor.uint(field::TRACK_UUID, uuid);
    if let Some(parent) = track.parent {
        descriptor.uint(field::TRACK_PARENT_UUID, parent);
    }
    match &track.kind {
        TrackKind::Process { pid, name, labels } => {
            descriptor.message(field::TRACK_PROCESS, |process| {
                process.int(field::PROCESS_PID, i64::from(*pid));
                if let Some(name) = name {
                    process.string(field::PROCESS_NAME, name);
                }
                for label in labels {
                    process.string(field::PROCESS_LABELS, label);
                }
            });
        }
        TrackKind::Thread { pid, tid, name, description } => {
            descriptor.message(field::TRACK_THREAD, |thread| {
                thread.int(field::THREAD_PID, i64::from(*pid)).int(field::THREAD_TID, *tid);
                if let Some(name) = name {
                    thread.string(field::THREAD_NAME, name);
                }
            });
            if let Some(description) = description {
                descriptor.string(field::TRACK_DESCRIPTION, description);
            }
        }
        TrackKind::Named { name } => {
            descriptor.string(field::TRACK_NAME, name);
        }
        TrackKind::Remote { name, description } => {
            descriptor.string(field::TRACK_NAME, name);
            if let Some(description) = description {
                descriptor.string(field::TRACK_DESCRIPTION, description);
            }
        }
        TrackKind::Counter { name } => {
            descriptor.string(field::TRACK_NAME, name);
            descriptor.message(field::TRACK_COUNTER, |_| {});
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_uuid_depends_on_every_part_and_its_boundaries() {
        let a = uuid_of(&[b"ab", b"c"]);
        assert_ne!(a, uuid_of(&[b"a", b"bc"]), "part boundaries count");
        assert_ne!(a, uuid_of(&[b"ab", b"d"]));
        assert_eq!(a, uuid_of(&[b"ab", b"c"]), "stable");
        assert_ne!(uuid_of(&[]), 0);
    }

    #[test]
    fn a_track_is_made_once() {
        let mut tracks = Tracks::default();
        let first = tracks.process(0, 7, || TrackKind::Process {
            pid: 7,
            name: Some("app".into()),
            labels: vec![],
        });
        let again = tracks.process(0, 7, || unreachable!("made once"));
        assert_eq!(first, again);
        assert_ne!(first, tracks.process(1, 7, || TrackKind::Named { name: "remote".into() }));
        assert_eq!(tracks.iter().count(), 2);
    }
}
