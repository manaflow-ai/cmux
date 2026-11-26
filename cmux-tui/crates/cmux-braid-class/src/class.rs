//! The class enum and its rules (RFD 0164 "Framing and classes").

use std::fmt;

/// One of Braid's four data classes. The discriminant is the 2-bit `class` field of the
/// Braid frame header, so it never changes for an existing class.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Class {
    /// Class 0: keystrokes and other small, latency-bound input. Duplicated on the best
    /// two paths, repaired at any loss, reordered at the far end by `seq`.
    Input = 0,
    /// Class 1: interactive state (terminal screen, video frames). Latest wins: a newer
    /// state replaces an older one still queued; repaired only above 1 % measured loss.
    State = 1,
    /// Class 2: reliable ordered messages (control, RPC, tunnelled streams).
    Ordered = 2,
    /// Class 3: bulk transfers. Reliable, striped over the paths with the most capacity.
    Bulk = 3,
}

/// How a class is repaired against loss.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Repair {
    /// Repair (duplicate or FEC) at any loss.
    Always,
    /// Repair only while measured loss is above 1 %; below it the next state replaces a
    /// lost one sooner than parity would rebuild it.
    AboveOnePercent,
}

/// What a full class queue does with one more item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropRule {
    /// Refuse the newest: the sender keeps it and retries (nothing is lost silently).
    RefuseNewest,
    /// A newer item for the same stream replaces the queued one.
    LatestWins,
    /// Drop the oldest queued item: what the class carries resends on its own.
    DropOldest,
}

/// The order a class keeps at the far end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Order {
    /// Reordered by `seq` and deduplicated (duplicate copies arrive).
    BySeq,
    /// None: each item is a whole state.
    None,
    /// In order within each stream.
    PerStream,
    /// In order within each chunk.
    PerChunk,
}

/// How a class is carried.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Carried {
    Datagram,
    Stream,
}

/// A wire byte that names no class.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireClassError(pub u8);

impl fmt::Display for WireClassError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "unknown Braid class {}", self.0)
    }
}

impl std::error::Error for WireClassError {}

impl Class {
    /// Every class, highest priority first.
    pub const ALL: [Self; 4] = [Self::Input, Self::State, Self::Ordered, Self::Bulk];

    /// The 2-bit header value.
    pub const fn wire(self) -> u8 {
        self as u8
    }

    pub const fn from_wire(value: u8) -> Result<Self, WireClassError> {
        match value {
            0 => Ok(Self::Input),
            1 => Ok(Self::State),
            2 => Ok(Self::Ordered),
            3 => Ok(Self::Bulk),
            other => Err(WireClassError(other)),
        }
    }

    /// Scheduling rank, 0 first. Equal to the wire value: input, then state, then
    /// ordered, then bulk.
    pub const fn rank(self) -> u8 {
        self as u8
    }

    /// When the class is repaired. Bulk is repaired at any loss: a loss gate on bulk cut
    /// a TCP flood inside the tunnel from 24.6 to 3.5 Mbit/s at 0.5 % loss (50 ms RTT,
    /// cmux-wg `link_stream_bench`), because the loss window lags the flood.
    pub const fn repair(self) -> Repair {
        match self {
            Self::State => Repair::AboveOnePercent,
            Self::Input | Self::Ordered | Self::Bulk => Repair::Always,
        }
    }

    /// Whether to repair now, given the measured loss. `loss_above_one_percent` is only
    /// called for a class whose repair depends on it, so a caller can fold its loss
    /// window lazily.
    pub fn repairs_at(self, loss_above_one_percent: impl FnOnce() -> bool) -> bool {
        match self.repair() {
            Repair::Always => true,
            Repair::AboveOnePercent => loss_above_one_percent(),
        }
    }

    /// Whether each item is sent on two paths when two are alive.
    pub const fn duplicates(self) -> bool {
        matches!(self, Self::Input)
    }

    pub const fn drop_rule(self) -> DropRule {
        match self {
            Self::Input | Self::Ordered => DropRule::RefuseNewest,
            Self::State => DropRule::LatestWins,
            Self::Bulk => DropRule::DropOldest,
        }
    }

    pub const fn order(self) -> Order {
        match self {
            Self::Input => Order::BySeq,
            Self::State => Order::None,
            Self::Ordered => Order::PerStream,
            Self::Bulk => Order::PerChunk,
        }
    }

    pub const fn carried(self) -> Carried {
        match self {
            Self::Input | Self::State => Carried::Datagram,
            Self::Ordered | Self::Bulk => Carried::Stream,
        }
    }
}

impl fmt::Display for Class {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Input => "input",
            Self::State => "state",
            Self::Ordered => "ordered",
            Self::Bulk => "bulk",
        })
    }
}

#[cfg(test)]
#[path = "class_tests.rs"]
mod tests;
