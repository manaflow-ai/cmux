#compdef cmux
# cmux shell completions (zsh) -- AUTO-GENERATED, DO NOT EDIT.
#
# Regenerate with:  scripts/generate-cli-completions.py --write
# Source of truth:  topLevelCommandNames in CLI/CMUXCLI+CommandSuggestions.swift + CLI/cmux.swift usage() help.

_cmux() {
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
        'remote'
        'remote-daemon-status'
        'remotes'
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
        'set-hook'
        'set-progress'
        'set-status'
        'settings'
        'shortcuts'
        'sidebar'
        'sidebar-state'
        'simulate-app-active'
        'simulate-sidebar-drag'
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
    local i cmd=""
    for (( i = 2; i < CURRENT; i++ )); do
        case ${words[i]} in
            --socket|--id-format|--window|--password) (( i++ )) ;;
            -*) ;;
            *) cmd=${words[i]}; break ;;
        esac
    done
    if [[ -z $cmd ]]; then
        _describe -t commands 'cmux command' commands
        return
    fi
    local prev=${words[CURRENT-1]}
    case $cmd in
        agent-hibernation)
            compadd -- off on ;;
        auth)
            compadd -- login logout status ;;
        break-pane)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --focus --no-focus --pane --surface --window --workspace ;;
        browser)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            if [[ $prev == --load-state ]]; then
                compadd -- interactive complete; return
            fi
            compadd -- addinitscript addscript addstyle back check click console cookies dblclick devtools dialog disable download enable errors eval fill find focus focus-mode forward frame get get-url goto highlight history hover identify import is keydown keyup navigate open open-split press profiles react-grab reload screenshot scroll scroll-into-view select snapshot state status storage tab type uncheck url wait zoom --all --compact --cursor --dx --dy --focus --force --function --interactive --json --load-state --max-depth --out --path --return-to --selector --snapshot-after --surface --text --timeout-ms --url-contains ;;
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
        cloud)
            compadd -- exec ls new rm shell ssh ;;
        config)
            compadd -- check docs doctor documentation path paths reload validate ;;
        current-workspace)
            compadd -- --window ;;
        diff)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            if [[ $prev == --layout ]]; then
                compadd -- split unified; return
            fi
            if [[ $prev == --source ]]; then
                compadd -- unstaged staged branch last-turn; return
            fi
            compadd -- --base --branch --cwd --focus --font-size --last-turn --layout --no-focus --source --staged --surface --title --unstaged --window --workspace ;;
        dismiss-notification)
            compadd -- --all-read --id ;;
        display-message)
            compadd -- --print ;;
        docs)
            compadd -- agents api browser dock settings shortcuts sidebars ;;
        drag-surface-to-split)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --focus --surface --window --workspace ;;
        events)
            compadd -- --after --category --cursor-file --limit --name --no-ack --no-heartbeat --reconnect ;;
        feed)
            compadd -- clear tui ;;
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
            compadd -- feed setup uninstall --agent --event --project --source ;;
        identify)
            compadd -- --no-caller --surface --window --workspace ;;
        join-pane)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
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
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- open --focus ;;
        memory)
            compadd -- --all --groups --workspace ;;
        move-surface)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --after --before --focus --index --pane --surface --window --workspace ;;
        move-tab-to-new-workspace)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --focus --surface --tab --title --window --workspace ;;
        move-workspace-to-window)
            compadd -- --window --workspace ;;
        new-pane)
            if [[ $prev == --direction ]]; then
                compadd -- left right up down; return
            fi
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            if [[ $prev == --type ]]; then
                compadd -- terminal browser; return
            fi
            compadd -- --direction --focus --type --url --window --workspace ;;
        new-split)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- down left right up --focus --panel --surface --window --workspace ;;
        new-surface)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            if [[ $prev == --provider ]]; then
                compadd -- codex claude opencode; return
            fi
            if [[ $prev == --renderer ]]; then
                compadd -- react solid; return
            fi
            if [[ $prev == --type ]]; then
                compadd -- terminal browser agent-session; return
            fi
            compadd -- --focus --pane --provider --renderer --type --url --window --workspace ;;
        new-workspace)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --command --cwd --description --focus --group --group-placement --group-reference --layout --name --window ;;
        next-window)
            compadd -- --window ;;
        notify)
            compadd -- --body --subtitle --surface --title --window --workspace ;;
        open)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
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
        remote)
            compadd -- add list remove --json --route --tag ;;
        remote-daemon-status)
            if [[ $prev == --arch ]]; then
                compadd -- arm64 amd64; return
            fi
            if [[ $prev == --os ]]; then
                compadd -- darwin linux; return
            fi
            compadd -- --arch --os ;;
        remotes)
            compadd -- add list remove --json --route --tag ;;
        rename-tab)
            compadd -- --surface --tab --window --workspace ;;
        rename-window)
            compadd -- --window --workspace ;;
        rename-workspace)
            compadd -- --window --workspace ;;
        reorder-surface)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
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
        set-hook)
            compadd -- --list --unset ;;
        set-progress)
            compadd -- --label --window --workspace ;;
        set-status)
            compadd -- --color --icon --priority --window --workspace ;;
        settings)
            compadd -- docs open path ;;
        sidebar)
            compadd -- open reload select validate ;;
        sidebar-state)
            compadd -- --window --workspace ;;
        simulate-sidebar-drag)
            compadd -- --duration-ms --from --steps --to --window ;;
        split-off)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --focus --surface --window --workspace ;;
        ssh)
            compadd -- --forward-agent --identity --name --no-focus --no-forward-agent --port --ssh-option --window ;;
        ssh-session-attach)
            if [[ $prev == --split ]]; then
                compadd -- left right up down; return
            fi
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
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --focus --pane --target-pane --window --workspace ;;
        tab-action)
            if [[ $prev == --focus ]]; then
                compadd -- true false; return
            fi
            compadd -- --action --focus --surface --tab --title --url --window --workspace ;;
        themes)
            compadd -- clear list set ;;
        top)
            if [[ $prev == --format ]]; then
                compadd -- tree tsv; return
            fi
            if [[ $prev == --sort ]]; then
                compadd -- cpu mem proc; return
            fi
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
