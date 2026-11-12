// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! Arguments and enumeration values shared by catalog actions. An optional use is
//! `NAME.optional()`.

use crate::model::*;
use crate::text::{t, tf};

#[rustfmt::skip]
pub const CASES_GENERAL_APPEARANCE: &[EnumCase] = &[EnumCase { value: "general", title: t("SettingsActions", "argument.value.section.general", "General") }, EnumCase { value: "appearance", title: t("SettingsActions", "argument.value.section.appearance", "Appearance") }, EnumCase { value: "terminal", title: t("SettingsActions", "argument.value.section.terminal", "Terminal") }, EnumCase { value: "browser", title: t("SettingsActions", "argument.value.section.browser", "Browser") }, EnumCase { value: "home", title: t("SettingsActions", "argument.value.section.home", "Home") }, EnumCase { value: "keyboard", title: t("SettingsActions", "argument.value.section.keyboard", "Keyboard") }, EnumCase { value: "notifications", title: t("SettingsActions", "argument.value.section.notifications", "Notifications") }, EnumCase { value: "accounts", title: t("SettingsActions", "argument.value.section.accounts", "Accounts") }, EnumCase { value: "rooms", title: t("SettingsActions", "argument.value.section.rooms", "Spaces & Profiles") }, EnumCase { value: "machines", title: t("SettingsActions", "argument.value.section.machines", "Machines") }, EnumCase { value: "advanced", title: t("SettingsActions", "argument.value.section.advanced", "Advanced") }, EnumCase { value: "development", title: t("SettingsActions", "argument.value.section.development", "Development") }];
#[rustfmt::skip]
pub const CASES_AUTO_TODO: &[EnumCase] = &[EnumCase { value: "auto", title: t("Localizable", "argument.value.auto", "Automatic") }, EnumCase { value: "todo", title: t("Localizable", "argument.value.todo", "To Do") }, EnumCase { value: "working", title: t("Localizable", "argument.value.working", "Working") }, EnumCase { value: "needs-attention", title: t("Localizable", "argument.value.needsAttention", "Needs Attention") }, EnumCase { value: "review", title: t("Localizable", "argument.value.review", "In Review") }, EnumCase { value: "done", title: t("Localizable", "argument.value.done", "Done") }];
#[rustfmt::skip]
pub const CASES_GREY_BLUE: &[EnumCase] = &[EnumCase { value: "grey", title: t("Localizable", "argument.value.grey", "Grey") }, EnumCase { value: "blue", title: t("Localizable", "argument.value.blue", "Blue") }, EnumCase { value: "red", title: t("Localizable", "argument.value.red", "Red") }, EnumCase { value: "yellow", title: t("Localizable", "argument.value.yellow", "Yellow") }, EnumCase { value: "green", title: t("Localizable", "argument.value.green", "Green") }, EnumCase { value: "pink", title: t("Localizable", "argument.value.pink", "Pink") }, EnumCase { value: "purple", title: t("Localizable", "argument.value.purple", "Purple") }, EnumCase { value: "cyan", title: t("Localizable", "argument.value.cyan", "Cyan") }, EnumCase { value: "orange", title: t("Localizable", "argument.value.orange", "Orange") }];
#[rustfmt::skip]
pub const CASES_MANUAL_NAME: &[EnumCase] = &[EnumCase { value: "manual", title: t("WorkspaceActions", "argument.value.groupSort.manual", "Manual") }, EnumCase { value: "name", title: t("WorkspaceActions", "argument.value.groupSort.name", "Name") }, EnumCase { value: "recent", title: t("WorkspaceActions", "argument.value.groupSort.recent", "Recent") }];
#[rustfmt::skip]
pub const CASES_CONFIG_ROSE_PINE: &[EnumCase] = &[EnumCase { value: "config", title: t("ThemeActions", "argument.value.theme.config", "Use Ghostty Config") }, EnumCase { value: "Rose Pine", title: Text::raw("Rose Pine") }, EnumCase { value: "Rose Pine Moon", title: Text::raw("Rose Pine Moon") }, EnumCase { value: "Catppuccin Mocha", title: Text::raw("Catppuccin Mocha") }, EnumCase { value: "TokyoNight", title: Text::raw("TokyoNight") }, EnumCase { value: "Gruvbox Dark", title: Text::raw("Gruvbox Dark") }, EnumCase { value: "Nord", title: Text::raw("Nord") }, EnumCase { value: "Vesper", title: Text::raw("Vesper") }, EnumCase { value: "Soft Blue", title: Text::raw("Soft Blue") }, EnumCase { value: "Clay Orange", title: Text::raw("Clay Orange") }, EnumCase { value: "Olive Grey", title: Text::raw("Olive Grey") }, EnumCase { value: "Rose Pine Dawn", title: Text::raw("Rose Pine Dawn") }, EnumCase { value: "Catppuccin Latte", title: Text::raw("Catppuccin Latte") }, EnumCase { value: "GitHub Light Default", title: Text::raw("GitHub Light Default") }, EnumCase { value: "Soft Blue Light", title: Text::raw("Soft Blue Light") }, EnumCase { value: "Clay Orange Light", title: Text::raw("Clay Orange Light") }];
#[rustfmt::skip]
pub const CASES_TAB_EDITOR: &[EnumCase] = &[EnumCase { value: "tab", title: t("Localizable", "argument.value.tab", "Tab") }, EnumCase { value: "editor", title: t("Localizable", "argument.value.editor", "Editor") }];
#[rustfmt::skip]
pub const CASES_WEBKIT_CEF: &[EnumCase] = &[EnumCase { value: "webkit", title: t("Localizable", "argument.value.webkit", "WebKit") }, EnumCase { value: "cef", title: t("Localizable", "argument.value.cef", "Chromium") }];
#[rustfmt::skip]
pub const CASES_MESSAGES_CHANNELS: &[EnumCase] = &[EnumCase { value: "messages", title: t("HomeActions", "argument.home.view.messages", "Home") }, EnumCase { value: "channels", title: t("HomeActions", "argument.home.view.channels", "Channels") }];
#[rustfmt::skip]
pub const CASES_AUTO_MENTIONS: &[EnumCase] = &[EnumCase { value: "auto", title: t("HomeActions", "argument.home.replies.auto", "Automatically") }, EnumCase { value: "mentions", title: t("HomeActions", "argument.home.replies.mentions", "Only When @Mentioned") }, EnumCase { value: "all", title: t("HomeActions", "argument.home.replies.all", "To Every Message") }];
#[rustfmt::skip]
pub const CASES_RIGHT_DOWN: &[EnumCase] = &[EnumCase { value: "right", title: t("Localizable", "argument.value.right", "Right") }, EnumCase { value: "down", title: t("Localizable", "argument.value.down", "Down") }, EnumCase { value: "left", title: t("Localizable", "argument.value.left", "Left") }, EnumCase { value: "up", title: t("Localizable", "argument.value.up", "Up") }];
#[rustfmt::skip]
pub const CASES_HOUR_TODAY: &[EnumCase] = &[EnumCase { value: "hour", title: t("HistoryActions", "argument.history.range.hour", "Last Hour") }, EnumCase { value: "today", title: t("HistoryActions", "argument.history.range.today", "Today") }, EnumCase { value: "week", title: t("HistoryActions", "argument.history.range.week", "Last 7 Days") }, EnumCase { value: "month", title: t("HistoryActions", "argument.history.range.month", "Last 4 Weeks") }, EnumCase { value: "all", title: t("HistoryActions", "argument.history.range.all", "All Time") }];
#[rustfmt::skip]
pub const CASES_SYSTEM_LIGHT: &[EnumCase] = &[EnumCase { value: "system", title: t("Localizable", "argument.value.system", "System") }, EnumCase { value: "light", title: t("Localizable", "argument.value.light", "Light") }, EnumCase { value: "dark", title: t("Localizable", "argument.value.dark", "Dark") }];
#[rustfmt::skip]
pub const CASES_16_9_16_10: &[EnumCase] = &[EnumCase { value: "16:9", title: Text::raw("16:9") }, EnumCase { value: "16:10", title: Text::raw("16:10") }, EnumCase { value: "4:3", title: Text::raw("4:3") }, EnumCase { value: "21:9", title: Text::raw("21:9") }, EnumCase { value: "1280", title: tf("Localizable", "argument.value.fitWidth", "%lld px", "1,280") }, EnumCase { value: "1440", title: tf("Localizable", "argument.value.fitWidth", "%lld px", "1,440") }, EnumCase { value: "1920", title: tf("Localizable", "argument.value.fitWidth", "%lld px", "1,920") }, EnumCase { value: "off", title: t("Localizable", "argument.value.fitOff", "Turn Off") }];
#[rustfmt::skip]
pub const CASES_LOCATION_CAMERA: &[EnumCase] = &[EnumCase { value: "location", title: t("PageInfoActions", "argument.permission.location", "Location") }, EnumCase { value: "camera", title: t("PageInfoActions", "argument.permission.camera", "Camera") }, EnumCase { value: "microphone", title: t("PageInfoActions", "argument.permission.microphone", "Microphone") }, EnumCase { value: "notifications", title: t("PageInfoActions", "argument.permission.notifications", "Notifications") }, EnumCase { value: "javascript", title: t("PageInfoActions", "argument.permission.javascript", "JavaScript") }, EnumCase { value: "images", title: t("PageInfoActions", "argument.permission.images", "Images") }, EnumCase { value: "popups", title: t("PageInfoActions", "argument.permission.popups", "Pop-ups and redirects") }, EnumCase { value: "sound", title: t("PageInfoActions", "argument.permission.sound", "Sound") }, EnumCase { value: "automaticDownloads", title: t("PageInfoActions", "argument.permission.automaticDownloads", "Automatic downloads") }, EnumCase { value: "midi", title: t("PageInfoActions", "argument.permission.midi", "MIDI device control & reprogram") }, EnumCase { value: "usb", title: t("PageInfoActions", "argument.permission.usb", "USB devices") }, EnumCase { value: "serial", title: t("PageInfoActions", "argument.permission.serial", "Serial ports") }, EnumCase { value: "hid", title: t("PageInfoActions", "argument.permission.hid", "HID devices") }, EnumCase { value: "clipboard", title: t("PageInfoActions", "argument.permission.clipboard", "Clipboard") }, EnumCase { value: "sensors", title: t("PageInfoActions", "argument.permission.sensors", "Motion sensors") }, EnumCase { value: "bluetooth", title: t("PageInfoActions", "argument.permission.bluetooth", "Bluetooth devices") }, EnumCase { value: "fileEditing", title: t("PageInfoActions", "argument.permission.fileEditing", "File editing") }, EnumCase { value: "windowManagement", title: t("PageInfoActions", "argument.permission.windowManagement", "Window management") }, EnumCase { value: "localFonts", title: t("PageInfoActions", "argument.permission.localFonts", "Fonts") }, EnumCase { value: "backgroundSync", title: t("PageInfoActions", "argument.permission.backgroundSync", "Background sync") }, EnumCase { value: "autoPictureInPicture", title: t("PageInfoActions", "argument.permission.autoPictureInPicture", "Auto picture-in-picture") }, EnumCase { value: "thirdPartySignIn", title: t("PageInfoActions", "argument.permission.thirdPartySignIn", "Third-party sign-in") }, EnumCase { value: "insecureContent", title: t("PageInfoActions", "argument.permission.insecureContent", "Insecure content") }];
#[rustfmt::skip]
pub const CASES_ASK_ALLOW: &[EnumCase] = &[EnumCase { value: "ask", title: t("PageInfoActions", "argument.setting.ask", "Ask") }, EnumCase { value: "allow", title: t("PageInfoActions", "argument.setting.allow", "Allow") }, EnumCase { value: "block", title: t("PageInfoActions", "argument.setting.block", "Block") }];
#[rustfmt::skip]
pub const CASES_INHERIT_NONE: &[EnumCase] = &[EnumCase { value: "inherit", title: t("Localizable", "argument.value.notifications.sound.inherit", "Inherit") }, EnumCase { value: "none", title: t("Localizable", "argument.value.notifications.sound.none", "No Sound") }, EnumCase { value: "default", title: t("Localizable", "argument.value.notifications.sound.default", "macOS Default") }, EnumCase { value: "Basso", title: Text::raw("Basso") }, EnumCase { value: "Blow", title: Text::raw("Blow") }, EnumCase { value: "Bottle", title: Text::raw("Bottle") }, EnumCase { value: "Frog", title: Text::raw("Frog") }, EnumCase { value: "Funk", title: Text::raw("Funk") }, EnumCase { value: "Glass", title: Text::raw("Glass") }, EnumCase { value: "Hero", title: Text::raw("Hero") }, EnumCase { value: "Morse", title: Text::raw("Morse") }, EnumCase { value: "Ping", title: Text::raw("Ping") }, EnumCase { value: "Pop", title: Text::raw("Pop") }, EnumCase { value: "Purr", title: Text::raw("Purr") }, EnumCase { value: "Sosumi", title: Text::raw("Sosumi") }, EnumCase { value: "Submarine", title: Text::raw("Submarine") }, EnumCase { value: "Tink", title: Text::raw("Tink") }, EnumCase { value: "choose", title: t("Localizable", "argument.value.notifications.sound.choose", "Choose Sound File…") }];
#[rustfmt::skip]
pub const CASES_ALL_FINISHED: &[EnumCase] = &[EnumCase { value: "all", title: t("Localizable", "argument.value.notifications.event.all", "Every Event") }, EnumCase { value: "finished", title: t("Localizable", "argument.value.notifications.event.finished", "Agent Finished") }, EnumCase { value: "needsInput", title: t("Localizable", "argument.value.notifications.event.needsInput", "Agent Needs Input") }, EnumCase { value: "error", title: t("Localizable", "argument.value.notifications.event.error", "Error") }, EnumCase { value: "bell", title: t("Localizable", "argument.value.notifications.event.bell", "Terminal Notification") }, EnumCase { value: "message", title: t("Localizable", "argument.value.notifications.event.message", "cmux notify Message") }];
#[rustfmt::skip]
pub const CASES_CLAUDE_CODEX: &[EnumCase] = &[EnumCase { value: "claude", title: Text::raw("Claude Code") }, EnumCase { value: "codex", title: Text::raw("Codex") }, EnumCase { value: "opencode", title: Text::raw("OpenCode") }, EnumCase { value: "gemini", title: Text::raw("Gemini") }];
#[rustfmt::skip]
pub const CASES_FINISHED_NEEDS_INPUT: &[EnumCase] = &[EnumCase { value: "finished", title: t("Localizable", "argument.value.notifications.event.finished", "Agent Finished") }, EnumCase { value: "needsInput", title: t("Localizable", "argument.value.notifications.event.needsInput", "Agent Needs Input") }, EnumCase { value: "error", title: t("Localizable", "argument.value.notifications.event.error", "Error") }, EnumCase { value: "bell", title: t("Localizable", "argument.value.notifications.event.bell", "Terminal Notification") }, EnumCase { value: "message", title: t("Localizable", "argument.value.notifications.event.message", "cmux notify Message") }];
#[rustfmt::skip]
pub const CASES_TALK_VIEW: &[EnumCase] = &[EnumCase { value: "talk", title: t("ActionCatalog", "argument.agentShare.role.talk", "Can talk") }, EnumCase { value: "view", title: t("ActionCatalog", "argument.agentShare.role.view", "Can view") }];
#[rustfmt::skip]
pub const CASES_ACP_TERMINAL: &[EnumCase] = &[EnumCase { value: "acp", title: t("ActionCatalog", "argument.agent.harness.protocol.acp", "ACP") }, EnumCase { value: "terminal", title: t("ActionCatalog", "argument.agent.harness.protocol.terminal", "Terminal") }];
#[rustfmt::skip]
pub const CASES_RD: &[EnumCase] = &[EnumCase { value: "rd", title: t("Localizable", "argument.value.viewerRd", "Video Stream") }];
#[rustfmt::skip]
pub const CASES_SMALL_MEDIUM: &[EnumCase] = &[EnumCase { value: "small", title: t("Localizable", "argument.value.small", "Small") }, EnumCase { value: "medium", title: t("Localizable", "argument.value.medium", "Medium") }, EnumCase { value: "large", title: t("Localizable", "argument.value.large", "Large") }, EnumCase { value: "xlarge", title: t("Localizable", "argument.value.xlarge", "Extra Large") }];
#[rustfmt::skip]
pub const CASES_OFF_15: &[EnumCase] = &[EnumCase { value: "off", title: t("Localizable", "argument.value.idlePauseOff", "Off") }, EnumCase { value: "15", title: t("Localizable", "argument.value.idlePause15", "After 15 Minutes") }, EnumCase { value: "30", title: t("Localizable", "argument.value.idlePause30", "After 30 Minutes") }, EnumCase { value: "60", title: t("Localizable", "argument.value.idlePause60", "After 1 Hour") }, EnumCase { value: "120", title: t("Localizable", "argument.value.idlePause120", "After 2 Hours") }];
#[rustfmt::skip]
pub const CASES_FULL_TRUSTED: &[EnumCase] = &[EnumCase { value: "full", title: t("Localizable", "argument.value.networkAccessFull", "Full Internet") }, EnumCase { value: "trusted", title: t("Localizable", "argument.value.networkAccessTrusted", "GitHub, Package Registries and Model Providers") }, EnumCase { value: "none", title: t("Localizable", "argument.value.networkAccessNone", "No Internet") }];
#[rustfmt::skip]
pub const CASES_CODEX_OPENAI: &[EnumCase] = &[EnumCase { value: "codex", title: Text::raw("ChatGPT / Codex") }, EnumCase { value: "openai", title: Text::raw("OpenAI API") }, EnumCase { value: "claude", title: Text::raw("Claude Code") }, EnumCase { value: "anthropic", title: Text::raw("Anthropic API") }, EnumCase { value: "gemini", title: Text::raw("Gemini") }, EnumCase { value: "openrouter", title: Text::raw("OpenRouter") }, EnumCase { value: "groq", title: Text::raw("Groq") }, EnumCase { value: "xai", title: Text::raw("xAI") }, EnumCase { value: "mistral", title: Text::raw("Mistral") }, EnumCase { value: "deepseek", title: Text::raw("DeepSeek") }, EnumCase { value: "bedrock", title: Text::raw("Amazon Bedrock") }, EnumCase { value: "vertex", title: Text::raw("Google Vertex AI") }, EnumCase { value: "copilot", title: Text::raw("GitHub Copilot") }];
#[rustfmt::skip]
pub const CASES_CODEX_OPENAI_2: &[EnumCase] = &[EnumCase { value: "codex", title: Text::raw("ChatGPT / Codex") }, EnumCase { value: "openai", title: Text::raw("OpenAI API") }, EnumCase { value: "claude", title: Text::raw("Claude Code") }, EnumCase { value: "anthropic", title: Text::raw("Anthropic API") }, EnumCase { value: "openrouter", title: Text::raw("OpenRouter") }, EnumCase { value: "bedrock", title: Text::raw("Amazon Bedrock") }];
#[rustfmt::skip]
pub const CASES_NETWORK_CODE: &[EnumCase] = &[EnumCase { value: "network", title: t("RemoteActions", "argument.value.addDeviceWay.network", "On Your Network") }, EnumCase { value: "code", title: t("RemoteActions", "argument.value.addDeviceWay.code", "It Shows a Code") }, EnumCase { value: "newDevice", title: t("RemoteActions", "argument.value.addDeviceWay.newDevice", "Set Up a New Device") }];
#[rustfmt::skip]
pub const CASES_MACHINE_THIS_MAC: &[EnumCase] = &[EnumCase { value: "machine", title: t("RemoteActions", "argument.value.remoteLocalhost.machine", "The Workspace's Machine") }, EnumCase { value: "thisMac", title: t("RemoteActions", "argument.value.remoteLocalhost.thisMac", "This Mac") }, EnumCase { value: "setting", title: t("RemoteActions", "argument.value.remoteLocalhost.setting", "Follow Settings") }];
#[rustfmt::skip]
pub const CASES_CMUX_ITERM2: &[EnumCase] = &[EnumCase { value: "cmux", title: t("Localizable", "argument.value.keymap.cmux", "cmux (Default)") }, EnumCase { value: "iterm2", title: t("Localizable", "argument.value.keymap.iterm2", "iTerm2") }, EnumCase { value: "terminal", title: t("Localizable", "argument.value.keymap.terminal", "Terminal.app") }, EnumCase { value: "tmux", title: t("Localizable", "argument.value.keymap.tmux", "Prefix chords (Ctrl-B)") }];
#[rustfmt::skip]
pub const CASES_STABLE_NIGHTLY: &[EnumCase] = &[EnumCase { value: "stable", title: t("Localizable", "argument.value.stable", "Stable") }, EnumCase { value: "nightly", title: t("Localizable", "argument.value.nightly", "Nightly") }, EnumCase { value: "dev", title: t("Localizable", "argument.value.dev", "DEV") }];
#[rustfmt::skip]
pub const CASES_ULTRA_COMPACT_COMPACT: &[EnumCase] = &[EnumCase { value: "ultraCompact", title: t("SettingsActions", "action.appearance.density.ultraCompact", "Density: Ultra-compact").without("SettingsActions", "action.appearance.density.prefix", "Density: ") }, EnumCase { value: "compact", title: t("SettingsActions", "action.appearance.density.compact", "Density: Compact").without("SettingsActions", "action.appearance.density.prefix", "Density: ") }, EnumCase { value: "cozy", title: t("SettingsActions", "action.appearance.density.cozy", "Density: Default").without("SettingsActions", "action.appearance.density.prefix", "Density: ") }, EnumCase { value: "comfortable", title: t("SettingsActions", "action.appearance.density.comfortable", "Density: Comfortable").without("SettingsActions", "action.appearance.density.prefix", "Density: ") }, EnumCase { value: "spacious", title: t("SettingsActions", "action.appearance.density.spacious", "Density: Spacious").without("SettingsActions", "action.appearance.density.prefix", "Density: ") }];
#[rustfmt::skip]
pub const CASES_INHERIT_NONE_2: &[EnumCase] = &[EnumCase { value: "inherit", title: t("LayoutActions", "argument.value.paneBackground.inherit", "Same as Workspace") }, EnumCase { value: "none", title: t("LayoutActions", "argument.value.paneBackground.none", "None") }, EnumCase { value: "daily", title: t("LayoutActions", "argument.value.paneBackground.shufflePaintings", "Shuffle Paintings") }, EnumCase { value: "desktop", title: t("LayoutActions", "argument.value.paneBackground.desktop", "Desktop Wallpaper") }];
#[rustfmt::skip]
pub const CASES_NONE_RED: &[EnumCase] = &[EnumCase { value: "none", title: t("LayoutActions", "argument.value.paneTint.none", "None") }, EnumCase { value: "red", title: t("LayoutActions", "argument.value.paneTint.red", "Red") }, EnumCase { value: "orange", title: t("LayoutActions", "argument.value.paneTint.orange", "Orange") }, EnumCase { value: "yellow", title: t("LayoutActions", "argument.value.paneTint.yellow", "Yellow") }, EnumCase { value: "green", title: t("LayoutActions", "argument.value.paneTint.green", "Green") }, EnumCase { value: "teal", title: t("LayoutActions", "argument.value.paneTint.teal", "Teal") }, EnumCase { value: "blue", title: t("LayoutActions", "argument.value.paneTint.blue", "Blue") }, EnumCase { value: "purple", title: t("LayoutActions", "argument.value.paneTint.purple", "Purple") }, EnumCase { value: "pink", title: t("LayoutActions", "argument.value.paneTint.pink", "Pink") }, EnumCase { value: "gray", title: t("LayoutActions", "argument.value.paneTint.gray", "Gray") }];
#[rustfmt::skip]
pub const CASES_WINDOW_WORKSPACE: &[EnumCase] = &[EnumCase { value: "window", title: t("LayoutActions", "argument.value.appearanceScope.window", "Window") }, EnumCase { value: "workspace", title: t("LayoutActions", "argument.value.appearanceScope.workspace", "Workspace") }, EnumCase { value: "pane", title: t("LayoutActions", "argument.value.appearanceScope.pane", "Pane") }, EnumCase { value: "tab", title: t("LayoutActions", "argument.value.appearanceScope.tab", "Tab") }];
#[rustfmt::skip]
pub const CASES_THEME_BACKGROUND: &[EnumCase] = &[EnumCase { value: "theme", title: t("LayoutActions", "argument.value.appearanceProperty.theme", "Theme") }, EnumCase { value: "background", title: t("LayoutActions", "argument.value.appearanceProperty.background", "Background") }, EnumCase { value: "tint", title: t("LayoutActions", "argument.value.appearanceProperty.tint", "Tint") }, EnumCase { value: "opacity", title: t("LayoutActions", "argument.value.appearanceProperty.opacity", "Opacity") }];
#[rustfmt::skip]
pub const CASES_TERMINAL_BROWSER: &[EnumCase] = &[EnumCase { value: "terminal", title: t("LayoutActions", "argument.value.dividerInsertKind.terminal", "Terminal") }, EnumCase { value: "browser", title: t("LayoutActions", "argument.value.dividerInsertKind.browser", "Browser") }, EnumCase { value: "agentChat", title: t("LayoutActions", "argument.value.dividerInsertKind.agentChat", "Agent Chat") }, EnumCase { value: "newTabPage", title: t("LayoutActions", "argument.value.dividerInsertKind.newTabPage", "New Tab Page") }];
#[rustfmt::skip]
pub const CASES_ALL: &[EnumCase] = &[EnumCase { value: "all", title: t("WorkspaceActions", "argument.value.autoArchive.restoreAll", "Restore All") }];
#[rustfmt::skip]
pub const CASES_DEFAULT_NEVER: &[EnumCase] = &[EnumCase { value: "default", title: t("WorkspaceActions", "argument.value.autoArchive.default", "Use the Default") }, EnumCase { value: "never", title: t("WorkspaceActions", "argument.value.autoArchive.never", "Never") }, EnumCase { value: "24", title: t("WorkspaceActions", "argument.value.autoArchive.day", "After 1 Idle Day") }, EnumCase { value: "72", title: t("WorkspaceActions", "argument.value.autoArchive.threeDays", "After 3 Idle Days") }, EnumCase { value: "168", title: t("WorkspaceActions", "argument.value.autoArchive.week", "After 1 Idle Week") }, EnumCase { value: "720", title: t("WorkspaceActions", "argument.value.autoArchive.month", "After 30 Idle Days") }];
#[rustfmt::skip]
pub const CASES_RIGHT_LEFT: &[EnumCase] = &[EnumCase { value: "right", title: t("Localizable", "argument.value.right", "Right") }, EnumCase { value: "left", title: t("Localizable", "argument.value.left", "Left") }, EnumCase { value: "top", title: Text::raw("top") }, EnumCase { value: "bottom", title: Text::raw("bottom") }];
#[rustfmt::skip]
pub const CASES_DOCKED_OVERLAY: &[EnumCase] = &[EnumCase { value: "docked", title: t("Localizable", "argument.value.docked", "Docked") }, EnumCase { value: "overlay", title: t("Localizable", "argument.value.overlay", "Floating") }];
#[rustfmt::skip]
pub const CASES_ALL_PAGE: &[EnumCase] = &[EnumCase { value: "all", title: t("HistoryActions", "argument.history.kind.all", "Everything") }, EnumCase { value: "page", title: t("HistoryActions", "argument.history.kind.page", "Pages") }, EnumCase { value: "location", title: t("HistoryActions", "argument.history.kind.location", "Locations") }, EnumCase { value: "closed", title: t("HistoryActions", "argument.history.kind.closed", "Closed Items") }, EnumCase { value: "agent", title: t("HistoryActions", "argument.history.kind.agent", "Agent Sessions") }, EnumCase { value: "command", title: t("HistoryActions", "argument.history.kind.command", "Commands") }];
#[rustfmt::skip]
pub const CASES_HOME_SETTINGS: &[EnumCase] = &[EnumCase { value: "home", title: t("SidebarSectionActions", "argument.sidebar.builtin.home", "Home") }, EnumCase { value: "settings", title: t("SidebarSectionActions", "argument.sidebar.builtin.settings", "Settings") }, EnumCase { value: "account", title: t("SidebarSectionActions", "argument.sidebar.builtin.account", "Account") }, EnumCase { value: "notifications", title: t("SidebarSectionActions", "argument.sidebar.builtin.notifications", "Notifications") }, EnumCase { value: "history", title: t("SidebarSectionActions", "argument.sidebar.builtin.history", "History") }, EnumCase { value: "bookmarks", title: t("SidebarSectionActions", "argument.sidebar.builtin.bookmarks", "Bookmarks") }, EnumCase { value: "app_store", title: t("SidebarSectionActions", "argument.sidebar.builtin.appStore", "App Store") }, EnumCase { value: "new_terminal", title: t("SidebarSectionActions", "argument.sidebar.builtin.newTerminal", "New Terminal Tab") }, EnumCase { value: "new_browser", title: t("SidebarSectionActions", "argument.sidebar.builtin.newBrowser", "New Browser Tab") }, EnumCase { value: "new_agent_chat", title: t("SidebarSectionActions", "argument.sidebar.builtin.newAgentChat", "New Agent Chat") }, EnumCase { value: "search_chats", title: t("SidebarSectionActions", "argument.sidebar.builtin.searchChats", "Search Chats") }, EnumCase { value: "chief", title: t("SidebarSectionActions", "argument.sidebar.builtin.chief", "Chief") }, EnumCase { value: "automations", title: t("SidebarSectionActions", "argument.sidebar.builtin.automations", "Automations") }, EnumCase { value: "customize", title: t("SidebarSectionActions", "argument.sidebar.builtin.customize", "Customize Appearance") }];
#[rustfmt::skip]
pub const CASES_TOP_MIDDLE: &[EnumCase] = &[EnumCase { value: "top", title: t("SidebarSectionActions", "argument.sidebar.region.top", "Top") }, EnumCase { value: "middle", title: t("SidebarSectionActions", "argument.sidebar.region.middle", "Scrolling") }, EnumCase { value: "bottom", title: t("SidebarSectionActions", "argument.sidebar.region.bottom", "Bottom") }];
#[rustfmt::skip]
pub const CASES_LEADING_CENTER: &[EnumCase] = &[EnumCase { value: "leading", title: t("SidebarSectionActions", "argument.sidebar.align.leading", "Leading") }, EnumCase { value: "center", title: t("SidebarSectionActions", "argument.sidebar.align.center", "Center") }, EnumCase { value: "trailing", title: t("SidebarSectionActions", "argument.sidebar.align.trailing", "Trailing") }, EnumCase { value: "fill", title: t("SidebarSectionActions", "argument.sidebar.align.fill", "Spread Out") }];
#[rustfmt::skip]
pub const CASES_HOME_LOCK: &[EnumCase] = &[EnumCase { value: "home", title: t("PhoneActions", "argument.phone.button.home", "Home") }, EnumCase { value: "lock", title: t("PhoneActions", "argument.phone.button.lock", "Lock") }, EnumCase { value: "volume-up", title: t("PhoneActions", "argument.phone.button.volumeUp", "Volume Up") }, EnumCase { value: "volume-down", title: t("PhoneActions", "argument.phone.button.volumeDown", "Volume Down") }, EnumCase { value: "siri", title: t("PhoneActions", "argument.phone.button.siri", "Siri or Assistant") }, EnumCase { value: "back", title: t("PhoneActions", "argument.phone.button.back", "Back") }, EnumCase { value: "app-switch", title: t("PhoneActions", "argument.phone.button.appSwitch", "App Switcher") }];
#[rustfmt::skip]
pub const CASES_LIGHT_DARK: &[EnumCase] = &[EnumCase { value: "light", title: t("PhoneActions", "argument.phone.appearance.light", "Light") }, EnumCase { value: "dark", title: t("PhoneActions", "argument.phone.appearance.dark", "Dark") }];

