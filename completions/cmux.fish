# cmux shell completions (fish) -- AUTO-GENERATED, DO NOT EDIT.
#
# Regenerate with:  scripts/generate-cli-completions.py --write
# Source of truth:  topLevelCommandNames in CLI/CMUXCLI+CommandSuggestions.swift + CLI/cmux.swift usage() help.

function __cmux_command
    set -l toks (commandline -opc)
    set -l i 2
    while test $i -le (count $toks)
        switch $toks[$i]
            case '--socket' '--id-format' '--window' '--password'
                set i (math $i + 2)
            case '-*'
                set i (math $i + 1)
            case '*'
                echo $toks[$i]
                return
        end
    end
end

function __cmux_needs_command
    set -l cmd (__cmux_command)
    test -z "$cmd"
end

function __cmux_command_is
    set -l cmd (__cmux_command)
    test "$cmd" = "$argv[1]"
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
complete -c cmux -n __cmux_needs_command -f -a 'remote'
complete -c cmux -n __cmux_needs_command -f -a 'remote-daemon-status'
complete -c cmux -n __cmux_needs_command -f -a 'remotes'
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
complete -c cmux -n __cmux_needs_command -f -a 'set-hook'
complete -c cmux -n __cmux_needs_command -f -a 'set-progress'
complete -c cmux -n __cmux_needs_command -f -a 'set-status'
complete -c cmux -n __cmux_needs_command -f -a 'settings'
complete -c cmux -n __cmux_needs_command -f -a 'shortcuts'
complete -c cmux -n __cmux_needs_command -f -a 'sidebar'
complete -c cmux -n __cmux_needs_command -f -a 'sidebar-state'
complete -c cmux -n __cmux_needs_command -f -a 'simulate-app-active'
complete -c cmux -n __cmux_needs_command -f -a 'simulate-sidebar-drag'
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

