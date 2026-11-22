//! Config loading: reads the config file, resolves every section against its defaults, and reports invalid sections without discarding valid ones.

use super::*;

/// Load the config: defaults, overlaid with the user's Ghostty selection
/// colors, overlaid with `cmux-tui.json` or legacy `mux.json`.
pub fn load() -> Config {
    let mut config = Config::default();

    let application_defaults = ghostty_application_defaults();
    let defaults = application_defaults.colors;
    config.terminal_defaults = defaults;
    config.scrollback_limit_bytes = application_defaults.scrollback_limit_bytes;
    if let Some(bg) = defaults.selection_bg {
        config.theme.selection_bg = Color::Rgb(bg.r, bg.g, bg.b);
        config.theme_overrides.selection = true;
    }
    if defaults.selection_fg.is_some() {
        config.theme_overrides.selection = true;
    }
    config.theme.selection_fg =
        defaults.selection_fg.map(|color| Color::Rgb(color.r, color.g, color.b));
    config.cursor_style = defaults.cursor_style;
    config.cursor_blink = defaults.cursor_blink;

    let raw = load_raw_config();
    let t = &raw.theme;
    if let Some(chrome) = t.chrome {
        config.chrome = chrome;
    }
    if let Some(c) = t.selection_background.as_ref().and_then(ColorValue::to_color) {
        config.theme.selection_bg = c;
        config.theme_overrides.selection = true;
    }
    match t.selection_foreground.as_ref() {
        None => {}
        Some(None) => {
            config.theme.selection_fg = None;
            config.theme_overrides.selection = true;
        }
        Some(Some(c)) => {
            if let Some(color) = c.to_color() {
                config.theme.selection_fg = Some(color);
                config.theme_overrides.selection = true;
            }
        }
    }
    if let Some(c) = t.sidebar_rail.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_rail = c;
    }
    if let Some(c) = t.sidebar_active_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_active_bg = c;
        config.theme_overrides.sidebar_active_bg = true;
    }
    if let Some(c) = t.tab_rail.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_rail = c;
    }
    if let Some(c) = t.tab_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_bg = c;
        config.theme_overrides.tab_bg = true;
    }
    if let Some(c) = t.tab_active_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_active_bg = Some(c);
    }
    if let Some(c) = t.border_active.as_ref().and_then(ColorValue::to_color) {
        config.theme.border_active = c;
        config.theme_overrides.border_active = true;
    }
    if let Some(c) = t.border_inactive.as_ref().and_then(ColorValue::to_color) {
        config.theme.border_inactive = c;
        config.theme_overrides.border_inactive = true;
    }
    if let Some(c) = t.notification_info.as_ref().and_then(ColorValue::to_color) {
        config.theme.notification_info = c;
    }
    if let Some(c) = t.notification_warning.as_ref().and_then(ColorValue::to_color) {
        config.theme.notification_warning = c;
    }
    if let Some(c) = t.notification_error.as_ref().and_then(ColorValue::to_color) {
        config.theme.notification_error = c;
    }
    if let Some(w) = raw.tabs.min_width {
        config.tabs.min_width = w.clamp(3, 40);
    }
    if let Some(b) = raw.tabs.solid_background {
        config.tabs.solid_background = b;
    }
    if let Some(b) = raw.tabs.show_titles {
        config.tabs.show_titles = b;
    }
    if let Some(agents) = raw.tabs.agents {
        config.tabs.agents = agents.into_iter().map(|a| a.to_lowercase()).collect();
    }
    if let Some(style) = raw.tabs.style {
        config.tabs.style = style;
    }
    if let Some(w) = raw.sidebar.width {
        config.sidebar.width = w.clamp(10, 60);
    }
    if let Some(w) = raw.sidebar.compact_width {
        config.sidebar.compact_width = w.clamp(10, 60);
    }
    config.sidebar.compact_width = config.sidebar.compact_width.min(config.sidebar.width);
    if let Some(view) = raw.sidebar.view {
        match parse_sidebar_view(&view) {
            Ok(view) => config.sidebar.view = view,
            Err(warning) => crate::client_log::stderr_log!("config", "{warning}"),
        }
    }
    if let Some(w) = raw.sidebar.max_width {
        config.sidebar.max_width = w;
    }
    if let Some(height) = raw.sidebar.row_height {
        config.sidebar.row_height = height.clamp(1, 2);
    }
    if let Some(gap) = raw.sidebar.row_gap {
        config.sidebar.row_gap = gap.min(2);
    }
    if let Some(glyph) = raw.sidebar.rail_glyph {
        if glyph.eq_ignore_ascii_case("none") {
            config.sidebar.rail_glyph = String::new();
        } else if glyph.chars().count() == 1
            && glyph.chars().all(|character| !character.is_control())
            && glyph.cell_width() == 1
        {
            // The renderer reserves exactly one cell for the glyph.
            config.sidebar.rail_glyph = glyph;
        } else {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring sidebar.rail_glyph {glyph:?}: one single-width character or \"none\""
            );
        }
    }
    if let Some(template) = raw.sidebar.workspace_label {
        let template = template.trim().to_string();
        if !template.is_empty() {
            config.sidebar.workspace_label = template;
        }
    }
    if let Some(plugin) = raw.sidebar.plugin {
        // Preserve every argument after argv[0]. Empty arguments are valid
        // process arguments, and filtering them would silently change the
        // command a user configured. Only the executable slot is required.
        let command = plugin.command.unwrap_or_default();
        if command.first().is_none_or(|arg| arg.trim().is_empty()) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring sidebar.plugin with empty command"
            );
        } else {
            config.sidebar.plugin = Some(SidebarPluginOptions {
                command,
                cwd: plugin.cwd.filter(|cwd| !cwd.trim().is_empty()),
            });
        }
    }
    // An explicit agents.plugin wins; otherwise the bundled screen detector
    // beside this daemon runs unless agents.screen_detection is false.
    config.agents.plugin = crate::agent_plugin_config::agent_plugin_for_this_daemon(raw.agents);
    if let Some(enabled) = raw.machine_sidebar.enabled {
        config.machine_sidebar.enabled = enabled;
    }
    if let Some(width) = raw.machine_sidebar.width {
        config.machine_sidebar.width = width.clamp(10, 60);
    }
    if let Some(max_width) = raw.machine_sidebar.max_width {
        config.machine_sidebar.max_width = max_width;
    }
    if let Some(sources) = raw.machine_sidebar.create_sources {
        let mut source_ids = HashSet::new();
        for source in sources {
            let id = source.id.trim().to_string();
            let name = source.name.trim().to_string();
            if id.is_empty() || name.is_empty() || !source_ids.insert(id.clone()) {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring machine creation source with an empty or duplicate id/name"
                );
                continue;
            }
            let subtitle =
                source.subtitle.map(|subtitle| subtitle.trim().to_string()).unwrap_or_default();
            config.machine_sidebar.create_sources.push(MachineCreationSourceConfig {
                id,
                name,
                subtitle,
            });
        }
    }
    if let Some(columns) = raw.sidebar.columns.as_ref() {
        let mut seen = HashSet::new();
        let mut resolved = Vec::new();
        for column in columns {
            let kind = match parse_sidebar_column_kind(column.kind.trim()) {
                Ok(kind) => kind,
                Err(warning) => {
                    crate::client_log::stderr_log!("config", "{warning}");
                    continue;
                }
            };
            if !seen.insert(kind) {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring duplicate sidebar column {:?}",
                    column.kind
                );
                continue;
            }
            let (default_width, default_max_width) = match kind {
                SidebarColumnKind::Machines => {
                    (config.machine_sidebar.width, config.machine_sidebar.max_width)
                }
                SidebarColumnKind::Workspaces => (config.sidebar.width, config.sidebar.max_width),
                SidebarColumnKind::Tabs => (22, 0),
            };
            resolved.push(SidebarColumn {
                kind,
                width: column.width.unwrap_or(default_width).clamp(10, 60),
                max_width: column.max_width.unwrap_or(default_max_width),
            });
        }
        if resolved.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.columns had no usable entries; keeping defaults"
            );
        } else {
            config.sidebar.columns = resolved;
            config.sidebar.columns_explicit = true;
        }
    } else {
        config.sidebar.columns = vec![
            SidebarColumn {
                kind: SidebarColumnKind::Machines,
                width: config.machine_sidebar.width,
                max_width: config.machine_sidebar.max_width,
            },
            SidebarColumn {
                kind: SidebarColumnKind::Workspaces,
                width: config.sidebar.width,
                max_width: config.sidebar.max_width,
            },
        ];
    }
    config.sidebar.views = config
        .sidebar
        .columns
        .iter()
        .map(|column| SidebarViewSpec::legacy(column.kind, column.width, column.max_width))
        .collect();
    config.sidebar.views_explicit = config.sidebar.columns_explicit;
    // User commands resolve before sidebar views so pinned buttons can
    // reference them as `command:<id>`; their chords bind after `keys`.
    let (user_commands, user_command_keys) = resolve_user_command_specs(raw.commands);
    let command_ids: Vec<String> = user_commands.iter().map(|command| command.id.clone()).collect();
    if let Some(plus) = raw.tabs.plus {
        config.tabs.plus = resolve_plus_button(plus, &command_ids, "tabs");
    }
    if let Some(plus) = raw.status_bar.screens_plus {
        config.status_bar.screens_plus = resolve_plus_button(plus, &command_ids, "status_bar");
    }
    if let Some(views) = raw.sidebar.views.as_ref() {
        if raw.sidebar.columns.is_some() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.views overrides sidebar.columns"
            );
        }
        let resolved = resolve_sidebar_view_specs(
            views,
            config.machine_sidebar.width,
            config.machine_sidebar.max_width,
            config.sidebar.width,
            config.sidebar.max_width,
            "sidebar",
            &command_ids,
        );
        if resolved.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.views had no usable entries; keeping defaults"
            );
        } else {
            config.sidebar.columns = resolved
                .iter()
                .filter_map(|view| {
                    view.legacy_kind().map(|kind| SidebarColumn {
                        kind,
                        width: view.width,
                        max_width: view.max_width,
                    })
                })
                .collect();
            config.sidebar.views = resolved;
            config.sidebar.columns_explicit = false;
            config.sidebar.views_explicit = true;
        }
    }
    config.sidebar.profiles[0].views.clone_from(&config.sidebar.views);
    if let Some(raw_profiles) = raw.sidebar.profiles.as_ref() {
        if raw.sidebar.views.is_some() || raw.sidebar.columns.is_some() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.profiles overrides sidebar.views and sidebar.columns"
            );
        }
        let mut ids = HashSet::new();
        let mut profiles = Vec::new();
        for raw_profile in raw_profiles {
            let id = raw_profile.id.trim();
            if id.is_empty() || !ids.insert(id.to_string()) {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring sidebar profile with an empty or duplicate id"
                );
                continue;
            }
            let owner = format!("sidebar profile {id:?}");
            let views = resolve_sidebar_view_specs(
                &raw_profile.views,
                config.machine_sidebar.width,
                config.machine_sidebar.max_width,
                config.sidebar.width,
                config.sidebar.max_width,
                &owner,
                &command_ids,
            );
            if views.is_empty() {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring sidebar profile {id:?} with no usable views"
                );
                continue;
            }
            let name = raw_profile
                .name
                .as_deref()
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .unwrap_or(id)
                .to_string();
            profiles.push(SidebarProfileSpec { id: id.to_string(), name, views });
        }
        if profiles.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.profiles had no usable entries; keeping defaults"
            );
        } else {
            let requested =
                raw.sidebar.profile.as_deref().map(str::trim).filter(|id| !id.is_empty());
            let selected = requested
                .and_then(|id| profiles.iter().position(|profile| profile.id == id))
                .unwrap_or_else(|| {
                    if let Some(requested) = requested {
                        crate::client_log::stderr_log!("config",
                            "{BIN}: sidebar.profile {requested:?} was not found; using the first profile"
                        );
                    }
                    0
                });
            config.sidebar.active_profile = profiles[selected].id.clone();
            config.sidebar.views = profiles[selected].views.clone();
            config.sidebar.columns = config
                .sidebar
                .views
                .iter()
                .filter_map(|view| {
                    view.legacy_kind().map(|kind| SidebarColumn {
                        kind,
                        width: view.width,
                        max_width: view.max_width,
                    })
                })
                .collect();
            config.sidebar.columns_explicit = false;
            config.sidebar.views_explicit = true;
            config.sidebar.profiles = profiles;
        }
    } else if raw.sidebar.profile.is_some() {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring sidebar.profile without sidebar.profiles"
        );
    }
    match raw.machine_provider.command {
        Some(command) if command.first().is_some_and(|program| !program.trim().is_empty()) => {
            config.machine_provider.command = Some(command);
        }
        Some(_) => {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring machine_provider.command without a program"
            );
        }
        None => {}
    }
    let cloud = raw.machine_provider.cloud;
    if let Some(enabled) = cloud.enabled {
        config.machine_provider.cloud.enabled = enabled;
    }
    if let Some(host) = cloud.host {
        let host = host.trim();
        if host.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring empty machine_provider.cloud.host"
            );
        } else {
            config.machine_provider.cloud.host = host.to_string();
        }
    }
    config.machine_provider.cloud.user =
        cloud.user.map(|user| user.trim().to_string()).filter(|user| !user.is_empty());
    config.machine_provider.cloud.port = match cloud.port {
        Some(0) => {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring zero machine_provider.cloud.port"
            );
            None
        }
        port => port,
    };
    config.machine_provider.cloud.identity_file = cloud
        .identity_file
        .map(|path| path.trim().to_string())
        .filter(|path| !path.is_empty())
        .map(PathBuf::from);
    let mut machine_ids = HashSet::new();
    for machine in raw.machines {
        let id = machine.id.trim().to_string();
        let name = machine.name.trim().to_string();
        if id.is_empty() || name.is_empty() || !machine_ids.insert(id.clone()) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring machine with an empty or duplicate id/name"
            );
            continue;
        }
        let target = match machine.target {
            RawMachineTarget::Unix { socket } if !socket.trim().is_empty() => {
                MachineTargetConfig::Unix { socket: PathBuf::from(socket) }
            }
            RawMachineTarget::Ssh { host, user, port, identity_file, session, binary }
                if !host.trim().is_empty() =>
            {
                let port = normalize_ssh_machine_port(&id, port);
                MachineTargetConfig::Ssh {
                    host: host.trim().to_string(),
                    user: user.filter(|value| !value.trim().is_empty()),
                    port,
                    identity_file: identity_file
                        .filter(|value| !value.trim().is_empty())
                        .map(PathBuf::from),
                    session: session
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or_else(|| "main".to_string()),
                    binary: binary
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or_else(|| "~/.local/bin/cmux-tui".to_string()),
                }
            }
            _ => {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring machine {id:?} with an empty transport target"
                );
                continue;
            }
        };
        config.machines.push(MachineConfig { id, name, subtitle: machine.subtitle, target });
    }
    config.browser.cdp_url = raw.browser.cdp_url.filter(|s| !s.trim().is_empty());
    if let Some(megapixels) = raw.browser.max_capture_megapixels {
        if megapixels.is_finite()
            && megapixels > 0.0
            && megapixels <= TRANSPORT_SAFE_CAPTURE_MEGAPIXELS
        {
            config.browser.max_capture_megapixels = megapixels;
        } else {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring browser.max_capture_megapixels={megapixels:?}; expected 0 < value <= {TRANSPORT_SAFE_CAPTURE_MEGAPIXELS}"
            );
        }
    }
    if let Some(scale) = raw.browser.capture_scale {
        if scale.is_finite() && scale > 0.0 && scale <= 1.0 {
            config.browser.capture_scale = Some(scale);
        } else {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring browser.capture_scale={scale:?}; expected 0 < scale <= 1"
            );
        }
    }
    if let Some(position) = raw.scrollbar.position {
        config.scrollbar.position = position;
    }
    if let Some(style) = raw.theme.border_style {
        config.theme.border_style = style;
    }
    if let Some(c) = raw.theme.status_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.status_bg = Some(c);
    }
    if let Some(c) = raw.theme.status_fg.as_ref().and_then(ColorValue::to_color) {
        config.theme.status_fg = Some(c);
    }
    if let Some(c) = raw.theme.sidebar_fg.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_fg = Some(c);
    }
    if let Some(c) = raw.theme.sidebar_selected_fg.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_selected_fg = Some(c);
    }
    if let Some(dim) = raw.theme.dim_inactive {
        config.theme.dim_inactive = dim;
    }
    if let Some(padding) = raw.pane.padding {
        config.pane.padding = padding.min(MAX_PANE_PADDING);
    }
    if let Some(visible) = raw.status_bar.visible {
        config.status_bar.visible = visible;
    }
    if let Some(show_screens) = raw.status_bar.show_screens {
        config.status_bar.show_screens = show_screens;
    }
    if let Some(show_session) = raw.status_bar.show_session {
        config.status_bar.show_session = show_session;
    }
    if let Some(left) = raw.status_bar.left {
        config.status_bar.left = resolve_status_segments(left, "left");
    }
    if let Some(right) = raw.status_bar.right {
        config.status_bar.right = resolve_status_segments(right, "right");
    }
    config.status_bar.left_separator =
        raw.status_bar.left_separator.filter(|separator| !separator.is_empty());
    config.status_bar.right_separator =
        raw.status_bar.right_separator.filter(|separator| !separator.is_empty());
    if let Some(style) = raw.status_bar.screens_style {
        config.status_bar.screens_style = style;
    }
    if let Some(animation) = raw.viewport.animation {
        config.viewport.animation = animation;
    }
    config.server.ws = raw.server.ws.filter(|value| !value.trim().is_empty());
    config.server.ws_token = raw.server.ws_token.filter(|value| !value.trim().is_empty());
    if let Some(detached_owner) = raw.server.detached_owner {
        config.server.detached_owner = detached_owner;
    }
    config.server.loopback_forward = raw.server.loopback_forward;
    config.keys.apply(&raw.keys);
    bind_user_command_chords(&mut config.keys, &user_commands, &user_command_keys);
    config.commands = user_commands;
    config
}

