/// The kind of one logged message (section 2).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    /// The user's words; also a subagent's report, "[id] report".
    User,
    /// The agent's replies.
    Talk,
    /// The agent's tool calls, as text: name and JSON input.
    Tool,
    /// Tool results, capped at `CAP` characters.
    Echo,
    /// Memories imported from an older system.
    Note,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::User => "user",
            Kind::Talk => "talk",
            Kind::Tool => "tool",
            Kind::Echo => "echo",
            Kind::Note => "note",
        }
    }

    pub fn parse(s: &str) -> Option<Kind> {
        Some(match s {
            "user" => Kind::User,
            "talk" => Kind::Talk,
            "tool" => Kind::Tool,
            "echo" => Kind::Echo,
            "note" => Kind::Note,
            _ => return None,
        })
    }
}

/// A tree node `(l, i)`: it covers messages `[i·2^l, (i+1)·2^l)` (section 3).
/// Level 0 summarizes one message; level `l > 0` merges its two children.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NodeId {
    pub l: u32,
    pub i: u64,
}

impl NodeId {
    pub const fn new(l: u32, i: u64) -> NodeId {
        NodeId { l, i }
    }

    /// How many messages it covers: `2^l`.
    pub const fn n(self) -> u64 {
        1 << self.l
    }

    /// Its first message.
    pub const fn start(self) -> u64 {
        self.i << self.l
    }

    /// One past its last message.
    pub const fn end(self) -> u64 {
        (self.i + 1) << self.l
    }

    pub const fn children(self) -> Option<(NodeId, NodeId)> {
        if self.l == 0 {
            return None;
        }
        Some((
            NodeId::new(self.l - 1, 2 * self.i),
            NodeId::new(self.l - 1, 2 * self.i + 1),
        ))
    }

    pub const fn parent(self) -> NodeId {
        NodeId::new(self.l + 1, self.i / 2)
    }

    /// `id+n`, as the view and `zoom` name it: its first message and how many it covers.
    pub fn name(self) -> String {
        format!("{}+{}", self.start(), self.n())
    }

    /// The node `zoom(id, n)` names, if `n` is a power of two and `id` a multiple of it.
    pub fn from_name(id: u64, n: u64) -> Option<NodeId> {
        if n == 0 || !n.is_power_of_two() || !id.is_multiple_of(n) {
            return None;
        }
        let l = n.trailing_zeros();
        Some(NodeId::new(l, id >> l))
    }
}
