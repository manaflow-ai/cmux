//! The reconciler against an in-memory model of the shadow tools, setfacl and the POSIX ACL
//! access check. Runs anywhere without root; tests/root.rs runs the same checks on a real Linux
//! machine as root.

mod common;

use cmux_team_host::acl::{Acl, AclEntry, PathAcl, Perm, Tag};
use cmux_team_host::observed::DirState;
use cmux_team_host::{Accounts, Action, Directory, Layout, System, reconcile};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
struct Dir {
    uid: u32,
    gid: u32,
    mode: u32,
    group_obj: Perm,
    named: BTreeSet<AclEntry>,
    mask: Option<Perm>,
    default: Acl,
}

impl Dir {
    fn access(&self) -> Acl {
        let bits = |shift: u32| Perm(((self.mode >> shift) & 7) as u8);
        let mut v = vec![AclEntry::user_obj(bits(6)), AclEntry::other(bits(0))];
        match self.mask {
            Some(_) => v.extend([AclEntry::group_obj(self.group_obj), AclEntry::mask(bits(3))]),
            None => v.push(AclEntry::group_obj(bits(3))),
        }
        v.extend(self.named.iter().copied());
        Acl::new(v)
    }

    fn set_access(&mut self, acl: &Acl) {
        let mut mode = self.mode & 0o7000;
        self.named.clear();
        self.mask = None;
        for e in &acl.0 {
            match e.tag {
                Tag::UserObj => mode |= u32::from(e.perm.0) << 6,
                Tag::Other => mode |= u32::from(e.perm.0),
                Tag::GroupObj => self.group_obj = e.perm,
                Tag::Mask => self.mask = Some(e.perm),
                Tag::User(_) | Tag::Group(_) => {
                    self.named.insert(*e);
                }
            }
        }
        mode |= u32::from(self.mask.unwrap_or(self.group_obj).0) << 3;
        self.mode = mode;
    }
}

#[derive(Default)]
struct Fake {
    users: BTreeMap<String, (u32, u32, String, String)>,
    groups: BTreeMap<String, (u32, BTreeSet<String>)>,
    dirs: BTreeMap<PathBuf, Dir>,
    commands: usize,
}

fn spec(args: &[String]) -> Acl {
    let text = args[args.len() - 2].replace(',', "\n").replace("u:", "user:").replace("g:", "group:").replace("m:", "mask:").replace("o:", "other:");
    cmux_team_host::acl::parse_getfacl(&text).expect("spec parses").access
}

impl System for Fake {
    fn read_to_string(&mut self, path: &Path) -> io::Result<String> {
        Ok(if path.ends_with("passwd") {
            let mut s = String::from("root:x:0:0:root:/root:/bin/bash\n");
            for (n, (uid, gid, home, shell)) in &self.users {
                s += &format!("{n}:x:{uid}:{gid}::{home}:{shell}\n");
            }
            s
        } else {
            let mut s = String::from("root:x:0:\n");
            for (n, (gid, members)) in &self.groups {
                s += &format!("{n}:x:{gid}:{}\n", members.iter().cloned().collect::<Vec<_>>().join(","));
            }
            s
        })
    }

    fn dir_state(&mut self, path: &Path) -> io::Result<Option<DirState>> {
        Ok(self.dirs.get(path).map(|d| DirState { is_dir: true, uid: d.uid, gid: d.gid, mode: d.mode, acl: PathAcl { access: d.access(), default: d.default.clone() } }))
    }