/// Validate the raw `commands` section into resolved specs plus each
/// command's raw chord values. Chords bind later, after the `keys` section
/// applied its overrides, so command chords keep last-write-wins order.
pub(super) fn resolve_user_command_specs(
    raw: Vec<RawUserCommand>,
) -> (Vec<UserCommandConfig>, Vec<Option<Value>>) {
    let mut commands = Vec::new();
    let mut key_values = Vec::new();
    let mut ids = HashSet::new();
    for command in raw {
        let id = command.id.as_deref().unwrap_or("").trim().to_string();
        if id.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command with a missing or empty id"
            );
            continue;
        }
        if ids.contains(&id) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command with duplicate id {id:?}"
            );
            continue;
        }
        // Empty positional arguments stay: argv executes directly, and an
        // empty argument is valid there. Only the program itself must exist.
        let run = command.run.unwrap_or_default();
        if run.first().is_none_or(|program| program.is_empty()) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command {id:?} without a run program"
            );
            continue;
        }
        if Action::user_command(commands.len()).is_none() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command {id:?} beyond the {MAX_USER_COMMANDS}-command limit"
            );
            continue;
        }
        // The id is reserved only after validation, so an ignored invalid
        // entry never blocks a later valid entry with the same id.
        ids.insert(id.clone());
        let name = command
            .name
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| id.clone());
        let cwd = command.cwd.map(|cwd| cwd.trim().to_string()).filter(|cwd| !cwd.is_empty());
        commands.push(UserCommandConfig { id, name, run, cwd });
        key_values.push(command.keys);
    }
    (commands, key_values)
}

