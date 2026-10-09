//! Tree and agent refreshes racing with live title and agent events.

use super::*;

#[test]
fn agent_refresh_does_not_restore_an_update_for_a_removed_surface() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "screens": [{
                "id": 2,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "tabs": [{"surface": 4, "title": "agent terminal"}],
                }],
            }],
        }],
    }));
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree, 0);
    let retired = HashSet::new();
    let refresh_generation = cache.agent_generation();
    cache.update_agent(
        AgentInfo {
            surface: 4,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            agent: None,
            updated_at_ms: 41,
        },
        &retired,
    );

    let title_generation = cache.title_generation();
    cache.replace(TreeView::default(), title_generation);
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    assert!(cache.agents.is_empty());
}

#[test]
fn agent_refresh_does_not_resurrect_after_confirmed_omission() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "screens": [{
                "id": 2,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "tabs": [{"surface": 4, "title": "agent terminal"}],
                }],
            }],
        }],
    }));
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree.clone(), 0);
    let retired = HashSet::new();

    // The event races the first refresh and is retained while the
    // topology omits the surface.
    let refresh_generation = cache.agent_generation();
    cache.update_agent(
        AgentInfo {
            surface: 4,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            agent: None,
            updated_at_ms: 41,
        },
        &retired,
    );
    cache.replace(TreeView::default(), cache.title_generation());
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    // A later refresh confirms the agent is absent. A stale topology may
    // briefly show the surface again, but the old event must not return.
    let confirmed_generation = cache.agent_generation();
    cache.replace(tree, cache.title_generation());
    cache.replace_agents(Vec::new(), confirmed_generation, &retired);

    assert!(cache.agents.is_empty());
    assert!(cache.agent_updates.is_empty());
}

#[test]
fn agent_refresh_retains_updates_when_topology_temporarily_omits_surface() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "screens": [{
                "id": 2,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "tabs": [{"surface": 4, "title": "agent terminal"}],
                }],
            }],
        }],
    }));
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree.clone(), 0);
    let retired = HashSet::new();
    let refresh_generation = cache.agent_generation();
    let update = AgentInfo {
        surface: 4,
        state: "working".into(),
        source: "hook".into(),
        session: Some("review".into()),
        agent: None,
        updated_at_ms: 41,
    };
    cache.update_agent(update.clone(), &retired);

    // The tree response can lag the event stream and omit a live surface.
    cache.replace(TreeView::default(), cache.title_generation());
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    assert_eq!(cache.agent_updates.get(&4).map(|pending| &pending.agent), Some(&update));

    // A later topology response makes the pending event visible again.
    cache.replace(tree, cache.title_generation());
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    assert_eq!(cache.agents, vec![update]);
}
