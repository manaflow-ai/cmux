//! What the machine has now: `/etc/passwd`, `/etc/group` and the state of each managed directory.

use crate::acl::PathAcl;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PasswdEntry {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub home: String,
    pub shell: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GroupEntry {
    pub name: String,
    pub gid: u32,
    pub members: BTreeSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirState {
    /// False when the path exists but is not a real directory (a file or a symlink): never touched.
    pub is_dir: bool,
    pub uid: u32,
    pub gid: u32,
    pub mode: u32,
    pub acl: PathAcl,
}

#[derive(Clone, Debug, Default)]
pub struct Observed {
    pub users: BTreeMap<String, PasswdEntry>,
    pub groups: BTreeMap<String, GroupEntry>,
    /// Missing paths are absent (or `None`).
    pub dirs: BTreeMap<PathBuf, Option<DirState>>,
}

impl Observed {
    pub fn user_by_uid(&self, uid: u32) -> Option<&PasswdEntry> {
        self.users.values().find(|u| u.uid == uid)
    }

    pub fn group_by_gid(&self, gid: u32) -> Option<&GroupEntry> {
        self.groups.values().find(|g| g.gid == gid)
    }

    /// Supplementary groups of `user` (groups that list it as a member).
    pub fn supplementary(&self, user: &str) -> BTreeSet<String> {
        self.groups.values().filter(|g| g.members.contains(user)).map(|g| g.name.clone()).collect()
    }
}

/// `name:x:uid:gid:gecos:home:shell` lines; comments, blanks and NIS `+` lines are skipped.
pub fn parse_passwd(text: &str) -> Result<BTreeMap<String, PasswdEntry>, String> {
    let mut out = BTreeMap::new();
    for line in text.lines() {
        if line.trim().is_empty()
            || line.starts_with('#')
            || line.starts_with('+')
            || line.starts_with('-')
        {
            continue;
        }
        let f: Vec<&str> = line.split(':').collect();
        if f.len() != 7 {
            return Err(format!("unexpected passwd line {line:?}"));
        }
        let num = |s: &str| s.parse::<u32>().map_err(|_| format!("bad id in passwd line {line:?}"));
        out.insert(
            f[0].to_string(),
            PasswdEntry {
                name: f[0].to_string(),
                uid: num(f[2])?,
                gid: num(f[3])?,
                home: f[5].to_string(),
                shell: f[6].to_string(),
            },
        );
    }
    Ok(out)
}

/// `name:x:gid:a,b,c` lines.
pub fn parse_group(text: &str) -> Result<BTreeMap<String, GroupEntry>, String> {
    let mut out = BTreeMap::new();
    for line in text.lines() {
        if line.trim().is_empty()
            || line.starts_with('#')
            || line.starts_with('+')
            || line.starts_with('-')
        {
            continue;
        }
        let f: Vec<&str> = line.split(':').collect();
        if f.len() != 4 {
            return Err(format!("unexpected group line {line:?}"));
        }
        let gid = f[2].parse::<u32>().map_err(|_| format!("bad gid in group line {line:?}"))?;
        let members = f[3].split(',').filter(|m| !m.is_empty()).map(str::to_string).collect();
        out.insert(f[0].to_string(), GroupEntry { name: f[0].to_string(), gid, members });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_passwd_and_group() {
        let p = parse_passwd("root:x:0:0:root:/root:/bin/bash\n# c\nlawrence:x:20000:20000::/home/lawrence:/bin/bash\n").expect("passwd");
        assert_eq!(p["lawrence"].uid, 20_000);
        assert_eq!(p["lawrence"].home, "/home/lawrence");
        let g = parse_group("n-acme-r:x:200000:lawrence,aziz\nmuxes:x:199999:\n").expect("group");
        assert_eq!(g["n-acme-r"].members.len(), 2);
        assert!(g["muxes"].members.is_empty());
        assert!(parse_passwd("broken:x:1\n").is_err());
        assert!(parse_group("g:x:notanumber:\n").is_err());
    }
}
