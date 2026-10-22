//! The ACL policy: Tailscale-shaped JSON, default deny.
//!
//! ```json
//! {
//!   "groups": { "group:eng": ["user:lawrence"] },
//!   "tagOwners": { "tag:fleet": ["group:eng"] },
//!   "acls": [ { "action": "accept", "src": ["group:eng"], "dst": ["tag:fleet:22,7319"] } ]
//! }
//! ```
//!
//! Selectors: `*`, `user:<id>`, `group:<name>`, `tag:<name>`, `node:<id>`.
//! A destination adds `:<ports>`: `*`, a port, a range `a-b`, or a comma
//! list of those. A tagged node is owned by its tags: `user:` and `group:`
//! selectors never match it.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::{Deserialize, Serialize};

const MAX_POLICY_BYTES: usize = 256 * 1024;
const MAX_RULES: usize = 1000;
const MAX_LIST: usize = 256;

/// An inclusive port range.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PortRange {
    pub first: u16,
    pub last: u16,
}

impl PortRange {
    pub const ALL: Self = Self { first: 1, last: 65535 };

    pub fn contains(&self, port: u16) -> bool {
        self.first <= port && port <= self.last
    }

    pub fn any_contains(ranges: &[Self], port: u16) -> bool {
        ranges.iter().any(|range| range.contains(port))
    }

    /// Sort and merge overlapping or adjacent ranges.
    pub fn normalize(ranges: &mut Vec<Self>) {
        ranges.sort();
        let mut merged: Vec<Self> = Vec::with_capacity(ranges.len());
        for range in ranges.drain(..) {
            match merged.last_mut() {
                Some(last) if u32::from(range.first) <= u32::from(last.last) + 1 => {
                    last.last = last.last.max(range.last);
                }
                _ => merged.push(range),
            }
        }
        *ranges = merged;
    }
}

/// What the policy needs to know about a node.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeIdentity {
    pub id: String,
    /// The owning user for an untagged node.
    pub user: Option<String>,
    /// Tags with their `tag:` prefix.
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyError(String);

impl fmt::Display for PolicyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for PolicyError {}

