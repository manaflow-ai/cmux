//! The ops of two sidebar edits planned on the document as the app shows
//! it (the app's `SidebarDocSubgroupPlan` and `SidebarDocHostGroupPlan`).
//!
//! - New Subgroup (remote-groups-DESIGN.md slice 3): one `group.create`
//!   inside a group, in its section. A group at the deepest level
//!   ([`MAX_GROUP_DEPTH`]) plans nothing and says why (`too_deep`), rather
//!   than an op the daemon refuses with `nesting`.
//! - A machine section as a remote group (slice 4): `section.update
//!   {host_group}` on its section, or `section.add` of that section, already
//!   a remote group, when the document has none yet. Unmarking leaves the
//!   section and its rows.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::json;

use super::doc::Doc;
use super::model::*;

/// One plan request (`{"plan": "subgroup" | "host_group", ...}`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "plan", rename_all = "snake_case")]
pub enum PlanRequest {
    /// A group `id` named `name` with `color` inside `parent` (a group item
    /// id, or an old personal group id). A blank `name` becomes
    /// [`DEFAULT_GROUP_NAME`]: the daemon refuses an empty one. The app sends
    /// its localized default itself.
    Subgroup {
        parent: String,
        id: ItemId,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
    },
    /// Mark (`on` true or absent) or unmark (`on` false) the remote group of
    /// daemon session `session`; `title` names a marked one's header.
    HostGroup {
        session: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        on: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
}

/// The name of a new group made without one (the app's `sidebar.group.newName`
/// default).
pub const DEFAULT_GROUP_NAME: &str = "New Group";

/// Why a plan has no ops.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanRefusal {
    /// `parent` is not a group of the document.
    UnknownGroup,
    /// `parent` is already at the deepest level a group may have.
    TooDeep,
}

/// The ops of `request` on `doc`; empty when there is nothing to change.
pub fn plan(doc: &Doc, request: &PlanRequest) -> Result<Vec<Op>, PlanRefusal> {
    match request {
        PlanRequest::Subgroup { parent, id, name, color } => {
            subgroup(doc, parent, id, name, color.as_deref()).map(|op| vec![op])
        }
        PlanRequest::HostGroup { session, on, title } => {
            Ok(host_group(doc, session, on.unwrap_or(true), title.as_deref()))
        }
    }
}

/// The group item of `id`: its personal group's item ([`group_item_id`]) or
/// the item itself.
fn group<'a>(doc: &'a Doc, id: &str) -> Option<&'a Item> {
    [group_item_id(id), id.to_string()]
        .iter()
        .find_map(|candidate| doc.item(candidate).filter(|item| item.body.is_group()))
}

fn subgroup(
    doc: &Doc,
    parent: &str,
    id: &str,
    name: &str,
    color: Option<&str>,
) -> Result<Op, PlanRefusal> {
    let group = group(doc, parent).ok_or(PlanRefusal::UnknownGroup)?;
    let mut level: usize = 1;
    let mut seen = HashSet::from([group.id.as_str()]);
    let mut above = group.parent.as_deref();
    while let Some(id) = above
        && seen.insert(id)
        && let Some(item) = doc.item(id)
    {
        level = level.saturating_add(1);
        above = item.parent.as_deref();
    }
    if level >= MAX_GROUP_DEPTH {
        return Err(PlanRefusal::TooDeep);
    }
    Ok(Op::GroupCreate {
        id: Some(id.to_string()),
        name: if name.trim().is_empty() { DEFAULT_GROUP_NAME } else { name }.to_string(),
        color: color.map(str::to_string),
        icon: None,
        profile: None,
        items: Vec::new(),
        to: Some(Target {
            section: group.section.clone(),
            parent: Some(group.id.clone()),
            ..Target::default()
        }),
    })
}