/// Bind every command's chords after `keys` overrides applied.
pub(super) fn bind_user_command_chords(
    keys: &mut Keys,
    commands: &[UserCommandConfig],
    chord_values: &[Option<Value>],
) {
    for (index, (command, value)) in commands.iter().zip(chord_values).enumerate() {
        let Some(action) = Action::user_command(index) else { break };
        let Some(value) = value.as_ref() else { continue };
        let id = &command.id;
        let mut bound = 0usize;
        for raw_chord in key_values(value) {
            if raw_chord.eq_ignore_ascii_case("none") {
                continue;
            }
            if bound >= MAX_USER_COMMAND_CHORDS {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring command {id:?} chords beyond the {MAX_USER_COMMAND_CHORDS}-chord limit"
                );
                break;
            }
            let Some(chord) = parse_chord(raw_chord) else {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring unparseable command binding {id} = {raw_chord:?}"
                );
                continue;
            };
            // Only a successful bind consumes the limit; rejected chords
            // leave room for the valid ones after them.
            if keys.bind_user_command_chord(id, action, chord) {
                bound += 1;
            }
        }
    }
    keys.rebuild_dispatch_maps();
}

pub(super) fn normalize_ssh_machine_port(id: &str, port: Option<u16>) -> Option<u16> {
    match port {
        Some(0) => {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring zero SSH machine port for {id:?}"
            );
            None
        }
        port => port,
    }
}

