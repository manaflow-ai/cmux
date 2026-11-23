//! This server's own tools, in the order `tools/list` gives them, before the app's actions and
//! the proxied servers' tools (`Server::listed`).

use serde_json::Value;

use super::{
    action_tools, agent_dispatch_tools, agent_events_tool, agent_tools, agent_wait_tool,
    automation_tools, browser_tools, chat_tools, cloud_connect_tools, cloud_repo_tools,
    customize_library_tool, customize_tools, device_tools, keybinding_tools, keys_tools,
    live_code_tools, open_tool, remote_tools, render_tool, settings_tools, terminal_talk_tools,
    v2_tools, video_tools, workflow_tools,
};

pub(super) fn first_party() -> Vec<Value> {
    let mut tools =
        v2_tools::tools().iter().map(v2_tools::V2Tool::descriptor_json).collect::<Vec<_>>();
    tools.extend(browser_tools::tools().iter().map(browser_tools::BrowserTool::descriptor_json));
    tools.push(action_tools::window_list_tool());
    tools.push(super::super::agents::snapshot_tool());
    tools.extend(agent_tools::TOOLS.iter().map(agent_tools::AgentTool::descriptor_json));
    tools.extend(agent_dispatch_tools::descriptors());
    tools.push(workflow_tools::descriptor());
    tools.extend(cloud_repo_tools::descriptors());
    tools.extend(cloud_connect_tools::descriptors());
    tools.extend(chat_tools::descriptors());
    tools.extend(live_code_tools::descriptors());
    tools.push(super::super::agents_doctor::mcp_tool());
    tools.push(agent_wait_tool::descriptor());
    tools.push(agent_events_tool::descriptor());
    tools.extend(terminal_talk_tools::descriptors());
    tools.push(render_tool::descriptor());
    tools.push(open_tool::descriptor());
    tools.extend(keys_tools::descriptors());
    tools.extend(video_tools::descriptors());
    tools.extend(remote_tools::TOOLS.iter().map(remote_tools::RemoteTool::descriptor_json));
    tools.extend(device_tools::descriptors());
    tools.extend(settings_tools::TOOLS.iter().map(settings_tools::SettingTool::descriptor_json));
    tools.extend(automation_tools::descriptors());
    tools.extend(customize_tools::descriptors());
    tools.push(customize_library_tool::descriptor());
    tools.extend(
        keybinding_tools::TOOLS.iter().map(keybinding_tools::KeybindingTool::descriptor_json),
    );
    tools
}
