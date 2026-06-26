# cmux shell completions (fish) -- AUTO-GENERATED, DO NOT EDIT.
#
# Regenerate with:  scripts/generate-cli-completions.py --write
# Source of truth:  topLevelCommandNames in CLI/cmux.swift + its usage() help.

# Complete top-level commands only when no command has been typed yet.
function __cmux_needs_command
    set -l cmd (commandline -opc)
    test (count $cmd) -le 1
end

complete -c cmux -n __cmux_needs_command -f -a 'agent-hibernation'
complete -c cmux -n __cmux_needs_command -f -a 'auth'
complete -c cmux -n __cmux_needs_command -f -a 'bind-key'
complete -c cmux -n __cmux_needs_command -f -a 'break-pane'
complete -c cmux -n __cmux_needs_command -f -a 'browser'
complete -c cmux -n __cmux_needs_command -f -a 'browser-back'
complete -c cmux -n __cmux_needs_command -f -a 'browser-forward'
complete -c cmux -n __cmux_needs_command -f -a 'browser-reload'
complete -c cmux -n __cmux_needs_command -f -a 'browser-status'
complete -c cmux -n __cmux_needs_command -f -a 'capabilities'
complete -c cmux -n __cmux_needs_command -f -a 'capture-pane'
complete -c cmux -n __cmux_needs_command -f -a 'claude-teams'
complete -c cmux -n __cmux_needs_command -f -a 'clear-history'
complete -c cmux -n __cmux_needs_command -f -a 'clear-log'
complete -c cmux -n __cmux_needs_command -f -a 'clear-notifications'
complete -c cmux -n __cmux_needs_command -f -a 'clear-progress'
complete -c cmux -n __cmux_needs_command -f -a 'clear-status'
complete -c cmux -n __cmux_needs_command -f -a 'close-surface'
complete -c cmux -n __cmux_needs_command -f -a 'close-window'
complete -c cmux -n __cmux_needs_command -f -a 'close-workspace'
complete -c cmux -n __cmux_needs_command -f -a 'cloud'
complete -c cmux -n __cmux_needs_command -f -a 'codex'
complete -c cmux -n __cmux_needs_command -f -a 'codex-teams'
complete -c cmux -n __cmux_needs_command -f -a 'config'
complete -c cmux -n __cmux_needs_command -f -a 'copy-mode'
complete -c cmux -n __cmux_needs_command -f -a 'current-window'
complete -c cmux -n __cmux_needs_command -f -a 'current-workspace'
complete -c cmux -n __cmux_needs_command -f -a 'debug-terminals'
complete -c cmux -n __cmux_needs_command -f -a 'detach-tab'
complete -c cmux -n __cmux_needs_command -f -a 'diff'
complete -c cmux -n __cmux_needs_command -f -a 'disable-browser'
complete -c cmux -n __cmux_needs_command -f -a 'dismiss-notification'
complete -c cmux -n __cmux_needs_command -f -a 'display-message'
complete -c cmux -n __cmux_needs_command -f -a 'docs'
complete -c cmux -n __cmux_needs_command -f -a 'drag-surface-to-split'
complete -c cmux -n __cmux_needs_command -f -a 'enable-browser'
complete -c cmux -n __cmux_needs_command -f -a 'events'
complete -c cmux -n __cmux_needs_command -f -a 'feed'
complete -c cmux -n __cmux_needs_command -f -a 'feedback'
complete -c cmux -n __cmux_needs_command -f -a 'find-window'
complete -c cmux -n __cmux_needs_command -f -a 'focus-pane'
complete -c cmux -n __cmux_needs_command -f -a 'focus-panel'
complete -c cmux -n __cmux_needs_command -f -a 'focus-webview'
complete -c cmux -n __cmux_needs_command -f -a 'focus-window'
complete -c cmux -n __cmux_needs_command -f -a 'get-url'
complete -c cmux -n __cmux_needs_command -f -a 'help'
complete -c cmux -n __cmux_needs_command -f -a 'hooks'
complete -c cmux -n __cmux_needs_command -f -a 'identify'
complete -c cmux -n __cmux_needs_command -f -a 'is-webview-focused'
complete -c cmux -n __cmux_needs_command -f -a 'join-pane'
complete -c cmux -n __cmux_needs_command -f -a 'jump-to-unread'
complete -c cmux -n __cmux_needs_command -f -a 'last-pane'
complete -c cmux -n __cmux_needs_command -f -a 'last-window'
complete -c cmux -n __cmux_needs_command -f -a 'list-buffers'
complete -c cmux -n __cmux_needs_command -f -a 'list-log'
complete -c cmux -n __cmux_needs_command -f -a 'list-notifications'
complete -c cmux -n __cmux_needs_command -f -a 'list-pane-surfaces'
complete -c cmux -n __cmux_needs_command -f -a 'list-panels'
complete -c cmux -n __cmux_needs_command -f -a 'list-panes'
complete -c cmux -n __cmux_needs_command -f -a 'list-status'
complete -c cmux -n __cmux_needs_command -f -a 'list-windows'
complete -c cmux -n __cmux_needs_command -f -a 'list-workspaces'
complete -c cmux -n __cmux_needs_command -f -a 'log'
complete -c cmux -n __cmux_needs_command -f -a 'login'
complete -c cmux -n __cmux_needs_command -f -a 'logout'
complete -c cmux -n __cmux_needs_command -f -a 'mark-notification-read'
complete -c cmux -n __cmux_needs_command -f -a 'markdown'
complete -c cmux -n __cmux_needs_command -f -a 'memory'
complete -c cmux -n __cmux_needs_command -f -a 'mobile'
complete -c cmux -n __cmux_needs_command -f -a 'move-surface'
complete -c cmux -n __cmux_needs_command -f -a 'move-tab-to-new-workspace'
complete -c cmux -n __cmux_needs_command -f -a 'move-workspace-to-window'
complete -c cmux -n __cmux_needs_command -f -a 'navigate'
complete -c cmux -n __cmux_needs_command -f -a 'new-pane'
complete -c cmux -n __cmux_needs_command -f -a 'new-split'
complete -c cmux -n __cmux_needs_command -f -a 'new-surface'
complete -c cmux -n __cmux_needs_command -f -a 'new-window'
complete -c cmux -n __cmux_needs_command -f -a 'new-workspace'
complete -c cmux -n __cmux_needs_command -f -a 'next-window'
complete -c cmux -n __cmux_needs_command -f -a 'notify'
complete -c cmux -n __cmux_needs_command -f -a 'omc'
complete -c cmux -n __cmux_needs_command -f -a 'omo'
complete -c cmux -n __cmux_needs_command -f -a 'omx'
complete -c cmux -n __cmux_needs_command -f -a 'open'
complete -c cmux -n __cmux_needs_command -f -a 'open-browser'
complete -c cmux -n __cmux_needs_command -f -a 'open-notification'
complete -c cmux -n __cmux_needs_command -f -a 'paste-buffer'
complete -c cmux -n __cmux_needs_command -f -a 'ping'
complete -c cmux -n __cmux_needs_command -f -a 'pipe-pane'
complete -c cmux -n __cmux_needs_command -f -a 'popup'
complete -c cmux -n __cmux_needs_command -f -a 'previous-window'
complete -c cmux -n __cmux_needs_command -f -a 'read-screen'
complete -c cmux -n __cmux_needs_command -f -a 'refresh-surfaces'
complete -c cmux -n __cmux_needs_command -f -a 'reload-config'
complete -c cmux -n __cmux_needs_command -f -a 'remote-daemon-status'
complete -c cmux -n __cmux_needs_command -f -a 'rename-tab'
complete -c cmux -n __cmux_needs_command -f -a 'rename-window'
complete -c cmux -n __cmux_needs_command -f -a 'rename-workspace'
complete -c cmux -n __cmux_needs_command -f -a 'reorder-surface'
complete -c cmux -n __cmux_needs_command -f -a 'reorder-workspace'
complete -c cmux -n __cmux_needs_command -f -a 'reorder-workspaces'
complete -c cmux -n __cmux_needs_command -f -a 'resize-pane'
complete -c cmux -n __cmux_needs_command -f -a 'respawn-pane'
complete -c cmux -n __cmux_needs_command -f -a 'restore-session'
complete -c cmux -n __cmux_needs_command -f -a 'right-sidebar'
complete -c cmux -n __cmux_needs_command -f -a 'rpc'
complete -c cmux -n __cmux_needs_command -f -a 'select-workspace'
complete -c cmux -n __cmux_needs_command -f -a 'send'
complete -c cmux -n __cmux_needs_command -f -a 'send-key'
complete -c cmux -n __cmux_needs_command -f -a 'send-key-panel'
complete -c cmux -n __cmux_needs_command -f -a 'send-panel'
complete -c cmux -n __cmux_needs_command -f -a 'set-app-focus'
complete -c cmux -n __cmux_needs_command -f -a 'set-buffer'
complete -c cmux -n __cmux_needs_command -f -a 'set-progress'
complete -c cmux -n __cmux_needs_command -f -a 'set-status'
complete -c cmux -n __cmux_needs_command -f -a 'settings'
complete -c cmux -n __cmux_needs_command -f -a 'shortcuts'
complete -c cmux -n __cmux_needs_command -f -a 'sidebar'
complete -c cmux -n __cmux_needs_command -f -a 'sidebar-state'
complete -c cmux -n __cmux_needs_command -f -a 'simulate-app-active'
complete -c cmux -n __cmux_needs_command -f -a 'split-off'
complete -c cmux -n __cmux_needs_command -f -a 'ssh'
complete -c cmux -n __cmux_needs_command -f -a 'ssh-session-attach'
complete -c cmux -n __cmux_needs_command -f -a 'ssh-session-cleanup'
complete -c cmux -n __cmux_needs_command -f -a 'ssh-session-list'
complete -c cmux -n __cmux_needs_command -f -a 'ssh-tmux'
complete -c cmux -n __cmux_needs_command -f -a 'surface'
complete -c cmux -n __cmux_needs_command -f -a 'surface-health'
complete -c cmux -n __cmux_needs_command -f -a 'surface-resume'
complete -c cmux -n __cmux_needs_command -f -a 'swap-pane'
complete -c cmux -n __cmux_needs_command -f -a 'tab-action'
complete -c cmux -n __cmux_needs_command -f -a 'themes'
complete -c cmux -n __cmux_needs_command -f -a 'top'
complete -c cmux -n __cmux_needs_command -f -a 'tree'
complete -c cmux -n __cmux_needs_command -f -a 'trigger-flash'
complete -c cmux -n __cmux_needs_command -f -a 'unbind-key'
complete -c cmux -n __cmux_needs_command -f -a 'version'
complete -c cmux -n __cmux_needs_command -f -a 'vm'
complete -c cmux -n __cmux_needs_command -f -a 'wait-for'
complete -c cmux -n __cmux_needs_command -f -a 'welcome'
complete -c cmux -n __cmux_needs_command -f -a 'workspace'
complete -c cmux -n __cmux_needs_command -f -a 'workspace-action'
complete -c cmux -n __cmux_needs_command -f -a 'workspace-group'