fn error(message: impl Into<String>) -> PolicyError {
    PolicyError(message.into())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PolicyFile {
    #[serde(default)]
    groups: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    tag_owners: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    acls: Vec<RuleFile>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RuleFile {
    action: String,
    src: Vec<String>,
    dst: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Selector {
    Any,
    User(String),
    Group(String),
    Tag(String),
    Node(String),
}

#[derive(Clone, Debug)]
struct Rule {
    src: Vec<Selector>,
    dst: Vec<(Selector, Vec<PortRange>)>,
}

/// A parsed and validated policy.
#[derive(Clone, Debug)]
pub struct Policy {
    /// Group name (with prefix) to user ids (without prefix).
    groups: BTreeMap<String, BTreeSet<String>>,
    /// Tag (with prefix) to owner selectors (`User` or `Group`).
    tag_owners: BTreeMap<String, Vec<Selector>>,
    rules: Vec<Rule>,
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._@-".contains(&byte))
}

fn check_len<T>(list: &[T], what: &str) -> Result<(), PolicyError> {
    if list.len() > MAX_LIST {
        return Err(error(format!("{what} has more than {MAX_LIST} entries")));
    }
    Ok(())
}

fn parse_port(text: &str) -> Result<u16, PolicyError> {
    match text.parse::<u16>() {
        Ok(0) | Err(_) => Err(error(format!("bad port `{text}` (1-65535)"))),
        Ok(port) => Ok(port),
    }
}

fn parse_ports(text: &str) -> Result<Vec<PortRange>, PolicyError> {
    if text == "*" {
        return Ok(vec![PortRange::ALL]);
    }
    let mut ranges = Vec::new();
    for part in text.split(',') {
        let range = match part.split_once('-') {
            Some((first, last)) => {
                let (first, last) = (parse_port(first)?, parse_port(last)?);
                if first > last {
                    return Err(error(format!("bad port range `{part}`")));
                }
                PortRange { first, last }
            }
            None => {
                let port = parse_port(part)?;
                PortRange { first: port, last: port }
            }
        };
        ranges.push(range);
    }
    PortRange::normalize(&mut ranges);
    Ok(ranges)
}

impl Policy {
    /// Parse and validate a policy. Every reference must resolve: groups
    /// used anywhere must be defined, tags must have a `tagOwners` entry.
    pub fn parse(text: &str) -> Result<Self, PolicyError> {
        if text.len() > MAX_POLICY_BYTES {
            return Err(error("policy is larger than 256 KiB"));
        }
        let file: PolicyFile =
            serde_json::from_str(text).map_err(|parse| error(format!("policy JSON: {parse}")))?;
        check_len(&file.acls, "acls")?;
        if file.acls.len() > MAX_RULES {
            return Err(error(format!("more than {MAX_RULES} acls")));
        }

        let mut groups = BTreeMap::new();
        check_len(&file.groups.keys().collect::<Vec<_>>(), "groups")?;
        for (name, members) in &file.groups {
            let bare = name
                .strip_prefix("group:")
                .ok_or_else(|| error(format!("group `{name}` must start with group:")))?;
            if !valid_name(bare) {
                return Err(error(format!("bad group name `{name}`")));
            }
            check_len(members, name)?;
            let mut users = BTreeSet::new();
            for member in members {
                let user = member
                    .strip_prefix("user:")
                    .filter(|user| valid_name(user))
                    .ok_or_else(|| error(format!("{name}: member `{member}` must be user:<id>")))?;
                users.insert(user.to_owned());
            }
            groups.insert(name.clone(), users);
        }

        let mut policy = Self { groups, tag_owners: BTreeMap::new(), rules: Vec::new() };
        check_len(&file.tag_owners.keys().collect::<Vec<_>>(), "tagOwners")?;
        for (tag, owners) in &file.tag_owners {
            let bare = tag
                .strip_prefix("tag:")
                .ok_or_else(|| error(format!("tag `{tag}` must start with tag:")))?;
            if !valid_name(bare) {
                return Err(error(format!("bad tag name `{tag}`")));
            }
            check_len(owners, tag)?;
            let mut parsed = Vec::new();
            for owner in owners {
                match policy.selector(owner)? {
                    selector @ (Selector::User(_) | Selector::Group(_)) => parsed.push(selector),
                    _ => {
                        return Err(error(format!(
                            "{tag}: owner `{owner}` must be a user or group"
                        )));
                    }
                }
            }
            policy.tag_owners.insert(tag.clone(), parsed);
        }

        for rule in &file.acls {
            if rule.action != "accept" {
                return Err(error(format!("action must be `accept`, got `{}`", rule.action)));
            }
            check_len(&rule.src, "src")?;
            check_len(&rule.dst, "dst")?;
            let src =
                rule.src.iter().map(|text| policy.selector(text)).collect::<Result<Vec<_>, _>>()?;
            let mut dst = Vec::new();
            for text in &rule.dst {
                let (selector, ports) = text
                    .rsplit_once(':')
                    .filter(|(selector, _)| *selector == "*" || selector.contains(':'))
                    .ok_or_else(|| error(format!("dst `{text}` needs a port list (`{text}:*`)")))?;
                dst.push((policy.selector(selector)?, parse_ports(ports)?));
            }
            policy.rules.push(Rule { src, dst });
        }
        Ok(policy)
    }

    fn selector(&self, text: &str) -> Result<Selector, PolicyError> {
        if text == "*" {
            return Ok(Selector::Any);
        }
        let (kind, name) =
            text.split_once(':').ok_or_else(|| error(format!("unknown selector `{text}`")))?;
        if !valid_name(name) {
            return Err(error(format!("bad name in selector `{text}`")));
        }
        match kind {
            "user" => Ok(Selector::User(name.to_owned())),
            "group" if self.groups.contains_key(text) => Ok(Selector::Group(text.to_owned())),
            "group" => Err(error(format!("undefined group `{text}`"))),
            "tag" if self.tag_owners.contains_key(text) => Ok(Selector::Tag(text.to_owned())),
            "tag" => Err(error(format!("tag `{text}` has no tagOwners entry"))),
            "node" => Ok(Selector::Node(name.to_owned())),
            _ => Err(error(format!("unknown selector `{text}`"))),
        }
    }

    fn matches(&self, selector: &Selector, node: &NodeIdentity) -> bool {
        let untagged_user = || if node.tags.is_empty() { node.user.as_deref() } else { None };
        match selector {
            Selector::Any => true,
            Selector::User(user) => untagged_user() == Some(user.as_str()),
            Selector::Group(group) => untagged_user().is_some_and(|user| {
                self.groups.get(group).is_some_and(|members| members.contains(user))
            }),
            Selector::Tag(tag) => node.tags.iter().any(|own| own == tag),
            Selector::Node(id) => node.id == *id,
        }
    }

    /// Ports on `target` that `source` may open, normalized; empty = none.
    pub fn allowed_ports(&self, source: &NodeIdentity, target: &NodeIdentity) -> Vec<PortRange> {
        if source.id == target.id {
            return Vec::new();
        }
        let mut ports = Vec::new();
        for rule in &self.rules {
            if !rule.src.iter().any(|selector| self.matches(selector, source)) {
                continue;
            }
            for (selector, rule_ports) in &rule.dst {
                if self.matches(selector, target) {
                    ports.extend_from_slice(rule_ports);
                }
            }
        }
        PortRange::normalize(&mut ports);
        ports
    }

    /// For each node that may open connections to `target`, the ports.
    pub fn inbound_for(
        &self,
        target: &NodeIdentity,
        nodes: &[NodeIdentity],
    ) -> BTreeMap<String, Vec<PortRange>> {
        nodes
            .iter()
            .filter_map(|source| {
                let ports = self.allowed_ports(source, target);
                (!ports.is_empty()).then(|| (source.id.clone(), ports))
            })
            .collect()
    }

    /// Nodes `target` needs a WireGuard session with: those it may reach and
    /// those that may reach it.
    pub fn peers_of(&self, target: &NodeIdentity, nodes: &[NodeIdentity]) -> BTreeSet<String> {
        nodes
            .iter()
            .filter(|other| {
                !self.allowed_ports(other, target).is_empty()
                    || !self.allowed_ports(target, other).is_empty()
            })
            .map(|other| other.id.clone())
            .collect()
    }

    pub fn has_tag(&self, tag: &str) -> bool {
        self.tag_owners.contains_key(tag)
    }

    /// Whether `user` may mint keys for (and so own devices with) `tag`.
    pub fn may_own_tag(&self, user: &str, tag: &str) -> bool {
        let Some(owners) = self.tag_owners.get(tag) else { return false };
        owners.iter().any(|owner| match owner {
            Selector::User(owner) => owner == user,
            Selector::Group(group) => {
                self.groups.get(group).is_some_and(|members| members.contains(user))
            }
            _ => false,
        })
    }
}
