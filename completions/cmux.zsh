#compdef cmux
# cmux shell completions (zsh) -- AUTO-GENERATED, DO NOT EDIT.
#
# Regenerate with:  scripts/generate-cli-completions.py --write
# Source of truth:  topLevelCommandNames in CLI/cmux.swift + its usage() help.

_cmux() {
    local context state line
    local -a commands
    commands=(
        'agent-hibernation'
        'auth'
        'bind-key'
        'break-pane'
        'browser'
        'browser-back'
        'browser-forward'
        'browser-reload'
        'browser-status'
        'capabilities'
        'capture-pane'
        'claude-teams'
        'clear-history'
        'clear-log'
        'clear-notifications'
        'clear-progress'
        'clear-status'
        'close-surface'
        'close-window'
        'close-workspace'
        'cloud'
        'codex'
        'codex-teams'
        'config'
        'copy-mode'
        'current-window'
        'current-workspace'
        'debug-terminals'
        'detach-tab'
        'diff'
        'disable-browser'
        'dismiss-notification'
        'display-message'
        'docs'
        'drag-surface-to-split'
        'enable-browser'
        'events'
        'feed'
        'feedback'
        'find-window'
        'focus-pane'
        'focus-panel'
        'focus-webview'
        'focus-window'
        'get-url'
        'help'
        'hooks'
        'identify'
        'is-webview-focused'
        'join-pane'
        'jump-to-unread'
        'last-pane'
        'last-window'
        'list-buffers'
        'list-log'
        'list-notifications'
        'list-pane-surfaces'
        'list-panels'
        'list-panes'
        'list-status'
        'list-windows'
        'list-workspaces'
        'log'
        'login'
        'logout'
        'mark-notification-read'
        'markdown'
        'memory'
        'mobile'
        'move-surface'
        'move-tab-to-new-workspace'
        'move-workspace-to-window'
        'navigate'
        'new-pane'
        'new-split'
        'new-surface'
        'new-window'
        'new-workspace'
        'next-window'
        'notify'
        'omc'
        'omo'
        'omx'
        'open'
        'open-browser'
        'open-notification'
        'paste-buffer'
        'ping'
        'pipe-pane'
        'popup'
        'previous-window'
        'read-screen'
        'refresh-surfaces'
        'reload-config'
        'remote-daemon-status'
        'rename-tab'
        'rename-window'
        'rename-workspace'
        'reorder-surface'
        'reorder-workspace'
        'reorder-workspaces'
        'resize-pane'
        'respawn-pane'
        'restore-session'
        'right-sidebar'
        'rpc'
        'select-workspace'
        'send'
        'send-key'
        'send-key-panel'
        'send-panel'
        'set-app-focus'
        'set-buffer'
        'set-progress'
        'set-status'
        'settings'
        'shortcuts'
        'sidebar'
        'sidebar-state'
        'simulate-app-active'
        'split-off'
        'ssh'
        'ssh-session-attach'
        'ssh-session-cleanup'
        'ssh-session-list'
        'ssh-tmux'
        'surface'
        'surface-health'
        'surface-resume'
        'swap-pane'
        'tab-action'
        'themes'
        'top'
        'tree'
        'trigger-flash'
        'unbind-key'
        'version'
        'vm'
        'wait-for'
        'welcome'
        'workspace'
        'workspace-action'
        'workspace-group'
    )
    if (( CURRENT == 2 )); then
        _describe -t commands 'cmux command' commands
        return
    fi
    local cmd=${words[2]}
    case $cmd in
        agent-hibernation)
            compadd -- off on ;;
        auth)
            compadd -- login logout status ;;
        break-pane)
            compadd -- --focus --no-focus --pane --surface --window --workspace ;;
        browser)
            compadd -- addinitscript addscript addstyle console cookies devtools dialog disable download errors eval fill find focus-mode frame get highlight history identify import is open open-split profiles react-grab screenshot scroll select snapshot state storage tab type wait zoom --all --compact --cursor --dx --dy --focus --force --function --interactive --json --load-state --max-depth --out --path --return-to --selector --snapshot-after --surface --text --timeout-ms --url-contains ;;
        capture-pane)
            compadd -- --lines --scrollback --surface --window --workspace ;;
        clear-history)
            compadd -- --surface --window --workspace ;;
        clear-log)
            compadd -- --window --workspace ;;
        clear-notifications)
            compadd -- --window --workspace ;;
        clear-progress)
            compadd -- --window --workspace ;;
        clear-status)
            compadd -- --window --workspace ;;
        close-surface)
            compadd -- --surface --window --workspace ;;
        close-window)
            compadd -- --window ;;
        close-workspace)
            compadd -- --window --workspace ;;
        current-workspace)
            compadd -- --window ;;
        diff)
            compadd -- --base --branch --cwd --focus --font-size --last-turn --layout --no-focus --source --staged --surface --title --unstaged --window --workspace ;;
        dismiss-notification)
            compadd -- --all-read --id ;;
        display-message)
            compadd -- --print ;;
        docs)
            compadd -- agents api browser dock settings shortcuts sidebars ;;
        drag-surface-to-split)
            compadd -- --focus --surface --window --workspace ;;
        events)
            compadd -- --after --category --cursor-file --limit --name --no-ack --no-heartbeat --reconnect ;;
        feedback)
            compadd -- --body --email --image ;;
        find-window)
            compadd -- --content --select --window ;;
        focus-pane)
            compadd -- --pane --window --workspace ;;
        focus-panel)
            compadd -- --panel --window --workspace ;;
        focus-window)
            compadd -- --window ;;
        hooks)
            compadd -- feed --agent --event --project --source ;;
        identify)
            compadd -- --no-caller --surface --window --workspace ;;
        join-pane)
            compadd -- --focus --no-focus --pane --surface --target-pane --window --workspace ;;
        last-pane)
            compadd -- --window --workspace ;;
        last-window)
            compadd -- --window ;;
        list-log)
            compadd -- --limit --window --workspace ;;
        list-pane-surfaces)
            compadd -- --pane --window --workspace ;;
        list-panels)
            compadd -- --window --workspace ;;
        list-panes)
            compadd -- --window --workspace ;;
        list-status)
            compadd -- --window --workspace ;;
        list-workspaces)
            compadd -- --window ;;
        log)
            compadd -- --level --source --window --workspace ;;
        mark-notification-read)
            compadd -- --all --id --surface --window --workspace ;;
        markdown)
            compadd -- --focus ;;
        memory)
            compadd -- --all --groups --workspace ;;
        move-surface)
            compadd -- --after --before --focus --index --pane --surface --window --workspace ;;
        move-tab-to-new-workspace)
            compadd -- --focus --surface --tab --title --window --workspace ;;
        move-workspace-to-window)
            compadd -- --window --workspace ;;
        new-pane)
            compadd -- --direction --focus --type --url --window --workspace ;;
        new-split)
            compadd -- down left right up --focus --panel --surface --window --workspace ;;
        new-surface)
            compadd -- --focus --pane --provider --renderer --type --url --window --workspace ;;
        new-workspace)
            compadd -- --command --cwd --description --focus --group --group-placement --group-reference --layout --name --window ;;
        next-window)
            compadd -- --window ;;
        notify)
            compadd -- --body --subtitle --surface --title --window --workspace ;;
        open)
            compadd -- --focus --no-focus --pane --surface --window --workspace ;;
        open-notification)
            compadd -- --id ;;
        paste-buffer)
            compadd -- --name --surface --window --workspace ;;
        pipe-pane)
            compadd -- --command --surface --window --workspace ;;
        previous-window)
            compadd -- --window ;;
        read-screen)
            compadd -- --lines --scrollback --surface --window --workspace ;;
        remote-daemon-status)
            compadd -- --arch --os ;;
        rename-tab)
            compadd -- --surface --tab --window --workspace ;;
        rename-window)
            compadd -- --window --workspace ;;
        rename-workspace)
            compadd -- --window --workspace ;;
        reorder-surface)
            compadd -- --after --before --focus --index --surface --window --workspace ;;
        reorder-workspace)
            compadd -- --after --before --dry-run --index --window --workspace ;;
        reorder-workspaces)
            compadd -- --dry-run --order --window ;;
        resize-pane)
            compadd -- --amount --pane --window --workspace ;;
        respawn-pane)
            compadd -- --command --surface --window --workspace ;;
        right-sidebar)
            compadd -- dock feed files find focus hide mode sessions set show toggle vault --no-focus --window --workspace ;;
        select-workspace)
            compadd -- --window --workspace ;;
        send)
            compadd -- --surface --window --workspace ;;
        send-key)
            compadd -- --surface --window --workspace ;;
        send-key-panel)
            compadd -- --panel --window --workspace ;;
        send-panel)
            compadd -- --panel --window --workspace ;;
        set-app-focus)
            compadd -- active clear inactive ;;
        set-buffer)
            compadd -- --name ;;
        set-progress)
            compadd -- --label --window --workspace ;;
        set-status)
            compadd -- --color --icon --priority --window --workspace ;;
        sidebar)
            compadd -- open reload select validate ;;
        sidebar-state)
            compadd -- --window --workspace ;;
        split-off)
            compadd -- --focus --surface --window --workspace ;;
        ssh)
            compadd -- --forward-agent --identity --name --no-focus --no-forward-agent --port --ssh-option --window ;;
        ssh-session-attach)
            compadd -- --pane --session-id --split --workspace ;;
        ssh-session-cleanup)
            compadd -- --all --all-workspaces --session-id --workspace ;;
        ssh-session-list)
            compadd -- --all-workspaces --workspace ;;
        ssh-tmux)
            compadd -- --identity --no-focus --port ;;
        surface)
            compadd -- resume --surface --window --workspace ;;
        surface-health)
            compadd -- --window --workspace ;;
        swap-pane)
            compadd -- --focus --pane --target-pane --window --workspace ;;
        tab-action)
            compadd -- --action --focus --surface --tab --title --url --window --workspace ;;
        themes)
            compadd -- clear list set ;;
        top)
            compadd -- --all --flat --format --processes --sort --window --workspace ;;
        tree)
            compadd -- --all --window --workspace ;;
        trigger-flash)
            compadd -- --surface --window --workspace ;;
        vm)
            compadd -- exec ls new rm shell ssh ;;
        wait-for)
            compadd -- --signal --timeout ;;
        workspace-action)
            compadd -- --action --color --description --title --window --workspace ;;
    esac
}
_cmux "$@"
