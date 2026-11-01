//! The `Command` router: one arm per command, each calling its family's handler
//! (`cmd_*` modules). Moved out of server.rs unchanged (cx-6so.3).

use super::*;

pub(super) fn handle_command_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
    cancellation: Option<&ConnectionCancellation>,
) -> anyhow::Result<Value> {
    // A move out of an incognito workspace can make another incognito
    // workspace; its app owns it (incognito_orphans). Every move command
    // takes part, so none commits outside the serialized moves.
    let moves = matches!(
        cmd,
        Command::MoveTabToNewWorkspace { .. }
            | Command::MoveTabGroupToNewWorkspace { .. }
            | Command::MoveScreen { .. }
            | Command::MoveScreenGroup { .. }
            | Command::MoveTabToWorkspace { .. }
            | Command::MoveTab { .. }
            | Command::MoveTabToSplit { .. }
            | Command::MoveTabGroup { .. }
            | Command::MoveTabGroupToSplit { .. }
            | Command::MoveTabGroupToColumn { .. }
            | Command::MoveTerminal { .. }
    );
    let claim = if moves { incognito_orphans::begin_move(mux, false) } else { None };
    let result = dispatch_command(mux, client, cmd, writer, cancellation);
    if let Some(claim) = claim
        && result.is_ok()
    {
        claim.finish(mux, client);
    }
    result
}