    fn run(&mut self, program: &str, args: &[String]) -> Result<(), String> {
        self.commands += 1;
        let name = args.last().cloned().unwrap_or_default();
        let opt = |flag: &str| args.iter().position(|a| a == flag).map(|i| args[i + 1].clone());
        match program {
            "groupadd" => {
                self.groups.insert(name, (opt("-g").unwrap().parse().unwrap(), BTreeSet::new()));
            }
            "groupdel" => {
                if self.groups.remove(&name).is_none() {
                    return Err(format!("exit 6 from groupdel {name}"));
                }
            }
            "useradd" => {
                let uid = opt("-u").unwrap().parse().unwrap();
                if self.users.values().any(|u| u.0 == uid) || self.users.contains_key(&name) {
                    return Err(format!("exit 4 from useradd {name}"));
                }
                self.users.insert(name, (uid, opt("-g").unwrap().parse().unwrap(), opt("-d").unwrap(), opt("-s").unwrap()));
            }
            "userdel" => {
                self.users.remove(&name).ok_or("exit 6 from userdel")?;
                for g in self.groups.values_mut() {
                    g.1.remove(&name);
                }
            }
            "usermod" => {
                let u = self.users.get_mut(&name).ok_or("exit 6 from usermod")?;
                if let Some(gid) = opt("-g") {
                    u.1 = gid.parse().unwrap();
                    u.2 = opt("-d").unwrap();
                    u.3 = opt("-s").unwrap();
                }
                if let Some(list) = opt("-G") {
                    let want: BTreeSet<&str> = list.split(',').filter(|x| !x.is_empty()).collect();
                    for (g, (_, members)) in &mut self.groups {
                        if want.contains(g.as_str()) {
                            members.insert(name.clone());
                        } else {
                            members.remove(&name);
                        }
                    }
                }
            }
            "setfacl" => {
                assert_eq!(args[0], "-P", "setfacl must not follow symlinks");
                let d = self.dirs.get_mut(Path::new(&name)).ok_or("exit 1 from setfacl: no such file")?;
                if args.contains(&"-b".to_string()) {
                    d.named.clear();
                    d.mask = None;
                    d.default = Acl::default();
                    d.mode = (d.mode & !0o070) | (u32::from(d.group_obj.0) << 3);
                } else if args.contains(&"-d".to_string()) {
                    d.default = spec(args);
                } else {
                    let acl = spec(args);
                    d.set_access(&acl);
                }
            }
            other => panic!("unexpected program {other}"),
        }
        Ok(())
    }

    fn chown(&mut self, path: &Path, uid: u32, gid: u32) -> io::Result<()> {
        let d = self.dirs.get_mut(path).ok_or(io::ErrorKind::NotFound)?;
        (d.uid, d.gid) = (uid, gid);
        Ok(())
    }

    fn chmod(&mut self, path: &Path, mode: u32) -> io::Result<()> {
        let d = self.dirs.get_mut(path).ok_or(io::ErrorKind::NotFound)?;
        d.mode = mode;
        if d.mask.is_some() {
            d.mask = Some(Perm(((mode >> 3) & 7) as u8));
        } else {
            d.group_obj = Perm(((mode >> 3) & 7) as u8);
        }
        Ok(())
    }

    fn mkdir(&mut self, path: &Path) -> io::Result<()> {
        if self.dirs.contains_key(path) {
            return Err(io::ErrorKind::AlreadyExists.into());
        }
        let parent = path.parent().and_then(|p| self.dirs.get(p)).cloned();
        let mut d = Dir { uid: 0, gid: 0, mode: 0o755, group_obj: Perm::RX, named: BTreeSet::new(), mask: None, default: Acl::default() };
        if let Some(p) = parent {
            if p.mode & 0o2000 != 0 {
                d.gid = p.gid;
                d.mode |= 0o2000;
            }
            if !p.default.0.is_empty() {
                // A new directory takes its parent's default ACL as both its access and default ACL.
                d.set_access(&p.default);
                d.default = p.default.clone();
            }
        }
        self.dirs.insert(path.to_path_buf(), d);
        Ok(())
    }
}

