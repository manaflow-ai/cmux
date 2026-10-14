//! The OSC 7501 program status tail of a Snapshot payload
//! (`FLAG_PROGRAM_STATUS`, cx-6so.36.6): the host's records, so a daemon that
//! adopts the host after a restart shows what the programs last reported.
//!
//! Layout: next_seq:u64, count:u16, then per record id:string, state:u8,
//! kind:u8 (0 none), progress:u8 (255 none), app, title and message as
//! optional strings, updated_seq:u64, updated_at_ms:u64.

use ghostty_vt::{ProgramStatusKind, ProgramStatusState};

use super::codec::{PayloadDecoder, put_optional_string, put_string};
use crate::program_status::{MAX_RECORDS, ProgramStatusRecord, ProgramStatusSnapshot};

const NO_PROGRESS: u8 = u8::MAX;

pub(crate) fn put_program_status(
    output: &mut Vec<u8>,
    snapshot: &ProgramStatusSnapshot,
) -> anyhow::Result<()> {
    if snapshot.records.len() > MAX_RECORDS {
        anyhow::bail!("terminal-host program status has too many records");
    }
    output.extend_from_slice(&snapshot.next_seq.to_le_bytes());
    output.extend_from_slice(&(snapshot.records.len() as u16).to_le_bytes());
    for (id, record) in &snapshot.records {
        put_string(output, id)?;
        output.push(state_code(record.state)?);
        output.push(record.kind.map_or(0, kind_code));
        output.push(record.progress.unwrap_or(NO_PROGRESS));
        put_optional_string(output, record.app.as_deref())?;
        put_optional_string(output, record.title.as_deref())?;
        put_optional_string(output, record.message.as_deref())?;
        output.extend_from_slice(&record.updated_seq.to_le_bytes());
        output.extend_from_slice(&record.updated_at_ms.to_le_bytes());
    }
    Ok(())
}

pub(crate) fn program_status(
    decoder: &mut PayloadDecoder<'_>,
) -> anyhow::Result<ProgramStatusSnapshot> {
    let next_seq = decoder.u64()?;
    let count = decoder.u16()? as usize;
    if count > MAX_RECORDS {
        anyhow::bail!("terminal-host program status has too many records");
    }
    let mut records = Vec::with_capacity(count);
    for _ in 0..count {
        let id = decoder.string()?;
        let state = state_from_code(decoder.u8()?)?;
        let kind = kind_from_code(decoder.u8()?)?;
        let progress = match decoder.u8()? {
            NO_PROGRESS => None,
            value if value <= 100 => Some(value),
            _ => anyhow::bail!("terminal-host program status progress is out of range"),
        };
        let record = ProgramStatusRecord {
            state,
            kind,
            progress,
            app: decoder.optional_string()?,
            title: decoder.optional_string()?,
            message: decoder.optional_string()?,
            updated_seq: decoder.u64()?,
            updated_at_ms: decoder.u64()?,
            since_ms: 0,
        };
        // Older hosts and this layout carry no state start: count from the last report.
        let record = ProgramStatusRecord { since_ms: record.updated_at_ms, ..record };
        records.push((id, record));
    }
    Ok(ProgramStatusSnapshot { records, next_seq })
}

fn state_code(state: ProgramStatusState) -> anyhow::Result<u8> {
    Ok(match state {
        ProgramStatusState::Idle => 1,
        ProgramStatusState::Working => 2,
        ProgramStatusState::Done => 3,
        ProgramStatusState::Blocked => 4,
        ProgramStatusState::Error => 5,
        ProgramStatusState::Clear => anyhow::bail!("a kept program status record is never clear"),
    })
}

fn state_from_code(code: u8) -> anyhow::Result<ProgramStatusState> {
    Ok(match code {
        1 => ProgramStatusState::Idle,
        2 => ProgramStatusState::Working,
        3 => ProgramStatusState::Done,
        4 => ProgramStatusState::Blocked,
        5 => ProgramStatusState::Error,
        _ => anyhow::bail!("bad terminal-host program status state"),
    })
}

fn kind_code(kind: ProgramStatusKind) -> u8 {
    match kind {
        ProgramStatusKind::Permission => 1,
        ProgramStatusKind::Question => 2,
        ProgramStatusKind::Auth => 3,
    }
}

fn kind_from_code(code: u8) -> anyhow::Result<Option<ProgramStatusKind>> {
    Ok(match code {
        0 => None,
        1 => Some(ProgramStatusKind::Permission),
        2 => Some(ProgramStatusKind::Question),
        3 => Some(ProgramStatusKind::Auth),
        _ => anyhow::bail!("bad terminal-host program status kind"),
    })
}