fn dispatch_command(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
    cancellation: Option<&ConnectionCancellation>,
) -> anyhow::Result<Value> {
    // Who a durable legacy command acts as (P8): read once per command.
    let actor = origin_gate::connection_actor(mux, client);
    if let Some(remote) = remote_relay::intercept(mux, client, &cmd, writer) {
        return remote;
    }
    match cmd {
        Command::SubscribeActivity => cmd_subscribe::subscribe_activity(mux, client, writer),
        cmd @ (Command::UrlOpenSubscribe { .. }
        | Command::UrlOpenClaim { .. }
        | Command::UrlOpenResult { .. }) => url_open::handle(mux, client, cmd, writer),
        cmd @ (Command::TerminalClipboardSubscribe { .. }
        | Command::TerminalClipboardReply { .. }) => {
            clipboard_read::handle(mux, client, cmd, writer)
        }
        Command::UrlOpen { .. } => {
            anyhow::bail!("URL opening requires the asynchronous request path")
        }
        Command::ChiefInspect(_) => {
            anyhow::bail!("chief-inspect requires the asynchronous request path")
        }
        Command::PasteImage {
            surface,
            terminal_id,
            lease,
            upload_id,
            op,
            mime,
            size,
            offset,
            data,
        } => cmd_terminal_io::paste_image(
            mux,
            client,
            surface,
            terminal_id,
            lease,
            upload_id,
            op,
            mime,
            size,
            offset,
            data,
        ),
        command @ (Command::SetTerminalCommandHistory(_)
        | Command::ListTerminalCommands(_)
        | Command::DeleteTerminalCommands(_)) => command_history::handle(mux, client, command),
        Command::ServerStats { include } => cmd_server::server_stats(mux, client, include),
        Command::BrowserHostProvider => cmd_browser::browser_host_provider(mux, client),
        Command::Identify { machine_metadata, revisions } => {
            cmd_server::identify(mux, machine_metadata, revisions)
        }
        Command::ShutdownDaemon { pid, generation, force, end_terminals, keep_layout } => {
            cmd_server::shutdown_daemon(
                mux,
                client,
                pid,
                generation,
                force,
                end_terminals,
                keep_layout,
            )
        }
        Command::Ping => cmd_server::ping(),
        Command::SetClientInfo {
            name,
            kind,
            capabilities,
            user_id,
            display_name,
            device_kind,
            device_name,
            device_id,
            api_revision,
            version,
            install,
            remote,
        } => cmd_server::set_client_info(
            mux,
            client,
            name,
            kind,
            capabilities,
            user_id,
            display_name,
            device_kind,
            device_name,
            device_id,
            api_revision,
            version,
            install,
            remote.unwrap_or(false),
        ),
        Command::ListClients => cmd_server::list_clients(mux, client),
        Command::MachineUsage => cmd_server::machine_usage(mux),
        Command::MachineListeningTcp => cmd_server::machine_listening_tcp(),
        Command::RegisterBrowserProvider {
            provider_id,
            endpoint,
            authentication,
            bearer_token,
            hosting,
            targets,
        } => cmd_browser::register_browser_provider(
            mux,
            client,
            cmd_browser::BrowserProviderRequest {
                provider_id,
                endpoint,
                authentication,
                bearer_token,
                hosting,
                targets,
            },
        ),
        Command::GetBrowserProvider => cmd_browser::get_browser_provider(mux, client),
        Command::UnregisterBrowserProvider => cmd_browser::unregister_browser_provider(mux, client),
        Command::ListTerminals => cmd_terminals::list_terminals(mux),
        Command::TerminalEvents { after_revision } => {
            cmd_terminals::terminal_events(mux, after_revision)
        }
        Command::SetClientSizing { surface, client: target, enabled, exclusive } => {
            cmd_sizing::set_client_sizing(mux, client, surface, target, enabled, exclusive)
        }
        Command::PairingResponse { request, approve } => {
            cmd_server::pairing_response(mux, client, request, approve)
        }
        Command::DetachClient { client: target, by, surface } => {
            cmd_attach::detach_client(mux, client, target, by, surface)
        }
        Command::SetSizePolicy { surface, workspace, policy } => {
            cmd_sizing::set_size_policy(mux, client, surface, workspace, policy)
        }
        Command::SetSizeCounts { surface, client: target, lease, view, participant, counts } => {
            cmd_sizing::set_size_counts(
                mux,
                client,
                surface,
                target,
                lease,
                view,
                participant,
                counts,
            )
        }
        Command::NoteSizeActivity { surface, view } => {
            cmd_sizing::note_size_activity(mux, client, surface, view)
        }
        Command::ReattachView { surface, counts } => {
            cmd_attach::reattach_view(mux, client, surface, counts)
        }
        Command::GetSizeState { surface } => cmd_sizing::get_size_state(mux, client, surface),
        Command::GetHostSizePolicy { surface } => cmd_sizing::get_host_size_policy(mux, surface),
        Command::SetHostSizePolicy { policy } => {
            cmd_sizing::set_host_size_policy(mux, client, policy.mode, policy.order)
        }
        Command::ReloadConfig => cmd_server::reload_config(mux),
        Command::SetWindowTitle { title } => cmd_server::set_window_title(mux, title),
        Command::ClearWindowTitle => cmd_server::clear_window_title(mux),
        Command::ListWorkspaces => cmd_workspaces::list_workspaces(mux),
        Command::GetFrontendProjection { frontend, scope, subject_key } => {
            cmd_frontend::get_frontend_projection(mux, frontend, scope, subject_key)
        }
        Command::PutFrontendProjection {
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
            mutation,
        } => cmd_frontend::put_frontend_projection(
            mux,
            client,
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
            mutation,
        ),
        Command::JournalFrontendEvent { event } => {
            cmd_frontend::journal_frontend_event(mux, client, event)
        }
        Command::ExportLayout { screen } => cmd_panes::export_layout(mux, screen),
        Command::ApplyLayout { workspace, name, layout, cols, rows } => {
            cmd_panes::apply_layout(mux, actor, workspace, name, layout, cols, rows)
        }
        Command::Send(params) => cmd_terminal_io::send(mux, client, writer, params),
        Command::ReadScreen { surface } => cmd_terminal_io::read_screen(mux, surface),
        Command::ClearHistory { surface, fallback_key } => {
            cmd_terminal_io::clear_history(mux, surface, fallback_key)
        }
        Command::ReadScrollback { surface, start, count } => {
            cmd_terminal_io::read_scrollback(mux, surface, start, count)
        }
        Command::SidebarPlugin { cols, rows, relaunch } => {
            cmd_frontend::sidebar_plugin(mux, cols, rows, relaunch)
        }
        Command::WaitFor { surface, pattern, timeout_ms } => {
            cmd_terminal_io::wait_for(mux, writer, cancellation, surface, pattern, timeout_ms)
        }
        Command::Run { argv, command, cwd, pane, new_workspace, key, name, cols, rows } => {
            cmd_terminal_io::run(
                mux,
                actor,
                argv,
                command,
                cwd,
                pane,
                new_workspace,
                key,
                name,
                cols,
                rows,
            )
        }
        Command::CreateSurfaceWithReceipt(request) => {
            cmd_frontend::create_surface_with_receipt_command(mux, client, request)
        }
        Command::SendKey { surface, keys } => cmd_terminal_io::send_key(mux, client, surface, keys),
        Command::Copy { surface, mode } => cmd_terminal_io::copy(mux, surface, mode),
        Command::Ids { kind } => cmd_frontend::ids(mux, kind),
        Command::Notify { title, body, level, surface, source } => {
            cmd_frontend::notify(mux, actor, title, body, level, surface, source)
        }
        Command::ListAgents { surface, state } => cmd_frontend::list_agents(mux, surface, state),
        Command::ReportAgent { surface, state, source, session } => {
            cmd_frontend::report_agent(mux, surface, state, source, session)
        }
        Command::VtState { .. } => {
            anyhow::bail!("vt-state is served by its streaming response path")
        }
        Command::MintTerminalRenderer { surface, ttl_ms } => {
            cmd_terminals::mint_terminal_renderer(mux, client, surface, ttl_ms)
        }
        Command::MintTerminalRendererByTerminal { terminal, ttl_ms } => {
            cmd_terminals::mint_terminal_renderer_by_terminal(mux, client, terminal, ttl_ms)
        }
        Command::ResolveTerminal { terminal_id } => {
            cmd_terminals::resolve_terminal(mux, terminal_id)
        }
        Command::CloseTerminal { terminal_id, terminal_incarnation, mutation } => {
            cmd_terminals::close_terminal(mux, client, terminal_id, terminal_incarnation, mutation)
        }
        Command::SetTerminalIdlePolicy { surface, terminal_id, idle_close_seconds } => {
            cmd_terminals::set_terminal_idle_policy(mux, surface, terminal_id, idle_close_seconds)
        }
        Command::SetTerminalKeep { surface, terminal_id, keep } => {
            cmd_terminals::set_terminal_keep(mux, surface, terminal_id, keep)
        }
        Command::TerminalResumeCommand { surface, terminal_id, command } => {
            cmd_terminals::terminal_resume_command(mux, surface, terminal_id, command)
        }
        Command::NewTab { pane, cwd, env, cols, rows, keep, terminal_id, shell_args } => {
            cmd_tabs::new_tab(
                mux,
                client,
                actor,
                pane,
                cwd,
                env,
                cols,
                rows,
                keep,
                terminal_id,
                shell_args,
            )
        }
        Command::NewConversationTab(params) => cmd_tabs::new_conversation_tab(mux, client, params),
        Command::BindConversationTabSession(params) => {
            cmd_tabs::bind_conversation_tab_session(mux, actor, params)
        }
        Command::RestartTab(params) => tab_restart::restart(mux, params),
        Command::ParkTabs(params) => tab_park::park(mux, params),
        Command::NewFrontendBrowserTab(params) => {
            cmd_tabs::new_frontend_browser_tab(mux, client, params)
        }
        Command::UpdateFrontendBrowserTab(params) => {
            cmd_tabs::update_frontend_browser_tab(mux, actor, params)
        }
        Command::SetFrontendBrowserHistory(params) => frontend_browser_history::set(mux, params),
        Command::GetFrontendBrowserHistory(params) => frontend_browser_history::get(mux, params),
        Command::NewRemoteTerminalTab(p) => remote_terminal_tabs_wire::create(mux, &actor, p),
        Command::UpdateRemoteTerminalTab(p) => remote_terminal_tabs_wire::update(mux, p),
        Command::RemoteTerminalSnapshot(p) => remote_terminal_tabs_wire::snapshot(mux, p),
        Command::NewBrowserTab { url, pane, cols, rows } => {
            cmd_tabs::new_browser_tab(mux, actor, url, pane, cols, rows)
        }
        Command::GetCellPixels => cmd_sizing::get_cell_pixels(mux),
        Command::SetCellPixels { width_px, height_px } => {
            cmd_sizing::set_cell_pixels(mux, width_px, height_px)
        }
        Command::BrowserFramePresented { surface, frame_seq } => {
            cmd_browser::browser_frame_presented(mux, client, surface, frame_seq)
        }
        cmd @ (Command::BrowserMouse { .. }
        | Command::BrowserMouseGuarded { .. }
        | Command::BrowserWheel { .. }
        | Command::BrowserWheelGuarded { .. }
        | Command::BrowserKey { .. }
        | Command::BrowserKeyPress { .. }
        | Command::BrowserInsertText { .. }) => browser_input::handle(mux, client, cmd),
        Command::BrowserNavigate { surface, url } => {
            cmd_browser::browser_navigate(mux, surface, url)
        }
        Command::BrowserBack { surface } => cmd_browser::browser_back(mux, surface),
        Command::BrowserForward { surface } => cmd_browser::browser_forward(mux, surface),
        Command::BrowserReload { surface } => cmd_browser::browser_reload(mux, surface),
        Command::BrowserActivate { surface } => cmd_browser::browser_activate(mux, surface),
        Command::NewWorkspace { name, cols, rows } => {
            cmd_workspaces::new_workspace(mux, actor, name, cols, rows)
        }
        Command::CreateWorkspace { name, key, mutation } => {
            cmd_workspaces::create_workspace(mux, client, name, key, mutation)
        }
        Command::CreateTerminal {
            workspace,
            key,
            argv,
            shell_args,
            command,
            cwd,
            name,
            cols,
            rows,
            terminal_id,
            env,
            keep,
            detached,
            mutation,
        } => cmd_terminals::create_terminal(
            mux,
            client,
            actor,
            workspace,
            key,
            argv,
            shell_args,
            command,
            cwd,
            name,
            cols,
            rows,
            terminal_id,
            env,
            keep,
            detached,
            mutation,
        ),
        Command::NewScreen(params) => cmd_screens::new_screen(mux, client, params),
        Command::SetScreenMetadata { screen, color, icon } => {
            cmd_screens::set_screen_metadata(mux, actor, screen, color, icon)
        }
        Command::SetScreenPinned { screen, pinned } => {
            cmd_screens::set_screen_pinned(mux, actor, screen, pinned)
        }
        Command::MoveScreen { screen, index, workspace, new_workspace } => {
            cmd_screens::move_screen(mux, actor, screen, index, workspace, new_workspace)
        }
        Command::CreateScreenGroup { screens, name, color } => {
            cmd_screens::create_screen_group(mux, actor, screens, name, color)
        }
        Command::UpdateScreenGroup { group, name, color, collapsed, icon } => {
            cmd_screens::update_screen_group(mux, actor, group, name, color, collapsed, icon)
        }
        Command::AddScreensToScreenGroup { group, screens, index } => {
            cmd_screens::add_screens_to_screen_group(mux, actor, group, screens, index)
        }
        Command::RemoveScreensFromScreenGroup { screens } => {
            cmd_screens::remove_screens_from_screen_group(mux, actor, screens)
        }
        Command::MoveScreenGroup { group, index, workspace, new_workspace } => {
            cmd_screens::move_screen_group(mux, actor, group, index, workspace, new_workspace)
        }
        Command::UngroupScreenGroup { group } => {
            cmd_screens::ungroup_screen_group(mux, actor, group)
        }
        Command::CloseScreenGroup { group, end_terminals } => {
            cmd_screens::close_screen_group(mux, actor, group, end_terminals)
        }
        Command::ListSavedScreenGroups => cmd_screens::list_saved_screen_groups(mux),
        Command::SaveScreenGroup { group } => cmd_screens::save_screen_group(mux, actor, group),
        Command::UnsaveScreenGroup { group } => cmd_screens::unsave_screen_group(mux, group),
        Command::DeleteSavedScreenGroup { saved } => {
            cmd_screens::delete_saved_screen_group(mux, saved)
        }
        Command::ReopenSavedScreenGroup { saved, workspace } => {
            cmd_screens::reopen_saved_screen_group(mux, actor, saved, workspace)
        }
        command @ Command::NewPane { .. } => cmd_panes::new_pane(mux, client, actor, command),
        Command::NewPaneRight(params) => cmd_panes::new_pane_right(mux, client, params),
        Command::Split(params) => cmd_panes::split(mux, client, params),
        Command::SetRatio { pane, dir, ratio } => {
            cmd_panes::set_ratio(mux, actor, pane, dir, ratio)
        }
        Command::SetSplitRatio { split, ratio, transaction } => {
            cmd_panes::set_split_ratio(mux, client, actor, split, ratio, transaction)
        }
        Command::SetViewportPaneWidth { pane, width, transaction } => {
            cmd_panes::set_viewport_pane_width(mux, client, actor, pane, width, transaction)
        }
        Command::SetColumnDock { pane, dock, edge, mode, role, permanent, pinned, transaction } => {
            cmd_panes::set_column_dock(
                mux,
                client,
                actor,
                pane,
                dock,
                edge,
                mode,
                role,
                permanent,
                pinned,
                transaction,
            )
        }
        Command::UndoLayout { pane, revision, confirm_close } => {
            cmd_panes::undo_layout(mux, actor, pane, revision, confirm_close)
        }
        Command::PaneNeighbor { pane, dir } => cmd_panes::pane_neighbor(mux, pane, dir),
        Command::FocusDirection { pane, dir } => cmd_panes::focus_direction(mux, actor, pane, dir),
        Command::SwapPane { pane, dir, target } => {
            cmd_panes::swap_pane(mux, actor, pane, dir, target)
        }
        Command::ZoomPane { pane, mode } => cmd_panes::zoom_pane(mux, actor, pane, mode),
        Command::ProcessInfo { surface } => cmd_terminals::process_info(mux, surface),
        Command::TerminalPorts { surface } => terminal_ports::terminal_ports(mux, surface),
        Command::TerminalResources { surfaces } => cmd_terminals::terminal_resources(mux, surfaces),
        Command::MoveTerminal { terminal_id, workspace_key, terminal_incarnation, mutation } => {
            cmd_terminals::move_terminal(
                mux,
                client,
                terminal_id,
                workspace_key,
                terminal_incarnation,
                mutation,
            )
        }
        Command::MoveTabToWorkspace { surface, workspace, transaction } => {
            cmd_tabs::move_tab_to_workspace(mux, actor, surface, workspace, transaction)
        }
        Command::MoveTabToSplit {
            surface,
            pane,
            edge,
            ratio,
            respawn,
            keep_focus,
            transaction,
        } => cmd_tabs::move_tab_to_split(
            mux,
            client,
            surface,
            pane,
            edge,
            ratio,
            respawn,
            keep_focus,
            transaction,
        ),
        Command::MoveTabToColumn(params) => cmd_tabs::move_tab_to_column(mux, client, params),
        Command::NewRow(params) => cmd_panes::new_row(mux, client, params),
        Command::SetRowHeights(params) => cmd_panes::set_row_heights(mux, client, params),
        Command::MoveColumn(params) => column_move::move_column(mux, client, params),
        Command::MoveTabToNewWorkspace { surface, group, index, name, transaction } => {
            cmd_tabs::move_tab_to_new_workspace(
                mux,
                actor,
                surface,
                group,
                index,
                name,
                transaction,
            )
        }
        Command::MoveTab { surface, pane, index, transaction } => {
            cmd_tabs::move_tab(mux, actor, surface, pane, index, transaction)
        }
        Command::ListTabGroups => cmd_tabs::list_tab_groups(mux),
        Command::CreateTabGroup { surfaces, name, color, group, transaction } => {
            cmd_tabs::create_tab_group(mux, actor, surfaces, name, color, group, transaction)
        }
        Command::UpdateTabGroup { group, name, color, collapsed, icon } => {
            cmd_tabs::update_tab_group(mux, actor, group, name, color, collapsed, icon)
        }
        Command::AddTabsToTabGroup { group, surfaces, transaction } => {
            cmd_tabs::add_tabs_to_tab_group(mux, actor, group, surfaces, transaction)
        }
        Command::RemoveTabsFromTabGroup { surfaces, transaction } => {
            cmd_tabs::remove_tabs_from_tab_group(mux, actor, surfaces, transaction)
        }
        Command::MoveTabGroup { group, pane, index, transaction } => {
            cmd_tabs::move_tab_group(mux, actor, group, pane, index, transaction)
        }
        Command::MoveTabGroupToSplit { group, pane, edge, ratio, transaction } => {
            cmd_tabs::move_tab_group_to_split(mux, actor, group, pane, edge, ratio, transaction)
        }
        Command::MoveTabGroupToColumn { group, pane, screen, after_column, width, transaction } => {
            cmd_tabs::move_tab_group_to_column(
                mux,
                actor,
                group,
                pane,
                screen,
                after_column,
                width,
                transaction,
            )
        }
        Command::MoveTabGroupToNewWorkspace { group, workspace_group, index, transaction } => {
            cmd_tabs::move_tab_group_to_new_workspace(
                mux,
                actor,
                group,
                workspace_group,
                index,
                transaction,
            )
        }
        Command::UngroupTabGroup { group } => cmd_tabs::ungroup_tab_group(mux, actor, group),
        Command::CloseTabGroup { group, end_terminals } => {
            cmd_tabs::close_tab_group(mux, actor, group, end_terminals)
        }
        Command::ListSavedTabGroups => cmd_tabs::list_saved_tab_groups(mux),
        Command::SaveTabGroup { group } => cmd_tabs::save_tab_group(mux, actor, group),
        Command::UnsaveTabGroup { group } => cmd_tabs::unsave_tab_group(mux, actor, group),
        Command::DeleteSavedTabGroup { saved } => {
            cmd_tabs::delete_saved_tab_group(mux, actor, saved)
        }
        Command::ReopenSavedTabGroup { saved, pane, transaction } => {
            cmd_tabs::reopen_saved_tab_group(mux, actor, saved, pane, transaction)
        }
        Command::AckTabNotifications { surface } => cmd_tabs::ack_tab_notifications(mux, surface),
        Command::ListNotifications { limit } => cmd_frontend::list_notifications(mux, limit),
        Command::SetTabPinned { surface, pinned } => {
            cmd_tabs::set_tab_pinned(mux, actor, surface, pinned)
        }
        Command::MoveWorkspace { workspace, key, index, mutation } => {
            cmd_workspaces::move_workspace(mux, client, workspace, key, index, mutation)
        }
        Command::SetWorkspaceMetadata {
            workspace,
            key,
            color,
            icon,
            title,
            pinned,
            marked_unread,
            mutation,
        } => cmd_workspaces::set_workspace_metadata(
            mux,
            client,
            workspace,
            key,
            color,
            icon,
            title,
            pinned,
            marked_unread,
            mutation,
        ),
        Command::ListPersonal => cmd_profiles::list_personal(mux),
        Command::CreateBrowserProfile(params) => browser_profiles::create(mux, params),
        Command::UpdateBrowserProfile(params) => browser_profiles::update(mux, params),
        Command::MoveBrowserProfile(params) => browser_profiles::move_to(mux, params),
        Command::DeleteBrowserProfile(params) => browser_profiles::delete(mux, client, params),
        Command::ListBookmarks(params) => bookmarks::list(mux, params),
        Command::CreateBookmark(params) => bookmarks::create(mux, &actor, params),
        Command::UpdateBookmark(params) => bookmarks::update(mux, &actor, params),
        Command::MoveBookmark(params) => bookmarks::move_to(mux, &actor, params),
        Command::DeleteBookmark(params) => bookmarks::delete(mux, &actor, params),
        Command::ImportBookmarks(params) => bookmarks::import(mux, &actor, params),
        cmd @ (Command::FeedLocalList(_)
        | Command::FeedLocalRead(_)
        | Command::FeedLocalHandoffBegin(_)
        | Command::FeedLocalHandoffAbort(_)
        | Command::FeedLocalHandoffDone(_)) => feed_local::dispatch(mux, &actor, cmd),
        Command::PutBlob(params) => icon_assets::put(mux, params),
        Command::GetBlob(params) => icon_assets::get(mux, params),
        Command::ConversationList => conversations::list(mux, client),
        Command::ConversationCreate(params) => conversations::create(mux, client, params),
        Command::ConversationSnapshot(params) => conversations::snapshot(mux, client, params),
        Command::ConversationHistory(params) => conversations::history(mux, client, params),
        Command::ConversationThread(params) => conversations::thread(mux, client, params),
        Command::ConversationLinkResolve(params) => {
            conversations::link_resolve(mux, client, params)
        }
        Command::ConversationInboxOp(params) => conversations::inbox_op(mux, client, params),
        Command::HomeInbox(params) => conversations::home_inbox(mux, client, params),
        Command::ConversationSearch(params) => conversations::search(mux, client, params),
        Command::HistorySearch(params) => history_search::search(mux, client, params),
        Command::ConversationOp(params) => conversations::op(mux, client, params),
        Command::ConversationTyping(params) => conversations::typing(mux, client, params),
        Command::ConversationDraft(params) => conversations::draft(mux, client, params),
        Command::ConversationBind(params) => conversations::bind(mux, client, params),
        Command::ConversationAgentToken(params) => conversations::agent_token(mux, client, params),
        Command::CloudSessionSet(params) => cloud_conversations::session_set(mux, client, params),
        Command::CloudSessionClear => cloud_conversations::session_clear(mux, client),
        Command::CloudSessionStatus => cloud_conversations::session_status(mux, client),
        Command::CloudHostReplicaSet(params) => cloud_host_replica::set(mux, client, params),
        Command::CloudHostReplicaClear(params) => cloud_host_replica::clear(mux, client, params),
        Command::CloudHostReplicaStatus => cloud_host_replica::status(mux, client),
        Command::PageCredential(params) => page_credential::page_credential(mux, client, params),
        Command::WsListen(params) => page_listener::ws_listen(mux, client, params),
        Command::CloudInboxList(params) => cloud_conversations::inbox_list(mux, client, params),
        Command::CloudRequestsList(_) => cloud_conversations::requests_list(mux, client),
        Command::CloudSelfhostInfo(_) => cloud_conversations::selfhost_info(mux, client),
        Command::CloudEnvironment(params) => cloud_conversations::environment(mux, client, params),
        Command::CloudConversationSnapshot(params) => {
            cloud_conversations::snapshot(mux, client, params)
        }
        Command::CloudConversationHistory(params) => {
            cloud_conversations::history(mux, client, params)
        }
        Command::CloudConversationThread(params) => {
            cloud_conversations::thread(mux, client, params)
        }
        Command::CloudConversationRuns(params) => cloud_conversations::runs(mux, client, params),
        Command::CloudConversationRun(params) => cloud_conversations::run(mux, client, params),
        Command::CloudParticipantAvatarGet(params) => {
            cloud_conversations::participant_avatar(mux, client, params)
        }
        Command::CloudConversationOp(params) => cloud_conversations::op(mux, client, params),
        Command::CloudInboxOp(params) => cloud_conversations::inbox_op(mux, client, params),
        Command::CloudInboxSubscribe => cloud_conversations::subscribe(mux, client, None),
        Command::CloudMuxSubscribe(_) => cloud_conversations::mux_subscribe(mux, client),
        Command::CloudMuxUnsubscribe(_) => cloud_conversations::mux_unsubscribe(mux, client),
        Command::CloudMuxAck(params) => cloud_conversations::mux_ack(mux, client, params),
        Command::CloudInboxUnsubscribe => cloud_conversations::unsubscribe(mux, client, None),
        Command::CloudConversationSubscribe(params) => {
            cloud_conversations::subscribe(mux, client, Some(params))
        }
        Command::CloudConversationUnsubscribe(params) => {
            cloud_conversations::unsubscribe(mux, client, Some(params))
        }
        Command::CloudConversationLive(params) => cloud_conversations::live(mux, client, params),
        Command::CloudConversationTyping(params) => {
            cloud_conversations::typing(mux, client, params)
        }
        Command::CloudConversationPresence(params) => {
            cloud_conversations::presence(mux, client, params)
        }
        Command::ConversationAttachmentUpload(p) => conversation_attachments::put(mux, client, p),
        Command::ConversationAttachmentRead(p) => conversation_attachments::read(mux, client, p),
        Command::ConversationAttachmentLink(p) => conversation_attachments::link(mux, client, p),
        Command::CloudAttachmentUpload(p) => cloud_attachments::put(mux, client, p),
        Command::CloudAttachmentRead(p) => cloud_attachments::read(mux, client, p),
        Command::CloudAttachmentLink(p) => cloud_attachments::link(mux, client, p),
        Command::ConversationRunAppend(p) => conversation_runs::append(mux, client, p),
        Command::ConversationRuns(p) => conversation_runs::runs(mux, client, p),
        Command::ConversationRun(p) => conversation_runs::run(mux, client, p),
        Command::ConversationLivePublish(p) => conversation_live::publish(mux, client, p),
        Command::ConversationLive(p) => conversation_live::live(mux, client, p),
        Command::ConversationImport(params) => conversations::import(mux, client, params),
        Command::CreateProfile {
            name,
            profile,
            color,
            icon,
            theme,
            index,
            browser_profile_id,
            default_session_id,
            defaults,
            follows,
        } => cmd_profiles::create_profile(
            mux,
            name,
            profile,
            color,
            icon,
            theme,
            index,
            browser_profile_id,
            default_session_id,
            defaults,
            follows,
        ),
        Command::UpdateProfile {
            profile,
            name,
            color,
            icon,
            theme,
            browser_profile_id,
            default_session_id,
            defaults,
        } => cmd_profiles::update_profile(
            mux,
            profile,
            name,
            color,
            icon,
            theme,
            browser_profile_id,
            default_session_id,
            defaults,
        ),
        Command::MoveProfile { profile, index } => cmd_profiles::move_profile(mux, profile, index),
        Command::DeleteProfile { profile, move_to } => {
            cmd_profiles::delete_profile(mux, client, profile, move_to)
        }
        Command::SetProfileFollows { profile, session_ids } => {
            cmd_profiles::set_profile_follows(mux, profile, session_ids)
        }
        Command::PinWorkspace { session_id, workspace_key, profile } => {
            cmd_workspaces::pin_workspace(mux, session_id, workspace_key, profile)
        }
        Command::UnpinWorkspace { session_id, workspace_key } => {
            cmd_workspaces::unpin_workspace(mux, session_id, workspace_key)
        }
        Command::PutSession {
            session_id,
            machine_name,
            session_name,
            transport,
            capabilities,
            follow_with,
        } => cmd_profiles::put_session(
            mux,
            session_id,
            machine_name,
            session_name,
            transport,
            capabilities,
            follow_with,
        ),
        Command::ForgetSession { session_id, force } => {
            cmd_profiles::forget_session(mux, session_id, force)
        }
        Command::SetSessionIcon(params) => personal::set_session_icon(mux, params),
        Command::ImportSessionOrganization { session_id, groups, workspaces } => {
            cmd_profiles::import_session_organization(mux, session_id, groups, workspaces)
        }
        Command::CreatePersonalGroup { name, group, profile, color, collapsed, index } => {
            cmd_profiles::create_personal_group(mux, name, group, profile, color, collapsed, index)
        }
        Command::UpdatePersonalGroup { group, name, color, collapsed, profile } => {
            cmd_profiles::update_personal_group(mux, group, name, color, collapsed, profile)
        }
        Command::DeletePersonalGroup { group } => {
            cmd_profiles::delete_personal_group(mux, client, group)
        }
        Command::MovePersonalGroup { group, index } => {
            cmd_profiles::move_personal_group(mux, group, index)
        }
        command @ Command::SetPersonalWorkspace { .. } => {
            cmd_profiles::set_personal_workspace(mux, command)
        }
        Command::SetPersonalTerminal { session_id, terminal_key, theme } => {
            cmd_profiles::set_personal_terminal(mux, session_id, terminal_key, theme)
        }
        Command::ListWorkspaceGroups => cmd_workspaces::list_workspace_groups(mux),
        Command::CreateWorkspaceGroup { name, group, color, collapsed, index } => {
            cmd_workspaces::create_workspace_group(mux, name, group, color, collapsed, index)
        }
        Command::UpdateWorkspaceGroup { group, name, color, collapsed } => {
            cmd_workspaces::update_workspace_group(mux, group, name, color, collapsed)
        }
        Command::DeleteWorkspaceGroup { group } => {
            cmd_workspaces::delete_workspace_group(mux, group)
        }
        Command::MoveWorkspaceGroup { group, index } => {
            cmd_workspaces::move_workspace_group(mux, group, index)
        }
        Command::MoveWorkspaceToGroup { workspace, key, group, index, mutation } => {
            cmd_workspaces::move_workspace_to_group(
                mux, client, workspace, key, group, index, mutation,
            )
        }
        Command::SetDefaultColors {
            fg,
            bg,
            cursor,
            selection_bg,
            selection_fg,
            cursor_style,
            cursor_blink,
            palette,
            complete,
        } => cmd_terminal_io::set_default_colors(
            mux,
            fg,
            bg,
            cursor,
            selection_bg,
            selection_fg,
            cursor_style,
            cursor_blink,
            palette,
            complete,
        ),
        Command::CloseSurface { surface } => cmd_tabs::close_surface(mux, actor, surface),
        Command::CloseTabs { surfaces, end_terminals, transaction, reason, mutation } => {
            cmd_tabs::close_tabs(
                mux,
                client,
                surfaces,
                end_terminals,
                transaction,
                reason,
                mutation,
            )
        }
        Command::ClosePane { pane, end_terminals } => {
            cmd_panes::close_pane(mux, actor, pane, end_terminals)
        }
        Command::CloseScreen { screen, end_terminals } => {
            cmd_screens::close_screen(mux, actor, screen, end_terminals)
        }
        Command::CloseWorkspace {
            workspace,
            key,
            end_terminals,
            reason,
            if_empty,
            report_closed_ids,
            mutation,
        } => {
            let ending = cmd_workspaces::Ending {
                terminals: end_terminals,
                reason,
                if_empty,
                report_closed_ids,
            };
            cmd_workspaces::close_workspace(mux, client, workspace, key, ending, mutation)
        }
        Command::MarkWorkspacesProviderManaged { authority } => {
            cmd_workspaces::mark_workspaces_provider_managed(mux, authority)
        }
        Command::CloseProviderManagedWorkspace { workspace, key, authority } => {
            cmd_workspaces::close_provider_managed_workspace(mux, actor, workspace, key, authority)
        }
        Command::RenamePane { pane, name } => cmd_panes::rename_pane(mux, actor, pane, name),
        Command::RenameSurface { surface, name } => {
            cmd_tabs::rename_surface(mux, actor, surface, name)
        }
        Command::RenameScreen { screen, name } => {
            cmd_screens::rename_screen(mux, actor, screen, name)
        }
        Command::RenameWorkspace { request, mutation } => {
            cmd_workspaces::rename_workspace(mux, client, request, mutation)
        }
        Command::RenameProviderManagedWorkspace { workspace, key, name, authority } => {
            cmd_workspaces::rename_provider_managed_workspace(
                mux, actor, workspace, key, name, authority,
            )
        }
        Command::ResizeSurface { surface, cols, rows } => {
            cmd_sizing::resize_surface(mux, client, surface, cols, rows)
        }
        Command::ResizeAttachedView { surface, lease, view, identity, cols, rows } => {
            cmd_sizing::resize_attached_view(
                mux, client, surface, lease, view, identity, cols, rows,
            )
        }
        Command::ReleaseSurfaceSize { surface } => {
            cmd_sizing::release_surface_size(mux, client, surface)
        }
        Command::ReleaseAttachedViewSize { surface, lease, view } => {
            cmd_sizing::release_attached_view_size(mux, client, surface, lease, view)
        }
        Command::DetachAttachedView { surface, lease, view } => {
            cmd_attach::detach_attached_view(mux, client, surface, lease, view)
        }
        Command::FocusPane { pane } => cmd_panes::focus_pane(mux, actor, pane),
        Command::SelectTab { pane, index, delta } => {
            cmd_tabs::select_tab(mux, actor, pane, index, delta)
        }
        Command::SelectScreen { index, delta } => {
            cmd_screens::select_screen(mux, actor, index, delta)
        }
        Command::SelectWorkspace { index, delta } => {
            cmd_workspaces::select_workspace(mux, actor, index, delta)
        }
        Command::ReportFocus { client_id, pane, tab } => {
            cmd_server::report_focus(mux, client_id, pane, tab)
        }
        Command::ClientFocus { client_id } => cmd_server::client_focus(mux, client_id),
        Command::SnapshotRequest(params) => cmd_terminal_io::snapshot_request(mux, client, params),
        Command::TerminalHistory(params) => cmd_terminals::terminal_history(mux, params),
        Command::TerminalReadRange(params) => cmd_terminals::terminal_read_range(mux, params),
        Command::ScrollSurface { surface, delta } => {
            cmd_terminal_io::scroll_surface(mux, surface, delta)
        }
        Command::Subscribe { tree_events, surface } => {
            cmd_subscribe::subscribe_command(mux, client, writer, tree_events, surface)
        }
        Command::AttachSurface {
            surface: surface_id,
            mode,
            cols,
            rows,
            expected_generation,
            expected_terminal_id,
            snapshot,
        } => {
            // A sized attach is a size report: it starts (or renews) the
            // lease before the size applies.
            if let Some(surface) = surface_id.filter(|_| cols.is_some() && rows.is_some()) {
                size_lease::renew_size_lease(mux, client, surface);
            }
            cmd_attach::attach_surface(
                mux,
                client,
                writer,
                surface_id,
                mode,
                cols,
                rows,
                expected_generation,
                expected_terminal_id,
                snapshot,
            )
        }
    }
}