pub(super) fn load_raw_config() -> RawConfig {
    // A config that exists but cannot be read leaves the user's agents choice
    // unknown, so the bundled screen detector stays off (agent_plugin_config).
    let unreadable = || RawConfig {
        agents: crate::agent_plugin_config::RawAgents::invalid(),
        ..RawConfig::default()
    };
    let Some(path) = platform::config_path() else { return RawConfig::default() };
    let text = match read_config_text(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return RawConfig::default(),
        Err(_) => return unreadable(),
    };
    let value: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(e) => {
            crate::client_log::stderr_log!(
                "config",
                "{} ({})",
                config_diagnostic(&e),
                path.display(),
            );
            return unreadable();
        }
    };
    let Some(object) = value.as_object() else {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring invalid config {}: root must be an object",
            path.display()
        );
        return unreadable();
    };
    const KNOWN: &[&str] = &[
        "theme",
        "tabs",
        "sidebar",
        "agents",
        "machine_sidebar",
        "machine_provider",
        "machines",
        "commands",
        "browser",
        "scrollbar",
        "pane",
        "status_bar",
        "viewport",
        "server",
        "keys",
    ];
    if let Some(unknown) = object.keys().find(|key| !KNOWN.contains(&key.as_str())) {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring invalid config {}: unknown top-level field `{unknown}`",
            path.display()
        );
        return unreadable();
    }
    let mut raw = RawConfig::default();
    // An invalid section keeps its defaults, or `$invalid` when given.
    macro_rules! section {
        ($field:ident, $name:literal $(, $invalid:expr)?) => {
            if let Some(value) = object.get($name) {
                match serde_json::from_value(value.clone()) {
                    Ok(parsed) => raw.$field = parsed,
                    Err(error) => {
                        crate::client_log::stderr_log!(
                            "config",
                            "{BIN}: ignoring invalid `{}` section in {}: {}",
                            $name,
                            path.display(),
                            error
                        );
                        $(raw.$field = $invalid;)?
                    }
                }
            }
        };
    }
    section!(theme, "theme");
    section!(tabs, "tabs");
    section!(sidebar, "sidebar");
    // An unreadable agents section must not turn the bundled detector on.
    section!(agents, "agents", crate::agent_plugin_config::RawAgents::invalid());
    section!(machine_sidebar, "machine_sidebar");
    section!(machine_provider, "machine_provider");
    section!(machines, "machines");
    section!(commands, "commands");
    section!(browser, "browser");
    section!(scrollbar, "scrollbar");
    section!(pane, "pane");
    section!(status_bar, "status_bar");
    section!(viewport, "viewport");
    section!(server, "server");
    section!(keys, "keys");
    raw
}

pub(super) fn config_diagnostic(error: &serde_json::Error) -> String {
    let text = error.to_string();
    if text.contains("unknown field") {
        return catalog().config.unknown_field("(see config file)");
    }
    if text.contains("invalid type") && text.contains("map") {
        return catalog().config.invalid_root();
    }
    catalog().config.invalid_section("(see config file)")
}
