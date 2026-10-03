//! POSIX ACLs in the text forms `setfacl` takes and `getfacl -n` prints. Numeric ids only, so the
//! reconciler never depends on name resolution.

use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Perm(pub u8);

impl Perm {
    pub const NONE: Perm = Perm(0);
    pub const RX: Perm = Perm(0b101);
    pub const RWX: Perm = Perm(0b111);

    pub fn text(self) -> String {
        let b = |bit: u8, c: char| if self.0 & bit != 0 { c } else { '-' };
        [b(4, 'r'), b(2, 'w'), b(1, 'x')].iter().collect()
    }

    pub fn parse(s: &str) -> Option<Perm> {
        let c: Vec<char> = s.chars().collect();
        if c.len() != 3 {
            return None;
        }
        let bit = |i: usize, want: char, v: u8| match c[i] {
            x if x == want => Some(v),
            '-' => Some(0),
            _ => None,
        };
        Some(Perm(bit(0, 'r', 4)? | bit(1, 'w', 2)? | bit(2, 'x', 1)?))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Tag {
    UserObj,
    User(u32),
    GroupObj,
    Group(u32),
    Mask,
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct AclEntry {
    pub tag: Tag,
    pub perm: Perm,
}

impl AclEntry {
    pub fn user_obj(perm: Perm) -> Self {
        Self { tag: Tag::UserObj, perm }
    }
    pub fn group_obj(perm: Perm) -> Self {
        Self { tag: Tag::GroupObj, perm }
    }
    pub fn group(gid: u32, perm: Perm) -> Self {
        Self { tag: Tag::Group(gid), perm }
    }
    pub fn mask(perm: Perm) -> Self {
        Self { tag: Tag::Mask, perm }
    }
    pub fn other(perm: Perm) -> Self {
        Self { tag: Tag::Other, perm }
    }

    fn text(&self) -> String {
        let p = self.perm.text();
        match self.tag {
            Tag::UserObj => format!("u::{p}"),
            Tag::User(id) => format!("u:{id}:{p}"),
            Tag::GroupObj => format!("g::{p}"),
            Tag::Group(id) => format!("g:{id}:{p}"),
            Tag::Mask => format!("m::{p}"),
            Tag::Other => format!("o::{p}"),
        }
    }
}

/// A set of entries (order does not matter to the kernel).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Acl(pub BTreeSet<AclEntry>);

impl Acl {
    pub fn new(entries: Vec<AclEntry>) -> Self {
        Self(entries.into_iter().collect())
    }

    /// `setfacl --set` argument.
    pub fn spec(&self) -> String {
        self.0.iter().map(AclEntry::text).collect::<Vec<_>>().join(",")
    }

    /// Only the three base entries (no named entry, no mask): an ACL the mode bits fully describe.
    pub fn is_minimal(&self) -> bool {
        self.0.iter().all(|e| matches!(e.tag, Tag::UserObj | Tag::GroupObj | Tag::Other))
    }
}

/// The access and default ACL of one path, from `getfacl -n -p --omit-header`.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct PathAcl {
    pub access: Acl,
    pub default: Acl,
}

/// Parses `getfacl -n -p --omit-header <path>` output. Effective-rights comments (`#effective:`)
/// and blank lines are ignored; an unknown line is an error (never guessed).
pub fn parse_getfacl(text: &str) -> Result<PathAcl, String> {
    let mut out = PathAcl::default();
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let (target, rest) = match line.strip_prefix("default:") {
            Some(r) => (&mut out.default, r),
            None => (&mut out.access, line),
        };
        let parts: Vec<&str> = rest.split(':').collect();
        if parts.len() != 3 {
            return Err(format!("unexpected getfacl line {raw:?}"));
        }
        let perm =
            Perm::parse(parts[2]).ok_or_else(|| format!("unexpected permissions in {raw:?}"))?;
        let id = |s: &str| s.parse::<u32>().map_err(|_| format!("non-numeric id in {raw:?}"));
        let tag = match (parts[0], parts[1]) {
            ("user", "") => Tag::UserObj,
            ("user", q) => Tag::User(id(q)?),
            ("group", "") => Tag::GroupObj,
            ("group", q) => Tag::Group(id(q)?),
            ("mask", "") => Tag::Mask,
            ("other", "") => Tag::Other,
            _ => return Err(format!("unexpected getfacl line {raw:?}")),
        };
        target.0.insert(AclEntry { tag, perm });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_access_and_default_entries_and_round_trips_the_spec() {
        let text = "user::rwx\ngroup::rwx\t\t\t#effective:rwx\ngroup:200000:r-x\nmask::rwx\nother::---\ndefault:user::rwx\ndefault:group::rwx\ndefault:group:200000:r-x\ndefault:mask::rwx\ndefault:other::---\n\n";
        let a = parse_getfacl(text).expect("parses");
        let want = Acl::new(vec![
            AclEntry::user_obj(Perm::RWX),
            AclEntry::group_obj(Perm::RWX),
            AclEntry::group(200_000, Perm::RX),
            AclEntry::mask(Perm::RWX),
            AclEntry::other(Perm::NONE),
        ]);
        assert_eq!(a.access, want);
        assert_eq!(a.default, want);
        assert_eq!(want.spec(), "u::rwx,g::rwx,g:200000:r-x,m::rwx,o::---");
        assert!(!want.is_minimal());
        let plain = parse_getfacl("user::rwx\ngroup::--x\nother::--x\n").expect("parses");
        assert!(plain.access.is_minimal() && plain.default.0.is_empty());
    }

    #[test]
    fn refuses_names_and_unknown_lines() {
        assert!(parse_getfacl("group:staff:r-x\n").is_err());
        assert!(parse_getfacl("flags::s--\n").is_err());
        assert!(parse_getfacl("user::rwz\n").is_err());
    }
}
