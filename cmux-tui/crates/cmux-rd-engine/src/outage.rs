//! D12, host half: what the host's pacer still holds when an outage ends.
//!
//! Sending it delays the newest picture behind frames queued while the radio
//! was away, but dropping a frame the encoder's next frame predicts from means
//! starting over from a keyframe, and on a long hold that keyframe can cost
//! more than the stale queue. So the drop is per stream and only of whole
//! frames none of whose datagrams has left: a frame that has started finishes
//! (the viewer holds its head). It is free when nothing kept or encoded next
//! predicts from a dropped frame, or when the stream's next frame is a
//! keyframe already; otherwise it happens only when the stream's unstarted
//! frames are larger than its last keyframe.

use std::collections::{BTreeMap, BTreeSet};

use cmux_rd_proto::{DatagramHeader, DatagramKind};

use crate::{IdrReason, MediaEngine, Output};

/// One stream's frames in the pacer queue, in send order: (frame, bytes queued,
/// datagrams queued).
type Queued = Vec<(u32, usize, usize)>;

impl MediaEngine {
    /// The (stream, frame) pairs to drop from `queued`, the host's pacer queue in
    /// send order, now that an outage ended (`out` is the output that says so).
    pub fn outage_drop_plan<'a>(
        &self,
        queued: impl IntoIterator<Item = &'a [u8]>,
        out: &Output,
    ) -> BTreeSet<(u16, u32)> {
        let mut streams: BTreeMap<u16, Queued> = BTreeMap::new();
        for d in queued {
            let Ok((h, _)) = DatagramHeader::decode(d) else { continue };
            if !matches!(h.kind, DatagramKind::Video | DatagramKind::Fec) {
                continue;
            }
            let frames = streams.entry(h.stream).or_default();
            match frames.last_mut() {
                Some((frame, bytes, count)) if *frame == h.frame => {
                    *bytes += d.len();
                    *count += 1;
                }
                _ => frames.push((h.frame, d.len(), 1)),
            }
        }
        let mut drop = BTreeSet::new();
        for (stream, frames) in streams {
            let Some(state) = self.streams.get(&stream) else { continue };
            // A frame whose datagrams are not all queued has started to leave. Frames
            // after it are unstarted (the queue is in send order).
            let unstarted: Vec<(u32, usize)> = frames
                .iter()
                .rev()
                .take_while(|(frame, _, count)| {
                    state.history.get(frame).is_some_and(|h| h.len() == *count)
                })
                .map(|&(frame, bytes, _)| (frame, bytes))
                .collect();
            if unstarted.is_empty() {
                continue;
            }
            // The encoder predicts its next frame from the stream's last one, and the
            // dropped frames are the stream's newest, so a video stream's next frame
            // depends on a dropped one; a tile frame is standalone but carries damage
            // only a refresh restores.
            let depended_on = state.tile_of.is_some()
                || unstarted.iter().any(|&(frame, _)| frame == state.last_frame);
            let keyframe_due = state.force_idr.is_some()
                || out.encode.as_ref().is_some_and(|r| r.stream == stream && r.force_idr);
            let bytes: usize = unstarted.iter().map(|&(_, b)| b).sum();
            let worth_a_keyframe =
                state.last_keyframe_bytes > 0 && bytes > state.last_keyframe_bytes;
            if !depended_on || keyframe_due || worth_a_keyframe {
                drop.extend(unstarted.iter().map(|&(frame, _)| (stream, frame)));
            }
        }
        drop
    }

    /// The host's strict pacer dropped these whole, never-sent frames at its queue
    /// limit (D2: newest frame wins). They leave the controller and the loss meter, so a
    /// datagram never sent is not read as loss (which over 5% would cut ultra); nothing
    /// is asked for, and their frames stay in the NACK history.
    pub fn forget_unsent(&mut self, dropped: &[Vec<u8>]) {
        for d in dropped {
            let Ok((header, _)) = DatagramHeader::decode(d) else { continue };
            if matches!(header.kind, DatagramKind::Video | DatagramKind::Fec) {
                self.cc.on_dropped(header.transport_seq);
                self.loss_meter.forget(header.transport_seq);
            }
        }
    }

    /// The host dropped `stale` (the datagrams `outage_drop_plan` picked) from its
    /// pacer. They are retired from the controller and the loss meter (a datagram
    /// never sent is not loss) and their frames leave the NACK history. A stream
    /// whose next frame would predict from a dropped one starts over from a keyframe
    /// of the newest picture: `out.encode` becomes that keyframe when it is for such
    /// a stream, and is asked for when there is none.
    pub fn retire_unsent(&mut self, stale: &[Vec<u8>], out: &mut Output, now_us: u64) {
        let mut dropped: BTreeMap<u16, Vec<u32>> = BTreeMap::new();
        for d in stale {
            let Ok((header, _)) = DatagramHeader::decode(d) else { continue };
            if !matches!(header.kind, DatagramKind::Video | DatagramKind::Fec) {
                continue;
            }
            self.cc.on_dropped(header.transport_seq);
            self.loss_meter.forget(header.transport_seq);
            let frames = dropped.entry(header.stream).or_default();
            if frames.last() != Some(&header.frame) {
                frames.push(header.frame);
            }
        }
        let mut restart = Vec::new();
        for (&stream, frames) in &dropped {
            let Some(state) = self.streams.get_mut(&stream) else { continue };
            for frame in frames {
                state.history.remove(frame);
                state.sent_at_us.remove(frame);
            }
            state.probe_from_us = None;
            state.probes = 0;
            if state.tile_of.is_some() || frames.contains(&state.last_frame) {
                state.force_idr.get_or_insert(IdrReason::Outage);
                restart.push(stream);
            }
        }
        // The outage end already cleared every gate's in-flight count.
        match out.encode.as_mut() {
            Some(req) if restart.contains(&req.stream) => {
                if !req.force_idr {
                    req.force_idr = true;
                    req.idr_reason = Some(IdrReason::Outage);
                }
            }
            Some(_) => {}
            None => {
                let Some(&stream) = restart.first() else { return };
                let Some(state) = self.streams.get_mut(&stream) else { return };
                let full = state.full();
                let action = state.gate.damage(full, now_us);
                out.encode = self.request(stream, action);
            }
        }
    }
}