fn host_group(doc: &Doc, session: &str, on: bool, title: Option<&str>) -> Vec<Op> {
    let id = machine_section_id(session);
    let title = title.filter(|title| !title.is_empty());
    let section = doc.section(&id);
    if !on {
        return match section {
            Some(section) if section.host_group => vec![Op::SectionUpdate {
                id,
                patch: SectionPatch { host_group: Some(false), ..SectionPatch::default() },
            }],
            _ => Vec::new(),
        };
    }
    if let Some(section) = section {
        let patch = SectionPatch {
            host_group: (!section.host_group).then_some(true),
            title: title.map_or(Patch::Keep, |title| Patch::Set(title.to_string())),
            ..SectionPatch::default()
        };
        if patch.host_group.is_none() && patch.title.is_keep() {
            return Vec::new();
        }
        return vec![Op::SectionUpdate { id, patch }];
    }
    // The section the daemon would make for this machine, read as the wire
    // names it, already a remote group.
    let wire = json!({
        "id": id,
        "kind": {"type": "machine", "session_id": session},
        "host_group": true,
        "title": title,
    });
    match serde_json::from_value::<Section>(wire) {
        Ok(section) => vec![Op::SectionAdd { section, place: SectionPlace::default() }],
        Err(_) => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc_with(sections: Vec<Section>, items: Vec<Item>) -> Doc {
        Doc::from_parts(1, sections, items)
    }

    fn group_item(id: &str, parent: Option<&str>) -> Item {
        let mut item = Item::new(
            id,
            "sec_m_mini",
            Body::Group {
                name: id.into(),
                color: None,
                icon: None,
                collapsed: false,
                profile: None,
            },
        );
        item.parent = parent.map(str::to_string);
        item.order = "a".into();
        item
    }

    /// A chain of `levels` nested groups g1 > g2 > ... in machine mini's section.
    fn chain(levels: usize) -> Doc {
        let items = (1..=levels)
            .map(|level| {
                let parent = (level > 1).then(|| format!("g{}", level - 1));
                group_item(&format!("g{level}"), parent.as_deref())
            })
            .collect();
        doc_with(vec![Section::machine("mini")], items)
    }

    fn subgroup_request(parent: &str) -> PlanRequest {
        PlanRequest::Subgroup {
            parent: parent.into(),
            id: "g_new".into(),
            name: "feat-x".into(),
            color: Some("green".into()),
        }
    }

    #[test]
    fn a_subgroup_is_one_group_create_inside_its_parent() {
        let ops = plan(&chain(1), &subgroup_request("g1")).expect("planned");
        let value = serde_json::to_value(&ops).expect("serializes");
        assert_eq!(
            value,
            json!([{"op": "group.create", "id": "g_new", "name": "feat-x", "color": "green", "items": [],
                    "to": {"section": "sec_m_mini", "parent": "g1"}}])
        );
    }

    #[test]
    fn a_personal_group_id_names_its_item() {
        let doc =
            doc_with(vec![Section::machine("mini")], vec![group_item(&group_item_id("p"), None)]);
        let ops = plan(&doc, &subgroup_request("p")).expect("planned");
        let [Op::GroupCreate { to: Some(to), .. }] = ops.as_slice() else {
            panic!("one group.create")
        };
        assert_eq!(to.parent.as_deref(), Some(group_item_id("p").as_str()));
    }

    #[test]
    fn the_deepest_level_plans_nothing() {
        assert!(
            plan(
                &chain(MAX_GROUP_DEPTH - 1),
                &subgroup_request(&format!("g{}", MAX_GROUP_DEPTH - 1))
            )
            .is_ok()
        );
        assert_eq!(
            plan(&chain(MAX_GROUP_DEPTH), &subgroup_request(&format!("g{MAX_GROUP_DEPTH}"))),
            Err(PlanRefusal::TooDeep)
        );
        assert!(
            plan(&chain(6), &subgroup_request("g6")).is_ok(),
            "six levels is far from the limit"
        );
    }

    #[test]
    fn a_blank_name_becomes_the_default_name() {
        for blank in ["", "  ", "\n\t"] {
            let request = PlanRequest::Subgroup {
                parent: "g1".into(),
                id: "g2".into(),
                name: blank.into(),
                color: None,
            };
            let ops = plan(&chain(1), &request).unwrap_or_default();
            assert!(
                matches!(ops.as_slice(), [Op::GroupCreate { name, .. }] if name == DEFAULT_GROUP_NAME),
                "{blank:?}: {ops:?}"
            );
        }
    }

    #[test]
    fn an_unknown_parent_is_refused() {
        assert_eq!(plan(&chain(1), &subgroup_request("nope")), Err(PlanRefusal::UnknownGroup));
    }

    fn host(on: Option<bool>, title: Option<&str>) -> PlanRequest {
        PlanRequest::HostGroup { session: "mini".into(), on, title: title.map(str::to_string) }
    }

    fn machine(host_group: bool) -> Doc {
        let mut section = Section::machine("mini");
        section.host_group = host_group;
        doc_with(vec![section], vec![])
    }

    #[test]
    fn unmarking_patches_only_a_remote_group() {
        let ops = plan(&machine(true), &host(Some(false), None)).expect("planned");
        assert_eq!(
            serde_json::to_value(&ops).expect("serializes"),
            json!([{"op": "section.update", "id": "sec_m_mini", "patch": {"host_group": false}}])
        );
        assert!(plan(&machine(false), &host(Some(false), None)).expect("planned").is_empty());
        assert!(
            plan(&doc_with(vec![], vec![]), &host(Some(false), None)).expect("planned").is_empty()
        );
    }

    #[test]
    fn marking_adds_the_section_when_the_document_has_none() {
        let ops =
            plan(&doc_with(vec![], vec![]), &host(None, Some("Build Mini"))).expect("planned");
        let [Op::SectionAdd { section, .. }] = ops.as_slice() else { panic!("one section.add") };
        assert_eq!(section.id, "sec_m_mini");
        assert!(section.host_group);
        assert_eq!(section.title.as_deref(), Some("Build Mini"));
        assert_eq!(section.kind, SectionKind::Machine { session_id: "mini".into() });
    }

    #[test]
    fn marking_patches_what_differs() {
        let ops = plan(&machine(false), &host(None, None)).expect("planned");
        assert_eq!(
            serde_json::to_value(&ops).expect("serializes"),
            json!([{"op": "section.update", "id": "sec_m_mini", "patch": {"host_group": true}}])
        );
        let ops = plan(&machine(true), &host(None, Some("Build Mini"))).expect("planned");
        assert_eq!(
            serde_json::to_value(&ops).expect("serializes"),
            json!([{"op": "section.update", "id": "sec_m_mini", "patch": {"title": "Build Mini"}}]),
            "a remote group that exists is only renamed"
        );
        assert!(plan(&machine(true), &host(None, None)).expect("planned").is_empty());
        assert!(
            plan(&machine(true), &host(None, Some(""))).expect("planned").is_empty(),
            "an empty title keeps the host's name"
        );
    }
}