#[rustfmt::skip]
pub const SECTION: Argument = Argument { name: "section", title: t("SettingsActions", "argument.section", "Section"), kind: ArgKind::Enumeration(CASES_GENERAL_APPEARANCE), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SETTING: Argument = Argument { name: "setting", title: t("Localizable", "argument.setting", "Setting"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const OUT: Argument = Argument { name: "out", title: t("Localizable", "argument.out", "Output File"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KEEP_SESSIONS: Argument = Argument { name: "keepSessions", title: t("Localizable", "argument.keepSessions", "Keep Sessions Running"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const END_SESSIONS: Argument = Argument { name: "endSessions", title: t("Localizable", "argument.endSessionsKeepLayout", "End Sessions, Keep Layout"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const END_EVERYTHING: Argument = Argument { name: "endEverything", title: t("Localizable", "argument.endEverything", "End Everything"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEXT: Argument = Argument { name: "text", title: t("Localizable", "argument.text", "Text"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SCOPE: Argument = Argument { name: "scope", title: t("Localizable", "argument.scope", "Scope"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const QUERY: Argument = Argument { name: "query", title: t("Localizable", "argument.query", "Search"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WORKSPACE: Argument = Argument { name: "workspace", title: t("Localizable", "argument.workspace", "Workspace"), kind: ArgKind::Target("workspace"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROCESS: Argument = Argument { name: "process", title: t("Localizable", "argument.process", "Process"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CONFIRM: Argument = Argument { name: "confirm", title: t("Localizable", "argument.confirm", "Confirm"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME: Argument = Argument { name: "name", title: t("Localizable", "argument.name", "Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CWD: Argument = Argument { name: "cwd", title: t("Localizable", "argument.cwd", "Working Directory"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COMMAND: Argument = Argument { name: "command", title: t("Localizable", "argument.command", "Command"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ENV: Argument = Argument { name: "env", title: t("Localizable", "argument.env", "Environment (JSON)"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FOCUS: Argument = Argument { name: "focus", title: t("Localizable", "argument.focus", "Focus"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KEEP: Argument = Argument { name: "keep", title: t("Localizable", "argument.keep", "Keep After Close"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const INDEX: Argument = Argument { name: "index", title: t("Localizable", "argument.index", "Number"), kind: ArgKind::Int(Some((1, 9))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WINDOW: Argument = Argument { name: "window", title: t("Localizable", "argument.window", "Window"), kind: ArgKind::Target("window"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_2: Argument = Argument { name: "name", title: t("Localizable", "argument.name", "Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: true, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DESCRIPTION: Argument = Argument { name: "description", title: t("Localizable", "argument.description", "Description"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: true, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const STATUS: Argument = Argument { name: "status", title: t("Localizable", "argument.status", "Status"), kind: ArgKind::Enumeration(CASES_AUTO_TODO), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ITEM: Argument = Argument { name: "item", title: t("Localizable", "argument.checklistItem", "Checklist Item"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PINNED: Argument = Argument { name: "pinned", title: t("Localizable", "argument.pinned", "Pinned"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COLOR: Argument = Argument { name: "color", title: t("Localizable", "argument.color", "Color"), kind: ArgKind::Enumeration(CASES_GREY_BLUE), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const GROUP: Argument = Argument { name: "group", title: t("Localizable", "argument.group", "Group"), kind: ArgKind::Target("workspace-group"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEMPLATE: Argument = Argument { name: "template", title: t("Localizable", "argument.template", "Template"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "layoutTemplates", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MACHINE: Argument = Argument { name: "machine", title: t("WorkspaceActions", "argument.machine", "Machine"), kind: ArgKind::Target("machine"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ICON: Argument = Argument { name: "icon", title: t("ProfileActions", "argument.icon", "Icon"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ANCHOR: Argument = Argument { name: "anchor", title: t("WorkspaceActions", "argument.anchor", "Next to Workspace"), kind: ArgKind::Target("workspace"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const INTO: Argument = Argument { name: "into", title: t("WorkspaceActions", "argument.into", "Into Workspace"), kind: ArgKind::Target("workspace"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SECTION_2: Argument = Argument { name: "section", title: t("Localizable", "argument.workspaceGroup.section", "Section"), kind: ArgKind::Target("sidebar-section"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SORT: Argument = Argument { name: "sort", title: t("WorkspaceActions", "argument.workspaceGroup.sort", "Sort Order"), kind: ArgKind::Enumeration(CASES_MANUAL_NAME), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SPACE: Argument = Argument { name: "space", title: t("ProfileActions", "argument.room", "Space"), kind: ArgKind::Target("room"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: true, asked_in_palette: false };
#[rustfmt::skip]
pub const MOVE_TO: Argument = Argument { name: "moveTo", title: t("ProfileActions", "argument.moveTo", "Move Workspaces To"), kind: ArgKind::Target("room"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const INDEX_2: Argument = Argument { name: "index", title: t("ProfileActions", "argument.position", "Position"), kind: ArgKind::Int(Some((1, 99))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SPACE_2: Argument = Argument { name: "space", title: t("ProfileActions", "argument.room", "Space"), kind: ArgKind::Target("room"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const THEME: Argument = Argument { name: "theme", title: t("ThemeActions", "argument.theme", "Theme"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "ghosttyThemes", pinned: CASES_CONFIG_ROSE_PINE, other_title: Some(t("ThemeActions", "argument.value.theme.pair", "Light and Dark Pair…")), allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PANE: Argument = Argument { name: "pane", title: t("Localizable", "argument.pane", "Pane"), kind: ArgKind::Target("pane"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PATH: Argument = Argument { name: "path", title: t("Localizable", "argument.path", "Path"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WHERE: Argument = Argument { name: "where", title: t("Localizable", "argument.where", "Open In"), kind: ArgKind::Enumeration(CASES_TAB_EDITOR), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const AS_TEXT: Argument = Argument { name: "asText", title: t("ActionCatalog", "argument.asText", "As Text"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEXT_2: Argument = Argument { name: "text", title: t("NewTabActions", "argument.newTab.text", "Text"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SEARCH: Argument = Argument { name: "search", title: t("NewTabActions", "argument.newTab.search", "Search the Web"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const AGENT: Argument = Argument { name: "agent", title: t("NewTabActions", "argument.newTab.agent", "Agent"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const URL: Argument = Argument { name: "url", title: t("Localizable", "argument.url", "URL"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ENGINE: Argument = Argument { name: "engine", title: t("Localizable", "argument.engine", "Engine"), kind: ArgKind::Enumeration(CASES_WEBKIT_CEF), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROFILE: Argument = Argument { name: "profile", title: t("Localizable", "argument.browserProfile", "Browser Profile"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const VIEW: Argument = Argument { name: "view", title: t("HomeActions", "argument.home.view", "View"), kind: ArgKind::Enumeration(CASES_MESSAGES_CHANNELS), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PATH_2: Argument = Argument { name: "path", title: t("HomeActions", "argument.home.attach.path", "File Path"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TO: Argument = Argument { name: "to", title: t("HomeActions", "argument.home.message.to", "Person or Email Address"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TITLE: Argument = Argument { name: "title", title: t("HomeActions", "argument.home.message.title", "Group Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EMAIL: Argument = Argument { name: "email", title: t("HomeActions", "argument.home.invite.email", "Email Address"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_3: Argument = Argument { name: "name", title: t("HomeActions", "argument.home.chief.name", "Chief Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HARNESS: Argument = Argument { name: "harness", title: Text::raw("Harness"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ENGINE_2: Argument = Argument { name: "engine", title: Text::raw("Engine"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CHIEF: Argument = Argument { name: "chief", title: t("HomeActions", "argument.home.chief.id", "Chief"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "homeChiefs", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CONVERSATION: Argument = Argument { name: "conversation", title: t("HomeActions", "argument.home.conversation", "Conversation"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PEOPLE: Argument = Argument { name: "people", title: t("HomeActions", "argument.home.groupMembers", "Members"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "homeMembers", pinned: &[], other_title: None, allows_multiple: true }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PERSON: Argument = Argument { name: "person", title: t("HomeActions", "argument.home.person", "Person"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MEMBERS: Argument = Argument { name: "members", title: t("HomeActions", "argument.home.groupMembers", "Members"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "homeMembers", pinned: &[], other_title: None, allows_multiple: true }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REPLIES: Argument = Argument { name: "replies", title: t("HomeActions", "argument.home.replies", "Chiefs Reply"), kind: ArgKind::Enumeration(CASES_AUTO_MENTIONS), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TITLE_2: Argument = Argument { name: "title", title: t("HomeActions", "argument.home.channelTitle", "Channel Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CHIEF_2: Argument = Argument { name: "chief", title: t("HomeActions", "argument.home.channelChief", "Chief Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PINNED_2: Argument = Argument { name: "pinned", title: t("HomeActions", "argument.home.pinned", "Pinned"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SENT: Argument = Argument { name: "sent", title: t("HomeActions", "argument.home.chatColors.sent", "My Bubble Color"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SENT_TEXT: Argument = Argument { name: "sentText", title: t("HomeActions", "argument.home.chatColors.sentText", "My Text Color"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const RECEIVED: Argument = Argument { name: "received", title: t("HomeActions", "argument.home.chatColors.received", "Their Bubble Color"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const RECEIVED_TEXT: Argument = Argument { name: "receivedText", title: t("HomeActions", "argument.home.chatColors.receivedText", "Their Text Color"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const RESET: Argument = Argument { name: "reset", title: t("HomeActions", "argument.home.chatColors.reset", "Reset to Default"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEXT_3: Argument = Argument { name: "text", title: t("HomeActions", "argument.home.send.text", "Message"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const STYLE: Argument = Argument { name: "style", title: t("HomeActions", "argument.home.playgroundStyle", "Header Style"), kind: ArgKind::Int(Some((0, 32))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EXPANDED: Argument = Argument { name: "expanded", title: t("HomeActions", "argument.home.playgroundExpanded", "Expanded"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEAM: Argument = Argument { name: "team", title: t("HomeActions", "argument.home.playgroundTeam", "Team Chat"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PEER: Argument = Argument { name: "peer", title: t("HomeActions", "argument.home.playgroundPeer", "Agent"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DARK: Argument = Argument { name: "dark", title: t("HomeActions", "argument.home.playgroundDark", "Dark Look"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const STYLE_2: Argument = Argument { name: "style", title: t("HomeActions", "argument.home.mcpPlaygroundStyle", "Card Style"), kind: ArgKind::Int(Some((1, 6))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FIXTURE: Argument = Argument { name: "fixture", title: t("HomeActions", "argument.home.mcpPlaygroundServer", "Server"), kind: ArgKind::Int(Some((0, 5))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PHASE: Argument = Argument { name: "phase", title: t("HomeActions", "argument.home.mcpPlaygroundPhase", "Phase"), kind: ArgKind::Int(Some((0, 6))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const VARIANT: Argument = Argument { name: "variant", title: t("HomeActions", "argument.home.comparePlaygroundVariant", "Variant"), kind: ArgKind::Int(Some((1, 7))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ROW: Argument = Argument { name: "row", title: t("HomeActions", "argument.home.comparePlaygroundRow", "Picture Set"), kind: ArgKind::Int(Some((0, 1))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const STATE: Argument = Argument { name: "state", title: t("HomeActions", "argument.home.teleportPlaygroundState", "Menu State"), kind: ArgKind::Int(Some((0, 9))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TO_2: Argument = Argument { name: "to", title: t("HomeActions", "argument.home.messageTo.to", "To"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "homeRecipients", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEXT_4: Argument = Argument { name: "text", title: t("HomeActions", "argument.home.messageTo.text", "Message"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEXT_5: Argument = Argument { name: "text", title: t("HomeActions", "argument.home.selection.text", "Text"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TABS: Argument = Argument { name: "tabs", title: t("Localizable", "argument.tabs", "Tabs"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const GROUP_2: Argument = Argument { name: "group", title: t("Localizable", "argument.group", "Group"), kind: ArgKind::Target("tab-group"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DIRECTION: Argument = Argument { name: "direction", title: t("Localizable", "argument.direction", "Direction"), kind: ArgKind::Enumeration(CASES_RIGHT_DOWN), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const GROUP_3: Argument = Argument { name: "group", title: t("Localizable", "argument.group", "Group"), kind: ArgKind::Target("screen-group"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SAVED: Argument = Argument { name: "saved", title: t("ScreenActions", "argument.savedGroup", "Saved Group"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ON: Argument = Argument { name: "on", title: t("Localizable", "argument.on", "On"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const APP: Argument = Argument { name: "app", title: t("Localizable", "argument.app", "App"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const RANGE: Argument = Argument { name: "range", title: t("HistoryActions", "argument.history.range", "Time Range"), kind: ArgKind::Enumeration(CASES_HOUR_TODAY), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BROWSER_PROFILE: Argument = Argument { name: "browserProfile", title: t("BrowserProfileActions", "argument.browserProfile", "Browser Profile"), kind: ArgKind::Target("browser-profile"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const URL_2: Argument = Argument { name: "url", title: t("Localizable", "argument.link.url", "Link"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const THEME_2: Argument = Argument { name: "theme", title: t("Localizable", "argument.theme", "Theme"), kind: ArgKind::Enumeration(CASES_SYSTEM_LIGHT), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DEVICE: Argument = Argument { name: "device", title: t("Localizable", "argument.device", "Device"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ORIENTATION: Argument = Argument { name: "orientation", title: t("Localizable", "argument.orientation", "Orientation"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FIT: Argument = Argument { name: "fit", title: t("Localizable", "argument.fit", "Aspect Ratio or Width"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "browserFit", pinned: CASES_16_9_16_10, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FROM: Argument = Argument { name: "from", title: t("ActionCatalog", "argument.browser.importCookies.from", "From Browser"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DOMAIN: Argument = Argument { name: "domain", title: t("ActionCatalog", "argument.browser.importCookies.domain", "Sites"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REASON: Argument = Argument { name: "reason", title: t("ActionCatalog", "argument.browser.importCookies.reason", "Reason"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROFILE_2: Argument = Argument { name: "profile", title: t("ActionCatalog", "argument.browser.importCookies.profile", "Into Browser Profile"), kind: ArgKind::Target("browser-profile"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const URL_3: Argument = Argument { name: "url", title: t("Localizable", "argument.browser.imageURL", "Image Address"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DOMAIN_2: Argument = Argument { name: "domain", title: t("PageInfoActions", "argument.domain", "Site"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PERMISSION: Argument = Argument { name: "permission", title: t("PageInfoActions", "argument.permission", "Permission"), kind: ArgKind::Enumeration(CASES_LOCATION_CAMERA), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SETTING_2: Argument = Argument { name: "setting", title: t("PageInfoActions", "argument.setting", "Setting"), kind: ArgKind::Enumeration(CASES_ASK_ALLOW), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PATH_3: Argument = Argument { name: "path", title: t("Extensions", "argument.extensionPath", "Folder"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EXTENSION: Argument = Argument { name: "extension", title: t("Extensions", "argument.extension", "Extension"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const INDEX_3: Argument = Argument { name: "index", title: t("Extensions", "argument.extensionIndex", "Position"), kind: ArgKind::Int(Some((0, 63))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COMMAND_2: Argument = Argument { name: "command", title: t("Extensions", "argument.extensionCommand", "Shortcut"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HISTORY: Argument = Argument { name: "history", title: t("BrowserProfileActions", "argument.browsingData.history", "Browsing History"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COOKIES: Argument = Argument { name: "cookies", title: t("BrowserProfileActions", "argument.browsingData.cookies", "Cookies and Site Data"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CACHE: Argument = Argument { name: "cache", title: t("BrowserProfileActions", "argument.browsingData.cache", "Cached Images and Files"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SOUND: Argument = Argument { name: "sound", title: t("Localizable", "argument.notifications.sound", "Sound"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "notificationSounds", pinned: CASES_INHERIT_NONE, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EVENT: Argument = Argument { name: "event", title: t("Localizable", "argument.notifications.event", "Event"), kind: ArgKind::Enumeration(CASES_ALL_FINISHED), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const VOLUME: Argument = Argument { name: "volume", title: t("Localizable", "argument.notifications.volume", "Volume (%)"), kind: ArgKind::Int(Some((0, 100))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FILE: Argument = Argument { name: "file", title: t("Localizable", "argument.notifications.file", "Sound File"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const AGENT_2: Argument = Argument { name: "agent", title: t("Localizable", "argument.notifications.agent", "Agent"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "notificationAgents", pinned: CASES_CLAUDE_CODEX, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EVENT_2: Argument = Argument { name: "event", title: t("Localizable", "argument.notifications.event", "Event"), kind: ArgKind::Enumeration(CASES_FINISHED_NEEDS_INPUT), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CWD_2: Argument = Argument { name: "cwd", title: t("Localizable", "argument.agent.cwd", "Folder"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HARNESS_2: Argument = Argument { name: "harness", title: t("ActionCatalog", "argument.agent.harness", "Harness"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MODEL: Argument = Argument { name: "model", title: t("ActionCatalog", "argument.agent.model", "Model"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HOST: Argument = Argument { name: "host", title: t("Localizable", "argument.agent.host", "Session Host"), kind: ArgKind::Target("machine"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SESSION: Argument = Argument { name: "session", title: t("Localizable", "argument.agent.session", "Session"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_4: Argument = Argument { name: "name", title: t("Localizable", "argument.agent.workspaceName", "Workspace Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DEFAULT_NAME: Argument = Argument { name: "defaultName", title: t("Localizable", "argument.agent.workspaceDefaultName", "Default Workspace Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KEY: Argument = Argument { name: "key", title: t("Localizable", "argument.agent.workspaceKey", "Workspace Key"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HOST_2: Argument = Argument { name: "host", title: t("Localizable", "argument.agent.host", "Session Host"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const GROUP_4: Argument = Argument { name: "group", title: t("Localizable", "argument.group", "Group"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PLACEMENT: Argument = Argument { name: "placement", title: t("Localizable", "argument.agent.placement", "Placement"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TARGET: Argument = Argument { name: "target", title: t("RemoteActions", "argument.chiefMoveTarget", "Target"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "chiefMoveTargets", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CHIEF_3: Argument = Argument { name: "chief", title: t("Localizable", "argument.chiefImportChief", "Cloud Chief"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SOURCE: Argument = Argument { name: "source", title: t("Localizable", "argument.chiefImportSource", "Source"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ENTRY: Argument = Argument { name: "entry", title: t("ActionCatalog", "argument.gallery.entry", "Entry"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const VARIANT_2: Argument = Argument { name: "variant", title: t("ActionCatalog", "argument.gallery.variant", "Variant"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MODEL_2: Argument = Argument { name: "model", title: t("AgentConfigurationActions", "argument.agentPane.model", "Model"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "agentModels", pinned: &[], other_title: Some(t("AgentConfigurationActions", "argument.agentPane.model.other", "Enter Model ID…")), allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EFFORT: Argument = Argument { name: "effort", title: t("AgentConfigurationActions", "argument.agentPane.effort", "Effort"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "agentEfforts", pinned: &[], other_title: Some(t("AgentConfigurationActions", "argument.agentPane.effort.other", "Enter Effort…")), allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MODE: Argument = Argument { name: "mode", title: t("AgentConfigurationActions", "argument.agentPane.mode", "Mode"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "agentModes", pinned: &[], other_title: Some(t("AgentConfigurationActions", "argument.agentPane.mode.other", "Enter Mode…")), allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SURFACE: Argument = Argument { name: "surface", title: t("ActionCatalog", "argument.agentShare.surface", "Surface"), kind: ArgKind::Int(Some((1, 2147483647))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TTL: Argument = Argument { name: "ttl", title: t("ActionCatalog", "argument.agentShare.ttl", "Expires After"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const USES: Argument = Argument { name: "uses", title: t("ActionCatalog", "argument.agentShare.uses", "Uses"), kind: ArgKind::Int(Some((1, 8))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SHARE_ID: Argument = Argument { name: "shareId", title: t("ActionCatalog", "argument.agentShare.shareId", "Share ID"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const GUEST_ID: Argument = Argument { name: "guestId", title: t("ActionCatalog", "argument.agentShare.guestId", "Guest ID"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ACCOUNT: Argument = Argument { name: "account", title: t("ActionCatalog", "argument.agentShare.account", "Email or @handle"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ROLE: Argument = Argument { name: "role", title: t("ActionCatalog", "argument.agentShare.role", "Access"), kind: ArgKind::Enumeration(CASES_TALK_VIEW), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SIGNED_IN_ROLE: Argument = Argument { name: "signedInRole", title: t("ActionCatalog", "argument.agentShare.signedInRole", "Signed-in Guests"), kind: ArgKind::Enumeration(CASES_TALK_VIEW), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KEY_2: Argument = Argument { name: "key", title: t("ActionCatalog", "argument.agentChat.key", "Chat"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COMMAND_3: Argument = Argument { name: "command", title: t("ActionCatalog", "argument.agent.harness.command", "Command"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ARGS: Argument = Argument { name: "args", title: t("ActionCatalog", "argument.agent.harness.args", "Arguments"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REGISTRY: Argument = Argument { name: "registry", title: t("ActionCatalog", "argument.agent.harness.registry", "Registry Agent"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EXAMPLE: Argument = Argument { name: "example", title: t("ActionCatalog", "argument.agent.harness.example", "Example"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ID: Argument = Argument { name: "id", title: t("ActionCatalog", "argument.agent.harness.id", "Agent"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_5: Argument = Argument { name: "name", title: t("ActionCatalog", "argument.agent.harness.name", "Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROTOCOL: Argument = Argument { name: "protocol", title: t("ActionCatalog", "argument.agent.harness.protocol", "Protocol"), kind: ArgKind::Enumeration(CASES_ACP_TERMINAL), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REPLACE: Argument = Argument { name: "replace", title: t("ActionCatalog", "argument.agent.harness.replace", "Replace"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BACKUP: Argument = Argument { name: "backup", title: t("ActionCatalog", "argument.agent.harness.backup", "Backup"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const INTENT: Argument = Argument { name: "intent", title: t("ActionCatalog", "argument.agent.harness.intent", "Update intent"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SIZE: Argument = Argument { name: "size", title: t("Localizable", "argument.size", "Size"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PERSISTENT: Argument = Argument { name: "persistent", title: t("Localizable", "argument.persistent", "Persistent"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BOOTSTRAP: Argument = Argument { name: "bootstrap", title: t("Localizable", "argument.bootstrap", "Bootstrap"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BOOTSTRAP_SCRIPT: Argument = Argument { name: "bootstrapScript", title: t("Localizable", "argument.bootstrapScript", "Bootstrap Script"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MACHINE_CONFIG: Argument = Argument { name: "machineConfig", title: t("Localizable", "argument.machineConfig", "Machine Config"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REPO: Argument = Argument { name: "repo", title: t("Localizable", "argument.repo", "Repository"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ENVIRONMENT: Argument = Argument { name: "environment", title: t("Localizable", "argument.environment", "Cloud Environment"), kind: ArgKind::String, required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SNAPSHOT: Argument = Argument { name: "snapshot", title: t("Localizable", "argument.snapshot", "Snapshot"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CONTENTS: Argument = Argument { name: "contents", title: t("Localizable", "argument.contents", "Contents"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PUBLIC_KEY: Argument = Argument { name: "publicKey", title: t("Localizable", "argument.publicKey", "SSH Public Key"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PORT: Argument = Argument { name: "port", title: t("Localizable", "argument.port", "Port"), kind: ArgKind::Int(Some((1, 65535))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KEY_3: Argument = Argument { name: "key", title: t("Localizable", "argument.apiKey", "API Key"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WORKSPACE_2: Argument = Argument { name: "workspace", title: t("Localizable", "argument.workspace", "Workspace"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const VIEWER: Argument = Argument { name: "viewer", title: t("Localizable", "argument.viewer", "Viewer"), kind: ArgKind::Enumeration(CASES_RD), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SIZE_2: Argument = Argument { name: "size", title: t("Localizable", "argument.size", "Size"), kind: ArgKind::Enumeration(CASES_SMALL_MEDIUM), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DISK: Argument = Argument { name: "disk", title: t("Localizable", "argument.diskGiB", "Disk (GiB)"), kind: ArgKind::Int(Some((4, 256))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REPO_2: Argument = Argument { name: "repo", title: t("Localizable", "argument.secretRepo", "Repository"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAMES: Argument = Argument { name: "names", title: t("Localizable", "argument.secretNames", "Secret Names"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MINUTES: Argument = Argument { name: "minutes", title: t("Localizable", "argument.idlePause", "Pause When Idle"), kind: ArgKind::Enumeration(CASES_OFF_15), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ACCESS: Argument = Argument { name: "access", title: t("Localizable", "argument.networkAccess", "Internet Access"), kind: ArgKind::Enumeration(CASES_FULL_TRUSTED), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEAM_2: Argument = Argument { name: "team", title: t("Localizable", "argument.team", "Team"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "cloudTeams", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LINK_ID: Argument = Argument { name: "linkId", title: t("CloudPortActions", "argument.linkID", "Link ID"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROVIDER: Argument = Argument { name: "provider", title: t("AccountsActions", "argument.provider", "Provider"), kind: ArgKind::Enumeration(CASES_CODEX_OPENAI), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROVIDER_2: Argument = Argument { name: "provider", title: t("AccountsActions", "argument.provider", "Provider"), kind: ArgKind::Enumeration(CASES_CODEX_OPENAI_2), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ACCOUNT_2: Argument = Argument { name: "account", title: t("AccountsActions", "argument.account", "Account ID"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DESTINATION: Argument = Argument { name: "destination", title: t("RemoteActions", "argument.destination", "SSH Destination"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SESSION_2: Argument = Argument { name: "session", title: t("RemoteActions", "argument.session", "Session"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BINARY: Argument = Argument { name: "binary", title: t("RemoteActions", "argument.binary", "cmux-tui Path"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const STATE_DIR: Argument = Argument { name: "stateDir", title: t("RemoteActions", "argument.stateDir", "State Directory"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WAY: Argument = Argument { name: "way", title: t("RemoteActions", "argument.addDeviceWay", "Way"), kind: ArgKind::Enumeration(CASES_NETWORK_CODE), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DESTINATION_2: Argument = Argument { name: "destination", title: t("RemoteActions", "argument.destination", "SSH Destination"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "remoteHosts", pinned: &[], other_title: Some(t("RemoteActions", "argument.remoteGroup.host.other", "Enter Host…")), allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HOST_3: Argument = Argument { name: "host", title: t("WorkspaceActions", "argument.machine", "Machine"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SPLIT: Argument = Argument { name: "split", title: t("Localizable", "argument.direction", "Direction"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CMD: Argument = Argument { name: "cmd", title: t("Localizable", "argument.command", "Command"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LABEL: Argument = Argument { name: "label", title: t("Localizable", "argument.name", "Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ATTACH: Argument = Argument { name: "attach", title: t("Localizable", "argument.attach", "Attach To"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const RATIO: Argument = Argument { name: "ratio", title: t("Localizable", "argument.ratio", "Size Ratio"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LOCALHOST: Argument = Argument { name: "localhost", title: t("RemoteActions", "argument.remoteLocalhost", "Localhost Target"), kind: ArgKind::Enumeration(CASES_MACHINE_THIS_MAC), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ADDRESS: Argument = Argument { name: "address", title: t("RemoteActions", "argument.remote.hostAddress", "Host Address"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SECRET_FILE: Argument = Argument { name: "secretFile", title: t("RemoteActions", "argument.remote.secretFile", "Host Secret File"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const AGENT_3: Argument = Argument { name: "agent", title: t("CloudSessionActions", "argument.cloudStartSession.agent", "Agent"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_6: Argument = Argument { name: "name", title: t("CloudSessionActions", "argument.cloudStartSession.name", "Machine Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CWD_3: Argument = Argument { name: "cwd", title: t("CloudSessionActions", "argument.cloudStartSession.cwd", "Folder on the Machine"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LOGIN: Argument = Argument { name: "login", title: t("CloudSessionActions", "argument.cloudStartSession.login", "Harness Login"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FROM_FOLDER: Argument = Argument { name: "fromFolder", title: t("CloudSessionActions", "argument.cloudStartSession.fromFolder", "Folder on This Mac to Copy"), kind: ArgKind::String, required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KEYMAP: Argument = Argument { name: "keymap", title: t("Localizable", "argument.keymap", "Keymap"), kind: ArgKind::Enumeration(CASES_CMUX_ITERM2), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REPLACE_2: Argument = Argument { name: "replace", title: t("Localizable", "argument.installCLI.replace", "Replace Another App's cmux"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CMUX_NEXT: Argument = Argument { name: "cmuxNext", title: t("Localizable", "argument.installCLI.cmuxNext", "Install as cmux-next"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CHANNEL: Argument = Argument { name: "channel", title: t("Localizable", "argument.channel", "Channel"), kind: ArgKind::Enumeration(CASES_STABLE_NIGHTLY), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TOPIC: Argument = Argument { name: "topic", title: t("Localizable", "argument.topic", "Topic"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SERVER: Argument = Argument { name: "server", title: t("ActionCatalog", "argument.projection.server", "Server"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WORKTREE: Argument = Argument { name: "worktree", title: t("ActionCatalog", "argument.projection.worktree", "Worktree"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEST: Argument = Argument { name: "test", title: t("ActionCatalog", "argument.projection.test", "Test Command"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PAGE: Argument = Argument { name: "page", title: t("ActionCatalog", "argument.projection.page", "Page"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DENSITY: Argument = Argument { name: "density", title: t("SettingsActions", "argument.density", "Density"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "densities", pinned: CASES_ULTRA_COMPACT_COMPACT, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_7: Argument = Argument { name: "name", title: t("SettingsActions", "argument.density.name", "Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BASED_ON: Argument = Argument { name: "basedOn", title: t("SettingsActions", "argument.density.basedOn", "Based On"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "densities", pinned: CASES_ULTRA_COMPACT_COMPACT, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FONT_SIZE: Argument = Argument { name: "fontSize", title: t("SettingsActions", "argument.density.fontSize", "Text Size"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BACKGROUND: Argument = Argument { name: "background", title: t("LayoutActions", "argument.paneBackground", "Background"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "paneBackgrounds", pinned: CASES_INHERIT_NONE_2, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COLOR_2: Argument = Argument { name: "color", title: t("LayoutActions", "argument.paneTint", "Tint"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "paneTints", pinned: CASES_NONE_RED, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SCOPE_2: Argument = Argument { name: "scope", title: t("LayoutActions", "argument.appearanceScope", "Scope"), kind: ArgKind::Enumeration(CASES_WINDOW_WORKSPACE), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROPERTY: Argument = Argument { name: "property", title: t("LayoutActions", "argument.appearanceProperty", "Property"), kind: ArgKind::Enumeration(CASES_THEME_BACKGROUND), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const VALUE: Argument = Argument { name: "value", title: t("LayoutActions", "argument.appearanceValue", "Value"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KIND_2: Argument = Argument { name: "kind", title: t("LayoutActions", "argument.dividerInsertKind", "Kind"), kind: ArgKind::Enumeration(CASES_TERMINAL_BROWSER), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SPLIT_2: Argument = Argument { name: "split", title: t("LayoutActions", "argument.dividerSplit", "Divider"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ITEM_2: Argument = Argument { name: "item", title: t("WorkspaceActions", "argument.autoArchive.item", "Archived Workspace"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "archivedWorkspaces", pinned: CASES_ALL, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const AFTER: Argument = Argument { name: "after", title: t("WorkspaceActions", "argument.autoArchive.after", "Archive Members"), kind: ArgKind::Enumeration(CASES_DEFAULT_NEVER), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DAYS: Argument = Argument { name: "days", title: t("WorkspaceActions", "argument.autoArchive.days", "Days"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const EDGE: Argument = Argument { name: "edge", title: t("Localizable", "argument.edge", "Edge"), kind: ArgKind::Enumeration(CASES_RIGHT_LEFT), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const MODE_2: Argument = Argument { name: "mode", title: t("Localizable", "argument.dockMode", "Mode"), kind: ArgKind::Enumeration(CASES_DOCKED_OVERLAY), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SESSION_3: Argument = Argument { name: "session", title: t("HistoryActions", "argument.history.session", "Session ID"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ID_2: Argument = Argument { name: "id", title: t("HistoryActions", "argument.history.closedItem", "Closed Item ID"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const INDEX_4: Argument = Argument { name: "index", title: t("HistoryActions", "argument.history.trailIndex", "Trail Index"), kind: ArgKind::Int(Some((0, 10000))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ID_3: Argument = Argument { name: "id", title: t("HistoryActions", "argument.history.entry", "History Entry ID"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NEW_TAB: Argument = Argument { name: "newTab", title: t("HistoryActions", "argument.history.newTab", "In New Tab"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const KIND: Argument = Argument { name: "kind", title: t("HistoryActions", "argument.history.kind", "Kind"), kind: ArgKind::Enumeration(CASES_ALL_PAGE), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_8: Argument = Argument { name: "name", title: t("BookmarkActions", "argument.bookmark.folderName", "Folder Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const URL_4: Argument = Argument { name: "url", title: t("BookmarkActions", "argument.bookmark.url", "URL"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TITLE_3: Argument = Argument { name: "title", title: t("BookmarkActions", "argument.bookmark.title", "Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FOLDER: Argument = Argument { name: "folder", title: t("BookmarkActions", "argument.bookmark.folder", "Folder"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PROFILE_3: Argument = Argument { name: "profile", title: t("BookmarkActions", "argument.bookmark.profile", "Browser Profile"), kind: ArgKind::Target("browser-profile"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BOOKMARK: Argument = Argument { name: "bookmark", title: t("BookmarkActions", "argument.bookmark.bookmark", "Bookmark"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const INDEX_5: Argument = Argument { name: "index", title: t("BookmarkActions", "argument.bookmark.index", "Position"), kind: ArgKind::Int(Some((0, 100000))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PATH_4: Argument = Argument { name: "path", title: t("BookmarkActions", "argument.bookmark.path", "File"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BROWSER: Argument = Argument { name: "browser", title: t("BookmarkActions", "argument.bookmark.browser", "Browser"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SOURCE_2: Argument = Argument { name: "source", title: t("BookmarkActions", "argument.bookmark.sourceProfile", "Profile to Import"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ITEM_3: Argument = Argument { name: "item", title: t("SidebarSectionActions", "argument.sidebar.item", "Item"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "sidebarItems", pinned: CASES_HOME_SETTINGS, other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SECTION_3: Argument = Argument { name: "section", title: t("SidebarSectionActions", "argument.sidebar.section", "Section"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TITLE_4: Argument = Argument { name: "title", title: t("SidebarSectionActions", "argument.sidebar.title", "Title"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REGION: Argument = Argument { name: "region", title: t("SidebarSectionActions", "argument.sidebar.region", "Place"), kind: ArgKind::Enumeration(CASES_TOP_MIDDLE), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TITLE_5: Argument = Argument { name: "title", title: t("SidebarSectionActions", "argument.sidebar.title", "Title"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: true, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ALIGN: Argument = Argument { name: "align", title: t("SidebarSectionActions", "argument.sidebar.align", "Alignment"), kind: ArgKind::Enumeration(CASES_LEADING_CENTER), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const GAP: Argument = Argument { name: "gap", title: t("SidebarSectionActions", "argument.sidebar.gap", "Spacing (points)"), kind: ArgKind::Int(Some((0, 32))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COLUMNS: Argument = Argument { name: "columns", title: t("SidebarSectionActions", "argument.sidebar.columns", "Columns (0 = as many as fit)"), kind: ArgKind::Int(Some((0, 12))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ROWS: Argument = Argument { name: "rows", title: t("SidebarSectionActions", "argument.sidebar.rows", "Rows (0 = automatic)"), kind: ArgKind::Int(Some((0, 50))), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CHAT: Argument = Argument { name: "chat", title: t("SidebarSectionActions", "argument.sidebar.priority.chat", "Chat"), kind: ArgKind::Target("agent-chat"), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: true, asked_in_palette: false };
#[rustfmt::skip]
pub const APP_2: Argument = Argument { name: "app", title: t("AppStoreActions", "argument.appStore.app", "App"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TAB: Argument = Argument { name: "tab", title: t("AppStoreActions", "argument.appStore.tab", "Tab"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CATEGORY: Argument = Argument { name: "category", title: t("AppStoreActions", "argument.appStore.category", "Category"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DEPLOY: Argument = Argument { name: "deploy", title: t("AppStoreActions", "argument.app.deploy", "Deploy To"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const COMMAND_4: Argument = Argument { name: "command", title: t("AppStoreActions", "argument.app.command", "Command"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DEVICE_2: Argument = Argument { name: "device", title: t("PhoneActions", "argument.phone.device", "Phone"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PATH_5: Argument = Argument { name: "path", title: t("PhoneActions", "argument.phone.path", "File"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NOTES: Argument = Argument { name: "notes", title: t("PhoneActions", "argument.phone.notes", "Notes"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const URL_5: Argument = Argument { name: "url", title: t("PhoneActions", "argument.phone.url", "URL"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TEXT_6: Argument = Argument { name: "text", title: t("PhoneActions", "argument.phone.text", "Text"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const X: Argument = Argument { name: "x", title: t("PhoneActions", "argument.phone.x", "X"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const Y: Argument = Argument { name: "y", title: t("PhoneActions", "argument.phone.y", "Y"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FROM_X: Argument = Argument { name: "fromX", title: t("PhoneActions", "argument.phone.fromX", "From X"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FROM_Y: Argument = Argument { name: "fromY", title: t("PhoneActions", "argument.phone.fromY", "From Y"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TO_X: Argument = Argument { name: "toX", title: t("PhoneActions", "argument.phone.toX", "To X"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TO_Y: Argument = Argument { name: "toY", title: t("PhoneActions", "argument.phone.toY", "To Y"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SECONDS: Argument = Argument { name: "seconds", title: t("PhoneActions", "argument.phone.seconds", "Seconds"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BUTTON: Argument = Argument { name: "button", title: t("PhoneActions", "argument.phone.button", "Button"), kind: ArgKind::Enumeration(CASES_HOME_LOCK), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const APPEARANCE: Argument = Argument { name: "appearance", title: t("PhoneActions", "argument.phone.appearance", "Appearance"), kind: ArgKind::Enumeration(CASES_LIGHT_DARK), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LATITUDE: Argument = Argument { name: "latitude", title: t("PhoneActions", "argument.phone.latitude", "Latitude"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LONGITUDE: Argument = Argument { name: "longitude", title: t("PhoneActions", "argument.phone.longitude", "Longitude"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LOCALE: Argument = Argument { name: "locale", title: t("PhoneActions", "argument.phone.locale", "Locale"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const PATH_6: Argument = Argument { name: "path", title: t("PhoneActions", "argument.phone.app", "App"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const APP_3: Argument = Argument { name: "app", title: t("PhoneActions", "argument.phone.bundle", "Bundle ID or Package"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BACKGROUND_2: Argument = Argument { name: "background", title: t("Localizable", "argument.link.background", "Open in Background"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SOURCE_3: Argument = Argument { name: "source", title: t("Localizable", "argument.link.source", "Beside Tab"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CODE: Argument = Argument { name: "code", title: t("ServerActions", "argument.server.code", "Pairing Code"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WORDS: Argument = Argument { name: "words", title: t("ServerActions", "argument.server.words", "Fingerprint Words"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const NAME_9: Argument = Argument { name: "name", title: t("ServerActions", "argument.server.name", "Server Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CHIEF_4: Argument = Argument { name: "chief", title: t("ServerActions", "argument.server.chief", "Run My Chief There"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ID_4: Argument = Argument { name: "id", title: t("ImportActions", "argument.import.card.id", "Card"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const ACTION: Argument = Argument { name: "action", title: t("ImportActions", "argument.import.card.action", "Button"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BROWSER_2: Argument = Argument { name: "browser", title: t("ImportActions", "argument.import.suggest.browser", "Browser"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const SITE: Argument = Argument { name: "site", title: t("ImportActions", "argument.import.suggest.site", "Site"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const REASON_2: Argument = Argument { name: "reason", title: t("ImportActions", "argument.import.suggest.reason", "Reason"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HARNESS_PROFILE: Argument = Argument { name: "id", title: t("ActionCatalog", "argument.agent.harness.id", "Agent"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "agentHarnessProfiles", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const HARNESS_ICON: Argument = Argument { name: "icon", title: t("ActionCatalog", "argument.agent.harness.icon", "Icon"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WORKTREE_NAME: Argument = Argument { name: "name", title: t("ActionCatalog", "argument.git.worktree.name", "Worktree Name"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WORKTREE_BASE: Argument = Argument { name: "base", title: t("ActionCatalog", "argument.git.worktree.base", "Base Revision"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const WORKTREE_DISCARD: Argument = Argument { name: "discard", title: t("ActionCatalog", "argument.git.worktree.discard", "Discard Unsaved Work"), kind: ArgKind::Bool, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FEED_ITEM: Argument = Argument { name: "item", title: t("ActionCatalog", "argument.feed.item", "Feed Item"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FEED_GITHUB_ACTION: Argument = Argument { name: "action", title: t("ActionCatalog", "argument.feed.githubAction", "GitHub Action"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const FEED_COMMENT: Argument = Argument { name: "comment", title: t("ActionCatalog", "argument.feed.comment", "Comment"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DEBUG_SIDEBAR_TOGGLE_ICON: Argument = Argument { name: "icon", title: t("ActionCatalog", "argument.debug.sidebarToggleIcon", "Icon"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "debugSidebarToggleIcons", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const DEBUG_STATUS_ICON_SET: Argument = Argument { name: "set", title: t("ActionCatalog", "argument.debug.statusIconSet", "Icon Set"), kind: ArgKind::String, required: true, suggestions: Some(Suggestions { source: "debugStatusIconSets", pinned: &[], other_title: None, allows_multiple: false }), is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