/// POSIX.1e access check (owner, named users, groups under the mask, other).
fn access(f: &Fake, user: &str, path: &Path) -> String {
    let (uid, gid, ..) = f.users[user];
    let mut gids: BTreeSet<u32> = f.groups.values().filter(|(_, m)| m.contains(user)).map(|(g, _)| *g).collect();
    gids.insert(gid);
    let d = &f.dirs[path];
    let acl = d.access();
    let get = |t: Tag| acl.0.iter().find(|e| e.tag == t).map(|e| e.perm.0);
    let mask = get(Tag::Mask).unwrap_or(7);
    let p = if uid == d.uid {
        get(Tag::UserObj).unwrap_or(0)
    } else if let Some(p) = get(Tag::User(uid)) {
        p & mask
    } else {
        let mut matched = None::<u8>;
        if gids.contains(&d.gid) {
            matched = Some(get(Tag::GroupObj).unwrap_or(0));
        }
        for e in &acl.0 {
            if let Tag::Group(g) = e.tag {
                if gids.contains(&g) {
                    matched = Some(matched.unwrap_or(0) | e.perm.0);
                }
            }
        }
        matched.map_or(get(Tag::Other).unwrap_or(0), |m| m & mask)
    };
    Perm(p).text()
}

fn fresh() -> (Fake, Accounts, Layout) {
    let mut f = Fake::default();
    // The image: the root of the team tree's parent and the homes' parent exist.
    for p in ["/srv", "/home"] {
        f.dirs.insert(PathBuf::from(p), Dir { uid: 0, gid: 0, mode: 0o755, group_obj: Perm::RX, named: BTreeSet::new(), mask: None, default: Acl::default() });
    }
    (f, Accounts { passwd: "/etc/passwd".into(), group: "/etc/group".into() }, Layout::default())
}

#[test]
fn the_spec_example_gives_the_spec_access_matrix_and_a_second_run_is_a_no_op() {
    let (mut f, acc, layout) = fresh();
    let r = reconcile(&mut f, &acc, &layout, &common::acme());
    assert!(r.errors.is_empty(), "{:?}", r.errors);
    assert!(r.refusals.is_empty(), "{:?}", r.refusals);
    assert!(r.remaining.actions.is_empty(), "{:?}", r.remaining.actions);
    for (path, want) in common::MATRIX {
        for (user, w) in common::USERS.iter().zip(want) {
            assert_eq!(access(&f, user, &layout.root.join(path)), w, "{user} on {path}");
        }
    }
    // Groups: the closure, the mux in `muxes`, agents inherit their person's roles.
    let members = |g: &str| f.groups[g].1.clone();
    assert!(members("n-acme.web.checkout-w").contains("austin-agents"));
    assert!(!members("n-acme.web-w").contains("aziz"));
    assert!(members("muxes").contains("austin-mux") && !members("muxes").contains("austin"));
    assert!(!members("n-acme.person-austin-r").contains("lawrence"));
    // Mailbox and node modes.
    let mode = |p: &str| f.dirs[&layout.root.join(p)].mode;
    assert_eq!(mode("mailbox/inbox/aziz"), 0o1733);
    assert_eq!(mode("mailbox/inbox/all"), 0o1775);
    assert_eq!(mode("t/acme/p/web"), 0o2770);
    assert_eq!(f.dirs[&layout.root.join("t/acme/p/web")].default, f.dirs[&layout.root.join("t/acme/p/web")].access());
    assert_eq!(f.dirs[&layout.root.join("t/acme/p")].mode, 0o711);
    assert!(f.dirs[&layout.root.join("t/acme/p")].default.0.is_empty(), "a plain directory keeps no inherited default ACL");
    assert_eq!(f.users["austin-agents"].0, 20_006);

    let before = f.commands;
    let again = reconcile(&mut f, &acc, &layout, &common::acme());
    assert!(again.applied.is_empty(), "{:?}", again.applied);
    assert_eq!(f.commands, before, "a second run changes nothing");
}