complete -c cmux -n '__fish_seen_subcommand_from agent-hibernation' -f -a 'off'
complete -c cmux -n '__fish_seen_subcommand_from agent-hibernation' -f -a 'on'
complete -c cmux -n '__fish_seen_subcommand_from auth' -f -a 'login'
complete -c cmux -n '__fish_seen_subcommand_from auth' -f -a 'logout'
complete -c cmux -n '__fish_seen_subcommand_from auth' -f -a 'status'
complete -c cmux -n '__fish_seen_subcommand_from break-pane' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from break-pane' -l no-focus
complete -c cmux -n '__fish_seen_subcommand_from break-pane' -l pane
complete -c cmux -n '__fish_seen_subcommand_from break-pane' -l surface
complete -c cmux -n '__fish_seen_subcommand_from break-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from break-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'addinitscript'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'addscript'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'addstyle'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'console'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'cookies'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'devtools'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'dialog'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'disable'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'download'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'errors'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'eval'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'fill'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'find'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'focus-mode'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'frame'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'get'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'highlight'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'history'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'identify'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'import'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'is'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'open'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'open-split'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'profiles'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'react-grab'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'screenshot'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'scroll'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'select'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'snapshot'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'state'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'storage'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'tab'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'type'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'wait'
complete -c cmux -n '__fish_seen_subcommand_from browser' -f -a 'zoom'
complete -c cmux -n '__fish_seen_subcommand_from browser' -l all
complete -c cmux -n '__fish_seen_subcommand_from browser' -l compact
complete -c cmux -n '__fish_seen_subcommand_from browser' -l cursor
complete -c cmux -n '__fish_seen_subcommand_from browser' -l dx
complete -c cmux -n '__fish_seen_subcommand_from browser' -l dy
complete -c cmux -n '__fish_seen_subcommand_from browser' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from browser' -l force
complete -c cmux -n '__fish_seen_subcommand_from browser' -l function
complete -c cmux -n '__fish_seen_subcommand_from browser' -l interactive
complete -c cmux -n '__fish_seen_subcommand_from browser' -l json
complete -c cmux -n '__fish_seen_subcommand_from browser' -l load-state -f -a 'interactive complete'
complete -c cmux -n '__fish_seen_subcommand_from browser' -l max-depth
complete -c cmux -n '__fish_seen_subcommand_from browser' -l out
complete -c cmux -n '__fish_seen_subcommand_from browser' -l path
complete -c cmux -n '__fish_seen_subcommand_from browser' -l return-to
complete -c cmux -n '__fish_seen_subcommand_from browser' -l selector
complete -c cmux -n '__fish_seen_subcommand_from browser' -l snapshot-after
complete -c cmux -n '__fish_seen_subcommand_from browser' -l surface
complete -c cmux -n '__fish_seen_subcommand_from browser' -l text
complete -c cmux -n '__fish_seen_subcommand_from browser' -l timeout-ms
complete -c cmux -n '__fish_seen_subcommand_from browser' -l url-contains
complete -c cmux -n '__fish_seen_subcommand_from capture-pane' -l lines
complete -c cmux -n '__fish_seen_subcommand_from capture-pane' -l scrollback
complete -c cmux -n '__fish_seen_subcommand_from capture-pane' -l surface
complete -c cmux -n '__fish_seen_subcommand_from capture-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from capture-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from clear-history' -l surface
complete -c cmux -n '__fish_seen_subcommand_from clear-history' -l window
complete -c cmux -n '__fish_seen_subcommand_from clear-history' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from clear-log' -l window
complete -c cmux -n '__fish_seen_subcommand_from clear-log' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from clear-notifications' -l window
complete -c cmux -n '__fish_seen_subcommand_from clear-notifications' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from clear-progress' -l window
complete -c cmux -n '__fish_seen_subcommand_from clear-progress' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from clear-status' -l window
complete -c cmux -n '__fish_seen_subcommand_from clear-status' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from close-surface' -l surface
complete -c cmux -n '__fish_seen_subcommand_from close-surface' -l window
complete -c cmux -n '__fish_seen_subcommand_from close-surface' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from close-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from close-workspace' -l window
complete -c cmux -n '__fish_seen_subcommand_from close-workspace' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from current-workspace' -l window
complete -c cmux -n '__fish_seen_subcommand_from diff' -l base
complete -c cmux -n '__fish_seen_subcommand_from diff' -l branch
complete -c cmux -n '__fish_seen_subcommand_from diff' -l cwd
complete -c cmux -n '__fish_seen_subcommand_from diff' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from diff' -l font-size
complete -c cmux -n '__fish_seen_subcommand_from diff' -l last-turn
complete -c cmux -n '__fish_seen_subcommand_from diff' -l layout -f -a 'split unified'
complete -c cmux -n '__fish_seen_subcommand_from diff' -l no-focus
complete -c cmux -n '__fish_seen_subcommand_from diff' -l source -f -a 'unstaged staged branch last-turn'
complete -c cmux -n '__fish_seen_subcommand_from diff' -l staged
complete -c cmux -n '__fish_seen_subcommand_from diff' -l surface
complete -c cmux -n '__fish_seen_subcommand_from diff' -l title
complete -c cmux -n '__fish_seen_subcommand_from diff' -l unstaged
complete -c cmux -n '__fish_seen_subcommand_from diff' -l window
complete -c cmux -n '__fish_seen_subcommand_from diff' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from dismiss-notification' -l all-read
complete -c cmux -n '__fish_seen_subcommand_from dismiss-notification' -l id
complete -c cmux -n '__fish_seen_subcommand_from display-message' -l print
complete -c cmux -n '__fish_seen_subcommand_from docs' -f -a 'agents'
complete -c cmux -n '__fish_seen_subcommand_from docs' -f -a 'api'
complete -c cmux -n '__fish_seen_subcommand_from docs' -f -a 'browser'
complete -c cmux -n '__fish_seen_subcommand_from docs' -f -a 'dock'
complete -c cmux -n '__fish_seen_subcommand_from docs' -f -a 'settings'
complete -c cmux -n '__fish_seen_subcommand_from docs' -f -a 'shortcuts'
complete -c cmux -n '__fish_seen_subcommand_from docs' -f -a 'sidebars'
complete -c cmux -n '__fish_seen_subcommand_from drag-surface-to-split' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from drag-surface-to-split' -l surface
complete -c cmux -n '__fish_seen_subcommand_from drag-surface-to-split' -l window
complete -c cmux -n '__fish_seen_subcommand_from drag-surface-to-split' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from events' -l after
complete -c cmux -n '__fish_seen_subcommand_from events' -l category
complete -c cmux -n '__fish_seen_subcommand_from events' -l cursor-file
complete -c cmux -n '__fish_seen_subcommand_from events' -l limit
complete -c cmux -n '__fish_seen_subcommand_from events' -l name
complete -c cmux -n '__fish_seen_subcommand_from events' -l no-ack
complete -c cmux -n '__fish_seen_subcommand_from events' -l no-heartbeat
complete -c cmux -n '__fish_seen_subcommand_from events' -l reconnect
complete -c cmux -n '__fish_seen_subcommand_from feedback' -l body
complete -c cmux -n '__fish_seen_subcommand_from feedback' -l email
complete -c cmux -n '__fish_seen_subcommand_from feedback' -l image
complete -c cmux -n '__fish_seen_subcommand_from find-window' -l content
complete -c cmux -n '__fish_seen_subcommand_from find-window' -l select
complete -c cmux -n '__fish_seen_subcommand_from find-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from focus-pane' -l pane
complete -c cmux -n '__fish_seen_subcommand_from focus-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from focus-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from focus-panel' -l panel
complete -c cmux -n '__fish_seen_subcommand_from focus-panel' -l window
complete -c cmux -n '__fish_seen_subcommand_from focus-panel' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from focus-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from hooks' -f -a 'feed'
complete -c cmux -n '__fish_seen_subcommand_from hooks' -l agent
complete -c cmux -n '__fish_seen_subcommand_from hooks' -l event
complete -c cmux -n '__fish_seen_subcommand_from hooks' -l project
complete -c cmux -n '__fish_seen_subcommand_from hooks' -l source
complete -c cmux -n '__fish_seen_subcommand_from identify' -l no-caller
complete -c cmux -n '__fish_seen_subcommand_from identify' -l surface
complete -c cmux -n '__fish_seen_subcommand_from identify' -l window
complete -c cmux -n '__fish_seen_subcommand_from identify' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from join-pane' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from join-pane' -l no-focus
complete -c cmux -n '__fish_seen_subcommand_from join-pane' -l pane
complete -c cmux -n '__fish_seen_subcommand_from join-pane' -l surface
complete -c cmux -n '__fish_seen_subcommand_from join-pane' -l target-pane
complete -c cmux -n '__fish_seen_subcommand_from join-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from join-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from last-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from last-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from last-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from list-log' -l limit
complete -c cmux -n '__fish_seen_subcommand_from list-log' -l window
complete -c cmux -n '__fish_seen_subcommand_from list-log' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from list-pane-surfaces' -l pane
complete -c cmux -n '__fish_seen_subcommand_from list-pane-surfaces' -l window
complete -c cmux -n '__fish_seen_subcommand_from list-pane-surfaces' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from list-panels' -l window
complete -c cmux -n '__fish_seen_subcommand_from list-panels' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from list-panes' -l window
complete -c cmux -n '__fish_seen_subcommand_from list-panes' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from list-status' -l window
complete -c cmux -n '__fish_seen_subcommand_from list-status' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from list-workspaces' -l window
complete -c cmux -n '__fish_seen_subcommand_from log' -l level
complete -c cmux -n '__fish_seen_subcommand_from log' -l source
complete -c cmux -n '__fish_seen_subcommand_from log' -l window
complete -c cmux -n '__fish_seen_subcommand_from log' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from mark-notification-read' -l all
complete -c cmux -n '__fish_seen_subcommand_from mark-notification-read' -l id
complete -c cmux -n '__fish_seen_subcommand_from mark-notification-read' -l surface
complete -c cmux -n '__fish_seen_subcommand_from mark-notification-read' -l window
complete -c cmux -n '__fish_seen_subcommand_from mark-notification-read' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from markdown' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from memory' -l all
complete -c cmux -n '__fish_seen_subcommand_from memory' -l groups
complete -c cmux -n '__fish_seen_subcommand_from memory' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l after
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l before
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l index
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l pane
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l surface
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l window
complete -c cmux -n '__fish_seen_subcommand_from move-surface' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from move-tab-to-new-workspace' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from move-tab-to-new-workspace' -l surface
complete -c cmux -n '__fish_seen_subcommand_from move-tab-to-new-workspace' -l tab
complete -c cmux -n '__fish_seen_subcommand_from move-tab-to-new-workspace' -l title
complete -c cmux -n '__fish_seen_subcommand_from move-tab-to-new-workspace' -l window
complete -c cmux -n '__fish_seen_subcommand_from move-tab-to-new-workspace' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from move-workspace-to-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from move-workspace-to-window' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from new-pane' -l direction -f -a 'left right up down'
complete -c cmux -n '__fish_seen_subcommand_from new-pane' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from new-pane' -l type -f -a 'terminal browser'
complete -c cmux -n '__fish_seen_subcommand_from new-pane' -l url
complete -c cmux -n '__fish_seen_subcommand_from new-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from new-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from new-split' -f -a 'down'
complete -c cmux -n '__fish_seen_subcommand_from new-split' -f -a 'left'
complete -c cmux -n '__fish_seen_subcommand_from new-split' -f -a 'right'
complete -c cmux -n '__fish_seen_subcommand_from new-split' -f -a 'up'
complete -c cmux -n '__fish_seen_subcommand_from new-split' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from new-split' -l panel
complete -c cmux -n '__fish_seen_subcommand_from new-split' -l surface
complete -c cmux -n '__fish_seen_subcommand_from new-split' -l window
complete -c cmux -n '__fish_seen_subcommand_from new-split' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l pane
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l provider -f -a 'codex claude opencode'
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l renderer -f -a 'react solid'
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l type -f -a 'terminal browser agent-session'
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l url
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l window
complete -c cmux -n '__fish_seen_subcommand_from new-surface' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l command
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l cwd
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l description
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l group
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l group-placement
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l group-reference
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l layout
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l name
complete -c cmux -n '__fish_seen_subcommand_from new-workspace' -l window
complete -c cmux -n '__fish_seen_subcommand_from next-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from notify' -l body
complete -c cmux -n '__fish_seen_subcommand_from notify' -l subtitle
complete -c cmux -n '__fish_seen_subcommand_from notify' -l surface
complete -c cmux -n '__fish_seen_subcommand_from notify' -l title
complete -c cmux -n '__fish_seen_subcommand_from notify' -l window
complete -c cmux -n '__fish_seen_subcommand_from notify' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from open' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from open' -l no-focus
complete -c cmux -n '__fish_seen_subcommand_from open' -l pane
complete -c cmux -n '__fish_seen_subcommand_from open' -l surface
complete -c cmux -n '__fish_seen_subcommand_from open' -l window
complete -c cmux -n '__fish_seen_subcommand_from open' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from open-notification' -l id
complete -c cmux -n '__fish_seen_subcommand_from paste-buffer' -l name
complete -c cmux -n '__fish_seen_subcommand_from paste-buffer' -l surface
complete -c cmux -n '__fish_seen_subcommand_from paste-buffer' -l window
complete -c cmux -n '__fish_seen_subcommand_from paste-buffer' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from pipe-pane' -l command
complete -c cmux -n '__fish_seen_subcommand_from pipe-pane' -l surface
complete -c cmux -n '__fish_seen_subcommand_from pipe-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from pipe-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from previous-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from read-screen' -l lines
complete -c cmux -n '__fish_seen_subcommand_from read-screen' -l scrollback
complete -c cmux -n '__fish_seen_subcommand_from read-screen' -l surface
complete -c cmux -n '__fish_seen_subcommand_from read-screen' -l window
complete -c cmux -n '__fish_seen_subcommand_from read-screen' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from remote-daemon-status' -l arch -f -a 'arm64 amd64'
complete -c cmux -n '__fish_seen_subcommand_from remote-daemon-status' -l os -f -a 'darwin linux'
complete -c cmux -n '__fish_seen_subcommand_from rename-tab' -l surface
complete -c cmux -n '__fish_seen_subcommand_from rename-tab' -l tab
complete -c cmux -n '__fish_seen_subcommand_from rename-tab' -l window
complete -c cmux -n '__fish_seen_subcommand_from rename-tab' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from rename-window' -l window
complete -c cmux -n '__fish_seen_subcommand_from rename-window' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from rename-workspace' -l window
complete -c cmux -n '__fish_seen_subcommand_from rename-workspace' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from reorder-surface' -l after
complete -c cmux -n '__fish_seen_subcommand_from reorder-surface' -l before
complete -c cmux -n '__fish_seen_subcommand_from reorder-surface' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from reorder-surface' -l index
complete -c cmux -n '__fish_seen_subcommand_from reorder-surface' -l surface
complete -c cmux -n '__fish_seen_subcommand_from reorder-surface' -l window
complete -c cmux -n '__fish_seen_subcommand_from reorder-surface' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspace' -l after
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspace' -l before
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspace' -l dry-run
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspace' -l index
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspace' -l window
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspace' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspaces' -l dry-run
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspaces' -l order
complete -c cmux -n '__fish_seen_subcommand_from reorder-workspaces' -l window
complete -c cmux -n '__fish_seen_subcommand_from resize-pane' -l amount
complete -c cmux -n '__fish_seen_subcommand_from resize-pane' -l pane
complete -c cmux -n '__fish_seen_subcommand_from resize-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from resize-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from respawn-pane' -l command
complete -c cmux -n '__fish_seen_subcommand_from respawn-pane' -l surface
complete -c cmux -n '__fish_seen_subcommand_from respawn-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from respawn-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'dock'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'feed'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'files'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'find'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'focus'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'hide'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'mode'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'sessions'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'set'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'show'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'toggle'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -f -a 'vault'
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -l no-focus
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -l window
complete -c cmux -n '__fish_seen_subcommand_from right-sidebar' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from select-workspace' -l window
complete -c cmux -n '__fish_seen_subcommand_from select-workspace' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from send' -l surface
complete -c cmux -n '__fish_seen_subcommand_from send' -l window
complete -c cmux -n '__fish_seen_subcommand_from send' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from send-key' -l surface
complete -c cmux -n '__fish_seen_subcommand_from send-key' -l window
complete -c cmux -n '__fish_seen_subcommand_from send-key' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from send-key-panel' -l panel
complete -c cmux -n '__fish_seen_subcommand_from send-key-panel' -l window
complete -c cmux -n '__fish_seen_subcommand_from send-key-panel' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from send-panel' -l panel
complete -c cmux -n '__fish_seen_subcommand_from send-panel' -l window
complete -c cmux -n '__fish_seen_subcommand_from send-panel' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from set-app-focus' -f -a 'active'
complete -c cmux -n '__fish_seen_subcommand_from set-app-focus' -f -a 'clear'
complete -c cmux -n '__fish_seen_subcommand_from set-app-focus' -f -a 'inactive'
complete -c cmux -n '__fish_seen_subcommand_from set-buffer' -l name
complete -c cmux -n '__fish_seen_subcommand_from set-progress' -l label
complete -c cmux -n '__fish_seen_subcommand_from set-progress' -l window
complete -c cmux -n '__fish_seen_subcommand_from set-progress' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from set-status' -l color
complete -c cmux -n '__fish_seen_subcommand_from set-status' -l icon
complete -c cmux -n '__fish_seen_subcommand_from set-status' -l priority
complete -c cmux -n '__fish_seen_subcommand_from set-status' -l window
complete -c cmux -n '__fish_seen_subcommand_from set-status' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from sidebar' -f -a 'open'
complete -c cmux -n '__fish_seen_subcommand_from sidebar' -f -a 'reload'
complete -c cmux -n '__fish_seen_subcommand_from sidebar' -f -a 'select'
complete -c cmux -n '__fish_seen_subcommand_from sidebar' -f -a 'validate'
complete -c cmux -n '__fish_seen_subcommand_from sidebar-state' -l window
complete -c cmux -n '__fish_seen_subcommand_from sidebar-state' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from split-off' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from split-off' -l surface
complete -c cmux -n '__fish_seen_subcommand_from split-off' -l window
complete -c cmux -n '__fish_seen_subcommand_from split-off' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l forward-agent
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l identity
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l name
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l no-focus
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l no-forward-agent
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l port
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l ssh-option
complete -c cmux -n '__fish_seen_subcommand_from ssh' -l window
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-attach' -l pane
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-attach' -l session-id
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-attach' -l split -f -a 'left right up down'
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-attach' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-cleanup' -l all
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-cleanup' -l all-workspaces
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-cleanup' -l session-id
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-cleanup' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-list' -l all-workspaces
complete -c cmux -n '__fish_seen_subcommand_from ssh-session-list' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from ssh-tmux' -l identity
complete -c cmux -n '__fish_seen_subcommand_from ssh-tmux' -l no-focus
complete -c cmux -n '__fish_seen_subcommand_from ssh-tmux' -l port
complete -c cmux -n '__fish_seen_subcommand_from surface' -f -a 'resume'
complete -c cmux -n '__fish_seen_subcommand_from surface' -l surface
complete -c cmux -n '__fish_seen_subcommand_from surface' -l window
complete -c cmux -n '__fish_seen_subcommand_from surface' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from surface-health' -l window
complete -c cmux -n '__fish_seen_subcommand_from surface-health' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from swap-pane' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from swap-pane' -l pane
complete -c cmux -n '__fish_seen_subcommand_from swap-pane' -l target-pane
complete -c cmux -n '__fish_seen_subcommand_from swap-pane' -l window
complete -c cmux -n '__fish_seen_subcommand_from swap-pane' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l action
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l focus -f -a 'true false'
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l surface
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l tab
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l title
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l url
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l window
complete -c cmux -n '__fish_seen_subcommand_from tab-action' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from themes' -f -a 'clear'
complete -c cmux -n '__fish_seen_subcommand_from themes' -f -a 'list'
complete -c cmux -n '__fish_seen_subcommand_from themes' -f -a 'set'
complete -c cmux -n '__fish_seen_subcommand_from top' -l all
complete -c cmux -n '__fish_seen_subcommand_from top' -l flat
complete -c cmux -n '__fish_seen_subcommand_from top' -l format -f -a 'tree tsv'
complete -c cmux -n '__fish_seen_subcommand_from top' -l processes
complete -c cmux -n '__fish_seen_subcommand_from top' -l sort -f -a 'cpu mem proc'
complete -c cmux -n '__fish_seen_subcommand_from top' -l window
complete -c cmux -n '__fish_seen_subcommand_from top' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from tree' -l all
complete -c cmux -n '__fish_seen_subcommand_from tree' -l window
complete -c cmux -n '__fish_seen_subcommand_from tree' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from trigger-flash' -l surface
complete -c cmux -n '__fish_seen_subcommand_from trigger-flash' -l window
complete -c cmux -n '__fish_seen_subcommand_from trigger-flash' -l workspace
complete -c cmux -n '__fish_seen_subcommand_from vm' -f -a 'exec'
complete -c cmux -n '__fish_seen_subcommand_from vm' -f -a 'ls'
complete -c cmux -n '__fish_seen_subcommand_from vm' -f -a 'new'
complete -c cmux -n '__fish_seen_subcommand_from vm' -f -a 'rm'
complete -c cmux -n '__fish_seen_subcommand_from vm' -f -a 'shell'
complete -c cmux -n '__fish_seen_subcommand_from vm' -f -a 'ssh'
complete -c cmux -n '__fish_seen_subcommand_from wait-for' -l signal
complete -c cmux -n '__fish_seen_subcommand_from wait-for' -l timeout
complete -c cmux -n '__fish_seen_subcommand_from workspace-action' -l action
complete -c cmux -n '__fish_seen_subcommand_from workspace-action' -l color
complete -c cmux -n '__fish_seen_subcommand_from workspace-action' -l description
complete -c cmux -n '__fish_seen_subcommand_from workspace-action' -l title
complete -c cmux -n '__fish_seen_subcommand_from workspace-action' -l window
complete -c cmux -n '__fish_seen_subcommand_from workspace-action' -l workspace
