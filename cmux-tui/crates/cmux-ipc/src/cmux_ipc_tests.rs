//! Tests are named `cmux_ipc_tests::…` so `cmux-tui-focused-test.sh cmux_ipc`
//! selects every one of them.

mod cli_wire_emitter_tests;
#[cfg(feature = "client")]
mod cli_wire_tests;
mod frame_tests;
mod golden_tests;
mod lane_writer_tests;
mod methods_table_tests;
mod reader_tests;
mod schema_tests;
mod server_families_tests;

use bytes::{Bytes, BytesMut};

use crate::{
    Aux, BadMessage, CallAux, CallFlags, Frame, FrameKind, FrameReader, Message, PriorityHint,
};

/// An owned copy of a `Message`, for comparing whole sequences.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Got {
    Line(String),
    Frame(Frame),
}

impl Got {
    fn of(message: Message<'_>) -> Got {
        match message {
            Message::Json(line) => Got::Line(line.to_owned()),
            Message::Frame(frame) => Got::Frame(frame),
        }
    }
}

/// Drains every message the reader has, stopping at the first error.
pub(crate) fn drain(reader: &mut FrameReader) -> Result<Vec<Got>, BadMessage> {
    let mut out = Vec::new();
    while let Some(message) = reader.next_message()? {
        out.push(Got::of(message));
    }
    Ok(out)
}

/// A reader with frames negotiated and default limits.
pub(crate) fn framed_reader() -> FrameReader {
    let mut reader = FrameReader::new(Default::default());
    reader.negotiate_frames();
    reader
}

/// One frame of every kind with a distinctive aux.
pub(crate) fn one_of_each_kind() -> Vec<Frame> {
    FrameKind::ALL
        .into_iter()
        .enumerate()
        .map(|(index, kind)| {
            let stream = if kind.needs_data_stream() { 3 } else { 0 };
            let aux = sample_aux(kind, index as u64);
            let payload = Bytes::from(format!("{}-payload\nwith a newline", kind.name()));
            Frame::new(kind, stream, aux, payload).unwrap()
        })
        .collect()
}

pub(crate) fn sample_aux(kind: FrameKind, seed: u64) -> Aux {
    let value = 0x0123_4567_89ab_cdef_u64.rotate_left(seed as u32);
    match kind.aux_class() {
        crate::AuxClass::Offset => Aux::Offset(value),
        crate::AuxClass::FlowId => Aux::FlowId(value),
        crate::AuxClass::SharedBufferSize => Aux::SharedBufferSize(value),
        crate::AuxClass::Call => Aux::Call(CallAux {
            request_id: u32::MAX - seed as u32,
            method_id: 0x6000 | seed as u16,
            priority: PriorityHint::ALL[seed as usize % PriorityHint::ALL.len()],
            flags: CallFlags::MORE.with(CallFlags::BINARY),
        }),
    }
}

pub(crate) fn encode_all(frames: &[Frame]) -> BytesMut {
    let mut out = BytesMut::new();
    for frame in frames {
        frame.encode_into(&mut out);
    }
    out
}