#[test]
fn drift_is_reverted() {
    let (mut f, acc, layout) = fresh();
    reconcile(&mut f, &acc, &layout, &common::acme());
    // A manual group membership, a manual user in the managed range, a widened mode and ACL.
    f.groups.get_mut("n-acme-a").unwrap().1.insert("aziz".into());
    f.users.insert("intruder".into(), (20_400, 20_400, "/home/intruder".into(), "/bin/bash".into()));
    let web = layout.root.join("t/acme/p/web");
    f.dirs.get_mut(&web).unwrap().mode = 0o2777;
    f.dirs.get_mut(&web).unwrap().named.insert(AclEntry::group(20_008, Perm::RWX));
    let r = reconcile(&mut f, &acc, &layout, &common::acme());
    assert!(r.applied.contains(&Action::DeleteUser { name: "intruder".into() }));
    assert!(!f.groups["n-acme-a"].1.contains("aziz"));
    assert_eq!(access(&f, "aziz", &web), "r-x");
    assert_eq!(f.dirs[&web].mode, 0o2770);
    assert!(reconcile(&mut f, &acc, &layout, &common::acme()).applied.is_empty());
}

#[test]
fn a_member_name_that_a_system_account_has_is_refused_and_untouched() {
    let (mut f, acc, layout) = fresh();
    f.users.insert("aziz".into(), (998, 998, "/var/lib/aziz".into(), "/usr/sbin/nologin".into()));
    let r = reconcile(&mut f, &acc, &layout, &common::acme());
    assert!(r.refusals.iter().any(|x| x.subject == "user aziz" && x.reason.contains("system account")), "{:?}", r.refusals);
    assert_eq!(f.users["aziz"], (998, 998, "/var/lib/aziz".into(), "/usr/sbin/nologin".into()));
    assert!(!f.groups.contains_key("aziz"), "no private group for a refused name");
    assert!(!f.dirs.contains_key(&layout.root.join("mailbox/inbox/aziz")));
    // The rest of the team still converges, and aziz's mux and agents (their own names) exist.
    assert!(r.errors.is_empty(), "{:?}", r.errors);
    assert_eq!(access(&f, "austin", &layout.root.join("t/acme/p/web")), "rwx");
    assert!(f.users.contains_key("aziz-agents"));
}

#[test]
fn removing_a_member_removes_their_users_and_groups_and_keeps_their_files() {
    let (mut f, acc, layout) = fresh();
    reconcile(&mut f, &acc, &layout, &common::acme());
    let mut d: Directory = common::acme();
    d.members.retain(|m| m.name != "aziz");
    let r = reconcile(&mut f, &acc, &layout, &d);
    assert!(r.errors.is_empty(), "{:?}", r.errors);
    for u in ["aziz", "aziz-mux", "aziz-agents"] {
        assert!(!f.users.contains_key(u) && !f.groups.contains_key(u), "{u} removed");
    }
    assert!(f.dirs.contains_key(&layout.root.join("mailbox/inbox/aziz")), "files and directories are kept");
}

#[test]
fn invalid_directory_parts_are_refused_not_guessed() {
    let mut d = common::acme();
    d.nodes.push(cmux_team_host::directory::Node { id: "acme.ghost.child".into(), kind: cmux_team_host::directory::NodeKind::Project, gid: 200_012, person: None });
    d.nodes.push(cmux_team_host::directory::Node { id: "acme.dup".into(), kind: cmux_team_host::directory::NodeKind::Project, gid: 200_003, person: None });
    d.members.push(cmux_team_host::directory::Member { name: "Root".into(), uid: 20_012, roles: vec![], agent_roles: None });
    d.members.push(cmux_team_host::directory::Member { name: "eve".into(), uid: 20_001, roles: vec![], agent_roles: None });
    let (v, refusals) = cmux_team_host::validate(&d);
    let subjects: Vec<&str> = refusals.iter().map(|r| r.subject.as_str()).collect();
    for s in ["node acme.ghost.child", "node acme.dup", "member Root", "member eve"] {
        assert!(subjects.contains(&s), "{s} refused: {refusals:?}");
    }
    assert_eq!(v.members.len(), 3);
    assert_eq!(v.nodes.len(), 4);
}