complete -c cmux -n '__cmux_command_is agent-hibernation' -f -a 'off'
complete -c cmux -n '__cmux_command_is agent-hibernation' -f -a 'on'
complete -c cmux -n '__cmux_command_is auth' -f -a 'login'
complete -c cmux -n '__cmux_command_is auth' -f -a 'logout'
complete -c cmux -n '__cmux_command_is auth' -f -a 'status'
complete -c cmux -n '__cmux_command_is break-pane' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is break-pane' -l no-focus
complete -c cmux -n '__cmux_command_is break-pane' -l pane
complete -c cmux -n '__cmux_command_is break-pane' -l surface
complete -c cmux -n '__cmux_command_is break-pane' -l window
complete -c cmux -n '__cmux_command_is break-pane' -l workspace
complete -c cmux -n '__cmux_command_is browser' -f -a 'addinitscript'
complete -c cmux -n '__cmux_command_is browser' -f -a 'addscript'
complete -c cmux -n '__cmux_command_is browser' -f -a 'addstyle'
complete -c cmux -n '__cmux_command_is browser' -f -a 'back'
complete -c cmux -n '__cmux_command_is browser' -f -a 'check'
complete -c cmux -n '__cmux_command_is browser' -f -a 'click'
complete -c cmux -n '__cmux_command_is browser' -f -a 'console'
complete -c cmux -n '__cmux_command_is browser' -f -a 'cookies'
complete -c cmux -n '__cmux_command_is browser' -f -a 'dblclick'
complete -c cmux -n '__cmux_command_is browser' -f -a 'devtools'
complete -c cmux -n '__cmux_command_is browser' -f -a 'dialog'
complete -c cmux -n '__cmux_command_is browser' -f -a 'disable'
complete -c cmux -n '__cmux_command_is browser' -f -a 'download'
complete -c cmux -n '__cmux_command_is browser' -f -a 'enable'
complete -c cmux -n '__cmux_command_is browser' -f -a 'errors'
complete -c cmux -n '__cmux_command_is browser' -f -a 'eval'
complete -c cmux -n '__cmux_command_is browser' -f -a 'fill'
complete -c cmux -n '__cmux_command_is browser' -f -a 'find'
complete -c cmux -n '__cmux_command_is browser' -f -a 'focus'
complete -c cmux -n '__cmux_command_is browser' -f -a 'focus-mode'
complete -c cmux -n '__cmux_command_is browser' -f -a 'forward'
complete -c cmux -n '__cmux_command_is browser' -f -a 'frame'
complete -c cmux -n '__cmux_command_is browser' -f -a 'get'
complete -c cmux -n '__cmux_command_is browser' -f -a 'get-url'
complete -c cmux -n '__cmux_command_is browser' -f -a 'goto'
complete -c cmux -n '__cmux_command_is browser' -f -a 'highlight'
complete -c cmux -n '__cmux_command_is browser' -f -a 'history'
complete -c cmux -n '__cmux_command_is browser' -f -a 'hover'
complete -c cmux -n '__cmux_command_is browser' -f -a 'identify'
complete -c cmux -n '__cmux_command_is browser' -f -a 'import'
complete -c cmux -n '__cmux_command_is browser' -f -a 'is'
complete -c cmux -n '__cmux_command_is browser' -f -a 'keydown'
complete -c cmux -n '__cmux_command_is browser' -f -a 'keyup'
complete -c cmux -n '__cmux_command_is browser' -f -a 'navigate'
complete -c cmux -n '__cmux_command_is browser' -f -a 'open'
complete -c cmux -n '__cmux_command_is browser' -f -a 'open-split'
complete -c cmux -n '__cmux_command_is browser' -f -a 'press'
complete -c cmux -n '__cmux_command_is browser' -f -a 'profiles'
complete -c cmux -n '__cmux_command_is browser' -f -a 'react-grab'
complete -c cmux -n '__cmux_command_is browser' -f -a 'reload'
complete -c cmux -n '__cmux_command_is browser' -f -a 'screenshot'
complete -c cmux -n '__cmux_command_is browser' -f -a 'scroll'
complete -c cmux -n '__cmux_command_is browser' -f -a 'scroll-into-view'
complete -c cmux -n '__cmux_command_is browser' -f -a 'select'
complete -c cmux -n '__cmux_command_is browser' -f -a 'snapshot'
complete -c cmux -n '__cmux_command_is browser' -f -a 'state'
complete -c cmux -n '__cmux_command_is browser' -f -a 'status'
complete -c cmux -n '__cmux_command_is browser' -f -a 'storage'
complete -c cmux -n '__cmux_command_is browser' -f -a 'tab'
complete -c cmux -n '__cmux_command_is browser' -f -a 'type'
complete -c cmux -n '__cmux_command_is browser' -f -a 'uncheck'
complete -c cmux -n '__cmux_command_is browser' -f -a 'url'
complete -c cmux -n '__cmux_command_is browser' -f -a 'wait'
complete -c cmux -n '__cmux_command_is browser' -f -a 'zoom'
complete -c cmux -n '__cmux_command_is browser' -l all
complete -c cmux -n '__cmux_command_is browser' -l compact
complete -c cmux -n '__cmux_command_is browser' -l cursor
complete -c cmux -n '__cmux_command_is browser' -l dx
complete -c cmux -n '__cmux_command_is browser' -l dy
complete -c cmux -n '__cmux_command_is browser' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is browser' -l force
complete -c cmux -n '__cmux_command_is browser' -l function
complete -c cmux -n '__cmux_command_is browser' -l interactive
complete -c cmux -n '__cmux_command_is browser' -l json
complete -c cmux -n '__cmux_command_is browser' -l load-state -f -a 'interactive complete'
complete -c cmux -n '__cmux_command_is browser' -l max-depth
complete -c cmux -n '__cmux_command_is browser' -l out
complete -c cmux -n '__cmux_command_is browser' -l path
complete -c cmux -n '__cmux_command_is browser' -l return-to
complete -c cmux -n '__cmux_command_is browser' -l selector
complete -c cmux -n '__cmux_command_is browser' -l snapshot-after
complete -c cmux -n '__cmux_command_is browser' -l surface
complete -c cmux -n '__cmux_command_is browser' -l text
complete -c cmux -n '__cmux_command_is browser' -l timeout-ms
complete -c cmux -n '__cmux_command_is browser' -l url-contains
complete -c cmux -n '__cmux_command_is capture-pane' -l lines
complete -c cmux -n '__cmux_command_is capture-pane' -l scrollback
complete -c cmux -n '__cmux_command_is capture-pane' -l surface
complete -c cmux -n '__cmux_command_is capture-pane' -l window
complete -c cmux -n '__cmux_command_is capture-pane' -l workspace
complete -c cmux -n '__cmux_command_is clear-history' -l surface
complete -c cmux -n '__cmux_command_is clear-history' -l window
complete -c cmux -n '__cmux_command_is clear-history' -l workspace
complete -c cmux -n '__cmux_command_is clear-log' -l window
complete -c cmux -n '__cmux_command_is clear-log' -l workspace
complete -c cmux -n '__cmux_command_is clear-notifications' -l window
complete -c cmux -n '__cmux_command_is clear-notifications' -l workspace
complete -c cmux -n '__cmux_command_is clear-progress' -l window
complete -c cmux -n '__cmux_command_is clear-progress' -l workspace
complete -c cmux -n '__cmux_command_is clear-status' -l window
complete -c cmux -n '__cmux_command_is clear-status' -l workspace
complete -c cmux -n '__cmux_command_is close-surface' -l surface
complete -c cmux -n '__cmux_command_is close-surface' -l window
complete -c cmux -n '__cmux_command_is close-surface' -l workspace
complete -c cmux -n '__cmux_command_is close-window' -l window
complete -c cmux -n '__cmux_command_is close-workspace' -l window
complete -c cmux -n '__cmux_command_is close-workspace' -l workspace
complete -c cmux -n '__cmux_command_is cloud' -f -a 'exec'
complete -c cmux -n '__cmux_command_is cloud' -f -a 'ls'
complete -c cmux -n '__cmux_command_is cloud' -f -a 'new'
complete -c cmux -n '__cmux_command_is cloud' -f -a 'rm'
complete -c cmux -n '__cmux_command_is cloud' -f -a 'shell'
complete -c cmux -n '__cmux_command_is cloud' -f -a 'ssh'
complete -c cmux -n '__cmux_command_is config' -f -a 'check'
complete -c cmux -n '__cmux_command_is config' -f -a 'docs'
complete -c cmux -n '__cmux_command_is config' -f -a 'doctor'
complete -c cmux -n '__cmux_command_is config' -f -a 'documentation'
complete -c cmux -n '__cmux_command_is config' -f -a 'path'
complete -c cmux -n '__cmux_command_is config' -f -a 'paths'
complete -c cmux -n '__cmux_command_is config' -f -a 'reload'
complete -c cmux -n '__cmux_command_is config' -f -a 'validate'
complete -c cmux -n '__cmux_command_is current-workspace' -l window
complete -c cmux -n '__cmux_command_is diff' -l base
complete -c cmux -n '__cmux_command_is diff' -l branch
complete -c cmux -n '__cmux_command_is diff' -l cwd
complete -c cmux -n '__cmux_command_is diff' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is diff' -l font-size
complete -c cmux -n '__cmux_command_is diff' -l last-turn
complete -c cmux -n '__cmux_command_is diff' -l layout -f -a 'split unified'
complete -c cmux -n '__cmux_command_is diff' -l no-focus
complete -c cmux -n '__cmux_command_is diff' -l source -f -a 'unstaged staged branch last-turn'
complete -c cmux -n '__cmux_command_is diff' -l staged
complete -c cmux -n '__cmux_command_is diff' -l surface
complete -c cmux -n '__cmux_command_is diff' -l title
complete -c cmux -n '__cmux_command_is diff' -l unstaged
complete -c cmux -n '__cmux_command_is diff' -l window
complete -c cmux -n '__cmux_command_is diff' -l workspace
complete -c cmux -n '__cmux_command_is dismiss-notification' -l all-read
complete -c cmux -n '__cmux_command_is dismiss-notification' -l id
complete -c cmux -n '__cmux_command_is display-message' -l print
complete -c cmux -n '__cmux_command_is docs' -f -a 'agents'
complete -c cmux -n '__cmux_command_is docs' -f -a 'api'
complete -c cmux -n '__cmux_command_is docs' -f -a 'browser'
complete -c cmux -n '__cmux_command_is docs' -f -a 'dock'
complete -c cmux -n '__cmux_command_is docs' -f -a 'settings'
complete -c cmux -n '__cmux_command_is docs' -f -a 'shortcuts'
complete -c cmux -n '__cmux_command_is docs' -f -a 'sidebars'
complete -c cmux -n '__cmux_command_is drag-surface-to-split' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is drag-surface-to-split' -l surface
complete -c cmux -n '__cmux_command_is drag-surface-to-split' -l window
complete -c cmux -n '__cmux_command_is drag-surface-to-split' -l workspace
complete -c cmux -n '__cmux_command_is events' -l after
complete -c cmux -n '__cmux_command_is events' -l category
complete -c cmux -n '__cmux_command_is events' -l cursor-file
complete -c cmux -n '__cmux_command_is events' -l limit
complete -c cmux -n '__cmux_command_is events' -l name
complete -c cmux -n '__cmux_command_is events' -l no-ack
complete -c cmux -n '__cmux_command_is events' -l no-heartbeat
complete -c cmux -n '__cmux_command_is events' -l reconnect
complete -c cmux -n '__cmux_command_is feed' -f -a 'clear'
complete -c cmux -n '__cmux_command_is feed' -f -a 'tui'
complete -c cmux -n '__cmux_command_is feedback' -l body
complete -c cmux -n '__cmux_command_is feedback' -l email
complete -c cmux -n '__cmux_command_is feedback' -l image
complete -c cmux -n '__cmux_command_is find-window' -l content
complete -c cmux -n '__cmux_command_is find-window' -l select
complete -c cmux -n '__cmux_command_is find-window' -l window
complete -c cmux -n '__cmux_command_is focus-pane' -l pane
complete -c cmux -n '__cmux_command_is focus-pane' -l window
complete -c cmux -n '__cmux_command_is focus-pane' -l workspace
complete -c cmux -n '__cmux_command_is focus-panel' -l panel
complete -c cmux -n '__cmux_command_is focus-panel' -l window
complete -c cmux -n '__cmux_command_is focus-panel' -l workspace
complete -c cmux -n '__cmux_command_is focus-window' -l window
complete -c cmux -n '__cmux_command_is hooks' -f -a 'feed'
complete -c cmux -n '__cmux_command_is hooks' -f -a 'setup'
complete -c cmux -n '__cmux_command_is hooks' -f -a 'uninstall'
complete -c cmux -n '__cmux_command_is hooks' -l agent
complete -c cmux -n '__cmux_command_is hooks' -l event
complete -c cmux -n '__cmux_command_is hooks' -l project
complete -c cmux -n '__cmux_command_is hooks' -l source
complete -c cmux -n '__cmux_command_is identify' -l no-caller
complete -c cmux -n '__cmux_command_is identify' -l surface
complete -c cmux -n '__cmux_command_is identify' -l window
complete -c cmux -n '__cmux_command_is identify' -l workspace
complete -c cmux -n '__cmux_command_is join-pane' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is join-pane' -l no-focus
complete -c cmux -n '__cmux_command_is join-pane' -l pane
complete -c cmux -n '__cmux_command_is join-pane' -l surface
complete -c cmux -n '__cmux_command_is join-pane' -l target-pane
complete -c cmux -n '__cmux_command_is join-pane' -l window
complete -c cmux -n '__cmux_command_is join-pane' -l workspace
complete -c cmux -n '__cmux_command_is last-pane' -l window
complete -c cmux -n '__cmux_command_is last-pane' -l workspace
complete -c cmux -n '__cmux_command_is last-window' -l window
complete -c cmux -n '__cmux_command_is list-log' -l limit
complete -c cmux -n '__cmux_command_is list-log' -l window
complete -c cmux -n '__cmux_command_is list-log' -l workspace
complete -c cmux -n '__cmux_command_is list-pane-surfaces' -l pane
complete -c cmux -n '__cmux_command_is list-pane-surfaces' -l window
complete -c cmux -n '__cmux_command_is list-pane-surfaces' -l workspace
complete -c cmux -n '__cmux_command_is list-panels' -l window
complete -c cmux -n '__cmux_command_is list-panels' -l workspace
complete -c cmux -n '__cmux_command_is list-panes' -l window
complete -c cmux -n '__cmux_command_is list-panes' -l workspace
complete -c cmux -n '__cmux_command_is list-status' -l window
complete -c cmux -n '__cmux_command_is list-status' -l workspace
complete -c cmux -n '__cmux_command_is list-workspaces' -l window
complete -c cmux -n '__cmux_command_is log' -l level
complete -c cmux -n '__cmux_command_is log' -l source
complete -c cmux -n '__cmux_command_is log' -l window
complete -c cmux -n '__cmux_command_is log' -l workspace
complete -c cmux -n '__cmux_command_is mark-notification-read' -l all
complete -c cmux -n '__cmux_command_is mark-notification-read' -l id
complete -c cmux -n '__cmux_command_is mark-notification-read' -l surface
complete -c cmux -n '__cmux_command_is mark-notification-read' -l window
complete -c cmux -n '__cmux_command_is mark-notification-read' -l workspace
complete -c cmux -n '__cmux_command_is markdown' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is memory' -l all
complete -c cmux -n '__cmux_command_is memory' -l groups
complete -c cmux -n '__cmux_command_is memory' -l workspace
complete -c cmux -n '__cmux_command_is move-surface' -l after
complete -c cmux -n '__cmux_command_is move-surface' -l before
complete -c cmux -n '__cmux_command_is move-surface' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is move-surface' -l index
complete -c cmux -n '__cmux_command_is move-surface' -l pane
complete -c cmux -n '__cmux_command_is move-surface' -l surface
complete -c cmux -n '__cmux_command_is move-surface' -l window
complete -c cmux -n '__cmux_command_is move-surface' -l workspace
complete -c cmux -n '__cmux_command_is move-tab-to-new-workspace' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is move-tab-to-new-workspace' -l surface
complete -c cmux -n '__cmux_command_is move-tab-to-new-workspace' -l tab
complete -c cmux -n '__cmux_command_is move-tab-to-new-workspace' -l title
complete -c cmux -n '__cmux_command_is move-tab-to-new-workspace' -l window
complete -c cmux -n '__cmux_command_is move-tab-to-new-workspace' -l workspace
complete -c cmux -n '__cmux_command_is move-workspace-to-window' -l window
complete -c cmux -n '__cmux_command_is move-workspace-to-window' -l workspace
complete -c cmux -n '__cmux_command_is new-pane' -l direction -f -a 'left right up down'
complete -c cmux -n '__cmux_command_is new-pane' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is new-pane' -l type -f -a 'terminal browser'
complete -c cmux -n '__cmux_command_is new-pane' -l url
complete -c cmux -n '__cmux_command_is new-pane' -l window
complete -c cmux -n '__cmux_command_is new-pane' -l workspace
complete -c cmux -n '__cmux_command_is new-split' -f -a 'down'
complete -c cmux -n '__cmux_command_is new-split' -f -a 'left'
complete -c cmux -n '__cmux_command_is new-split' -f -a 'right'
complete -c cmux -n '__cmux_command_is new-split' -f -a 'up'
complete -c cmux -n '__cmux_command_is new-split' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is new-split' -l panel
complete -c cmux -n '__cmux_command_is new-split' -l surface
complete -c cmux -n '__cmux_command_is new-split' -l window
complete -c cmux -n '__cmux_command_is new-split' -l workspace
complete -c cmux -n '__cmux_command_is new-surface' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is new-surface' -l pane
complete -c cmux -n '__cmux_command_is new-surface' -l provider -f -a 'codex claude opencode'
complete -c cmux -n '__cmux_command_is new-surface' -l renderer -f -a 'react solid'
complete -c cmux -n '__cmux_command_is new-surface' -l type -f -a 'terminal browser agent-session'
complete -c cmux -n '__cmux_command_is new-surface' -l url
complete -c cmux -n '__cmux_command_is new-surface' -l window
complete -c cmux -n '__cmux_command_is new-surface' -l workspace
complete -c cmux -n '__cmux_command_is new-workspace' -l command
complete -c cmux -n '__cmux_command_is new-workspace' -l cwd
complete -c cmux -n '__cmux_command_is new-workspace' -l description
complete -c cmux -n '__cmux_command_is new-workspace' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is new-workspace' -l group
complete -c cmux -n '__cmux_command_is new-workspace' -l group-placement
complete -c cmux -n '__cmux_command_is new-workspace' -l group-reference
complete -c cmux -n '__cmux_command_is new-workspace' -l layout
complete -c cmux -n '__cmux_command_is new-workspace' -l name
complete -c cmux -n '__cmux_command_is new-workspace' -l window
complete -c cmux -n '__cmux_command_is next-window' -l window
complete -c cmux -n '__cmux_command_is notify' -l body
complete -c cmux -n '__cmux_command_is notify' -l subtitle
complete -c cmux -n '__cmux_command_is notify' -l surface
complete -c cmux -n '__cmux_command_is notify' -l title
complete -c cmux -n '__cmux_command_is notify' -l window
complete -c cmux -n '__cmux_command_is notify' -l workspace
complete -c cmux -n '__cmux_command_is open' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is open' -l no-focus
complete -c cmux -n '__cmux_command_is open' -l pane
complete -c cmux -n '__cmux_command_is open' -l surface
complete -c cmux -n '__cmux_command_is open' -l window
complete -c cmux -n '__cmux_command_is open' -l workspace
complete -c cmux -n '__cmux_command_is open-notification' -l id
complete -c cmux -n '__cmux_command_is paste-buffer' -l name
complete -c cmux -n '__cmux_command_is paste-buffer' -l surface
complete -c cmux -n '__cmux_command_is paste-buffer' -l window
complete -c cmux -n '__cmux_command_is paste-buffer' -l workspace
complete -c cmux -n '__cmux_command_is pipe-pane' -l command
complete -c cmux -n '__cmux_command_is pipe-pane' -l surface
complete -c cmux -n '__cmux_command_is pipe-pane' -l window
complete -c cmux -n '__cmux_command_is pipe-pane' -l workspace
complete -c cmux -n '__cmux_command_is previous-window' -l window
complete -c cmux -n '__cmux_command_is read-screen' -l lines
complete -c cmux -n '__cmux_command_is read-screen' -l scrollback
complete -c cmux -n '__cmux_command_is read-screen' -l surface
complete -c cmux -n '__cmux_command_is read-screen' -l window
complete -c cmux -n '__cmux_command_is read-screen' -l workspace
complete -c cmux -n '__cmux_command_is remote' -f -a 'add'
complete -c cmux -n '__cmux_command_is remote' -f -a 'list'
complete -c cmux -n '__cmux_command_is remote' -f -a 'remove'
complete -c cmux -n '__cmux_command_is remote' -l json
complete -c cmux -n '__cmux_command_is remote' -l route
complete -c cmux -n '__cmux_command_is remote' -l tag
complete -c cmux -n '__cmux_command_is remote-daemon-status' -l arch -f -a 'arm64 amd64'
complete -c cmux -n '__cmux_command_is remote-daemon-status' -l os -f -a 'darwin linux'
complete -c cmux -n '__cmux_command_is remotes' -f -a 'add'
complete -c cmux -n '__cmux_command_is remotes' -f -a 'list'
complete -c cmux -n '__cmux_command_is remotes' -f -a 'remove'
complete -c cmux -n '__cmux_command_is remotes' -l json
complete -c cmux -n '__cmux_command_is remotes' -l route
complete -c cmux -n '__cmux_command_is remotes' -l tag
complete -c cmux -n '__cmux_command_is rename-tab' -l surface
complete -c cmux -n '__cmux_command_is rename-tab' -l tab
complete -c cmux -n '__cmux_command_is rename-tab' -l window
complete -c cmux -n '__cmux_command_is rename-tab' -l workspace
complete -c cmux -n '__cmux_command_is rename-window' -l window
complete -c cmux -n '__cmux_command_is rename-window' -l workspace
complete -c cmux -n '__cmux_command_is rename-workspace' -l window
complete -c cmux -n '__cmux_command_is rename-workspace' -l workspace
complete -c cmux -n '__cmux_command_is reorder-surface' -l after
complete -c cmux -n '__cmux_command_is reorder-surface' -l before
complete -c cmux -n '__cmux_command_is reorder-surface' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is reorder-surface' -l index
complete -c cmux -n '__cmux_command_is reorder-surface' -l surface
complete -c cmux -n '__cmux_command_is reorder-surface' -l window
complete -c cmux -n '__cmux_command_is reorder-surface' -l workspace
complete -c cmux -n '__cmux_command_is reorder-workspace' -l after
complete -c cmux -n '__cmux_command_is reorder-workspace' -l before
complete -c cmux -n '__cmux_command_is reorder-workspace' -l dry-run
complete -c cmux -n '__cmux_command_is reorder-workspace' -l index
complete -c cmux -n '__cmux_command_is reorder-workspace' -l window
complete -c cmux -n '__cmux_command_is reorder-workspace' -l workspace
complete -c cmux -n '__cmux_command_is reorder-workspaces' -l dry-run
complete -c cmux -n '__cmux_command_is reorder-workspaces' -l order
complete -c cmux -n '__cmux_command_is reorder-workspaces' -l window
complete -c cmux -n '__cmux_command_is resize-pane' -l amount
complete -c cmux -n '__cmux_command_is resize-pane' -l pane
complete -c cmux -n '__cmux_command_is resize-pane' -l window
complete -c cmux -n '__cmux_command_is resize-pane' -l workspace
complete -c cmux -n '__cmux_command_is respawn-pane' -l command
complete -c cmux -n '__cmux_command_is respawn-pane' -l surface
complete -c cmux -n '__cmux_command_is respawn-pane' -l window
complete -c cmux -n '__cmux_command_is respawn-pane' -l workspace
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'dock'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'feed'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'files'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'find'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'focus'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'hide'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'mode'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'sessions'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'set'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'show'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'toggle'
complete -c cmux -n '__cmux_command_is right-sidebar' -f -a 'vault'
complete -c cmux -n '__cmux_command_is right-sidebar' -l no-focus
complete -c cmux -n '__cmux_command_is right-sidebar' -l window
complete -c cmux -n '__cmux_command_is right-sidebar' -l workspace
complete -c cmux -n '__cmux_command_is select-workspace' -l window
complete -c cmux -n '__cmux_command_is select-workspace' -l workspace
complete -c cmux -n '__cmux_command_is send' -l surface
complete -c cmux -n '__cmux_command_is send' -l window
complete -c cmux -n '__cmux_command_is send' -l workspace
complete -c cmux -n '__cmux_command_is send-key' -l surface
complete -c cmux -n '__cmux_command_is send-key' -l window
complete -c cmux -n '__cmux_command_is send-key' -l workspace
complete -c cmux -n '__cmux_command_is send-key-panel' -l panel
complete -c cmux -n '__cmux_command_is send-key-panel' -l window
complete -c cmux -n '__cmux_command_is send-key-panel' -l workspace
complete -c cmux -n '__cmux_command_is send-panel' -l panel
complete -c cmux -n '__cmux_command_is send-panel' -l window
complete -c cmux -n '__cmux_command_is send-panel' -l workspace
complete -c cmux -n '__cmux_command_is set-app-focus' -f -a 'active'
complete -c cmux -n '__cmux_command_is set-app-focus' -f -a 'clear'
complete -c cmux -n '__cmux_command_is set-app-focus' -f -a 'inactive'
complete -c cmux -n '__cmux_command_is set-buffer' -l name
complete -c cmux -n '__cmux_command_is set-hook' -l list
complete -c cmux -n '__cmux_command_is set-hook' -l unset
complete -c cmux -n '__cmux_command_is set-progress' -l label
complete -c cmux -n '__cmux_command_is set-progress' -l window
complete -c cmux -n '__cmux_command_is set-progress' -l workspace
complete -c cmux -n '__cmux_command_is set-status' -l color
complete -c cmux -n '__cmux_command_is set-status' -l icon
complete -c cmux -n '__cmux_command_is set-status' -l priority
complete -c cmux -n '__cmux_command_is set-status' -l window
complete -c cmux -n '__cmux_command_is set-status' -l workspace
complete -c cmux -n '__cmux_command_is sidebar' -f -a 'open'
complete -c cmux -n '__cmux_command_is sidebar' -f -a 'reload'
complete -c cmux -n '__cmux_command_is sidebar' -f -a 'select'
complete -c cmux -n '__cmux_command_is sidebar' -f -a 'validate'
complete -c cmux -n '__cmux_command_is sidebar-state' -l window
complete -c cmux -n '__cmux_command_is sidebar-state' -l workspace
complete -c cmux -n '__cmux_command_is simulate-sidebar-drag' -l duration-ms
complete -c cmux -n '__cmux_command_is simulate-sidebar-drag' -l from
complete -c cmux -n '__cmux_command_is simulate-sidebar-drag' -l steps
complete -c cmux -n '__cmux_command_is simulate-sidebar-drag' -l to
complete -c cmux -n '__cmux_command_is simulate-sidebar-drag' -l window
complete -c cmux -n '__cmux_command_is split-off' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is split-off' -l surface
complete -c cmux -n '__cmux_command_is split-off' -l window
complete -c cmux -n '__cmux_command_is split-off' -l workspace
complete -c cmux -n '__cmux_command_is ssh' -l forward-agent
complete -c cmux -n '__cmux_command_is ssh' -l identity
complete -c cmux -n '__cmux_command_is ssh' -l name
complete -c cmux -n '__cmux_command_is ssh' -l no-focus
complete -c cmux -n '__cmux_command_is ssh' -l no-forward-agent
complete -c cmux -n '__cmux_command_is ssh' -l port
complete -c cmux -n '__cmux_command_is ssh' -l ssh-option
complete -c cmux -n '__cmux_command_is ssh' -l window
complete -c cmux -n '__cmux_command_is ssh-session-attach' -l pane
complete -c cmux -n '__cmux_command_is ssh-session-attach' -l session-id
complete -c cmux -n '__cmux_command_is ssh-session-attach' -l split -f -a 'left right up down'
complete -c cmux -n '__cmux_command_is ssh-session-attach' -l workspace
complete -c cmux -n '__cmux_command_is ssh-session-cleanup' -l all
complete -c cmux -n '__cmux_command_is ssh-session-cleanup' -l all-workspaces
complete -c cmux -n '__cmux_command_is ssh-session-cleanup' -l session-id
complete -c cmux -n '__cmux_command_is ssh-session-cleanup' -l workspace
complete -c cmux -n '__cmux_command_is ssh-session-list' -l all-workspaces
complete -c cmux -n '__cmux_command_is ssh-session-list' -l workspace
complete -c cmux -n '__cmux_command_is ssh-tmux' -l identity
complete -c cmux -n '__cmux_command_is ssh-tmux' -l no-focus
complete -c cmux -n '__cmux_command_is ssh-tmux' -l port
complete -c cmux -n '__cmux_command_is surface' -f -a 'resume'
complete -c cmux -n '__cmux_command_is surface' -l surface
complete -c cmux -n '__cmux_command_is surface' -l window
complete -c cmux -n '__cmux_command_is surface' -l workspace
complete -c cmux -n '__cmux_command_is surface-health' -l window
complete -c cmux -n '__cmux_command_is surface-health' -l workspace
complete -c cmux -n '__cmux_command_is swap-pane' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is swap-pane' -l pane
complete -c cmux -n '__cmux_command_is swap-pane' -l target-pane
complete -c cmux -n '__cmux_command_is swap-pane' -l window
complete -c cmux -n '__cmux_command_is swap-pane' -l workspace
complete -c cmux -n '__cmux_command_is tab-action' -l action
complete -c cmux -n '__cmux_command_is tab-action' -l focus -f -a 'true false'
complete -c cmux -n '__cmux_command_is tab-action' -l surface
complete -c cmux -n '__cmux_command_is tab-action' -l tab
complete -c cmux -n '__cmux_command_is tab-action' -l title
complete -c cmux -n '__cmux_command_is tab-action' -l url
complete -c cmux -n '__cmux_command_is tab-action' -l window
complete -c cmux -n '__cmux_command_is tab-action' -l workspace
complete -c cmux -n '__cmux_command_is themes' -f -a 'clear'
complete -c cmux -n '__cmux_command_is themes' -f -a 'list'
complete -c cmux -n '__cmux_command_is themes' -f -a 'set'
complete -c cmux -n '__cmux_command_is top' -l all
complete -c cmux -n '__cmux_command_is top' -l flat
complete -c cmux -n '__cmux_command_is top' -l format -f -a 'tree tsv'
complete -c cmux -n '__cmux_command_is top' -l processes
complete -c cmux -n '__cmux_command_is top' -l sort -f -a 'cpu mem proc'
complete -c cmux -n '__cmux_command_is top' -l window
complete -c cmux -n '__cmux_command_is top' -l workspace
complete -c cmux -n '__cmux_command_is tree' -l all
complete -c cmux -n '__cmux_command_is tree' -l window
complete -c cmux -n '__cmux_command_is tree' -l workspace
complete -c cmux -n '__cmux_command_is trigger-flash' -l surface
complete -c cmux -n '__cmux_command_is trigger-flash' -l window
complete -c cmux -n '__cmux_command_is trigger-flash' -l workspace
complete -c cmux -n '__cmux_command_is vm' -f -a 'exec'
complete -c cmux -n '__cmux_command_is vm' -f -a 'ls'
complete -c cmux -n '__cmux_command_is vm' -f -a 'new'
complete -c cmux -n '__cmux_command_is vm' -f -a 'rm'
complete -c cmux -n '__cmux_command_is vm' -f -a 'shell'
complete -c cmux -n '__cmux_command_is vm' -f -a 'ssh'
complete -c cmux -n '__cmux_command_is wait-for' -l signal
complete -c cmux -n '__cmux_command_is wait-for' -l timeout
complete -c cmux -n '__cmux_command_is workspace-action' -l action
complete -c cmux -n '__cmux_command_is workspace-action' -l color
complete -c cmux -n '__cmux_command_is workspace-action' -l description
complete -c cmux -n '__cmux_command_is workspace-action' -l title
complete -c cmux -n '__cmux_command_is workspace-action' -l window
complete -c cmux -n '__cmux_command_is workspace-action' -l workspace
