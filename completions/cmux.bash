# cmux shell completions (bash) -- AUTO-GENERATED, DO NOT EDIT.
#
# Regenerate with:  scripts/generate-cli-completions.py --write
# Source of truth:  topLevelCommandNames in CLI/cmux.swift + its usage() help.

_cmux() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        cword=$COMP_CWORD
    }
    # Locate the command word (first non-option after `cmux`).
    local i cmd=""
    for ((i=1; i < COMP_CWORD; i++)); do
        case "${COMP_WORDS[i]}" in
            -*) ;;
            *) cmd="${COMP_WORDS[i]}"; break ;;
        esac
    done
    local commands="agent-hibernation auth bind-key break-pane browser browser-back browser-forward browser-reload browser-status capabilities capture-pane claude-teams clear-history clear-log clear-notifications clear-progress clear-status close-surface close-window close-workspace cloud codex codex-teams config copy-mode current-window current-workspace debug-terminals detach-tab diff disable-browser dismiss-notification display-message docs drag-surface-to-split enable-browser events feed feedback find-window focus-pane focus-panel focus-webview focus-window get-url help hooks identify is-webview-focused join-pane jump-to-unread last-pane last-window list-buffers list-log list-notifications list-pane-surfaces list-panels list-panes list-status list-windows list-workspaces log login logout mark-notification-read markdown memory mobile move-surface move-tab-to-new-workspace move-workspace-to-window navigate new-pane new-split new-surface new-window new-workspace next-window notify omc omo omx open open-browser open-notification paste-buffer ping pipe-pane popup previous-window read-screen refresh-surfaces reload-config remote remote-daemon-status remotes rename-tab rename-window rename-workspace reorder-surface reorder-workspace reorder-workspaces resize-pane respawn-pane restore-session right-sidebar rpc select-workspace send send-key send-key-panel send-panel set-app-focus set-buffer set-progress set-status settings shortcuts sidebar sidebar-state simulate-app-active simulate-sidebar-drag split-off ssh ssh-session-attach ssh-session-cleanup ssh-session-list ssh-tmux surface surface-health surface-resume swap-pane tab-action themes top tree trigger-flash unbind-key version vm wait-for welcome workspace workspace-action workspace-group"
    if [[ -z $cmd ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
    fi
    case "$cmd" in
        agent-hibernation)
            COMPREPLY=( $(compgen -W "off on" -- "$cur") ); return ;;
        auth)
            COMPREPLY=( $(compgen -W "login logout status" -- "$cur") ); return ;;
        break-pane)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --no-focus --pane --surface --window --workspace" -- "$cur") ); return ;;
        browser)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            if [[ $prev == --load-state ]]; then
                COMPREPLY=( $(compgen -W "interactive complete" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "addinitscript addscript addstyle back check click console cookies dblclick devtools dialog disable download errors eval fill find focus focus-mode forward frame get get-url goto highlight history hover identify import is keydown keyup navigate open open-split press profiles react-grab reload screenshot scroll scroll-into-view select snapshot state storage tab type uncheck url wait zoom --all --compact --cursor --dx --dy --focus --force --function --interactive --json --load-state --max-depth --out --path --return-to --selector --snapshot-after --surface --text --timeout-ms --url-contains" -- "$cur") ); return ;;
        capture-pane)
            COMPREPLY=( $(compgen -W "--lines --scrollback --surface --window --workspace" -- "$cur") ); return ;;
        clear-history)
            COMPREPLY=( $(compgen -W "--surface --window --workspace" -- "$cur") ); return ;;
        clear-log)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        clear-notifications)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        clear-progress)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        clear-status)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        close-surface)
            COMPREPLY=( $(compgen -W "--surface --window --workspace" -- "$cur") ); return ;;
        close-window)
            COMPREPLY=( $(compgen -W "--window" -- "$cur") ); return ;;
        close-workspace)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        current-workspace)
            COMPREPLY=( $(compgen -W "--window" -- "$cur") ); return ;;
        diff)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            if [[ $prev == --layout ]]; then
                COMPREPLY=( $(compgen -W "split unified" -- "$cur") ); return
            fi
            if [[ $prev == --source ]]; then
                COMPREPLY=( $(compgen -W "unstaged staged branch last-turn" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--base --branch --cwd --focus --font-size --last-turn --layout --no-focus --source --staged --surface --title --unstaged --window --workspace" -- "$cur") ); return ;;
        dismiss-notification)
            COMPREPLY=( $(compgen -W "--all-read --id" -- "$cur") ); return ;;
        display-message)
            COMPREPLY=( $(compgen -W "--print" -- "$cur") ); return ;;
        docs)
            COMPREPLY=( $(compgen -W "agents api browser dock settings shortcuts sidebars" -- "$cur") ); return ;;
        drag-surface-to-split)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --surface --window --workspace" -- "$cur") ); return ;;
        events)
            COMPREPLY=( $(compgen -W "--after --category --cursor-file --limit --name --no-ack --no-heartbeat --reconnect" -- "$cur") ); return ;;
        feed)
            COMPREPLY=( $(compgen -W "clear tui" -- "$cur") ); return ;;
        feedback)
            COMPREPLY=( $(compgen -W "--body --email --image" -- "$cur") ); return ;;
        find-window)
            COMPREPLY=( $(compgen -W "--content --select --window" -- "$cur") ); return ;;
        focus-pane)
            COMPREPLY=( $(compgen -W "--pane --window --workspace" -- "$cur") ); return ;;
        focus-panel)
            COMPREPLY=( $(compgen -W "--panel --window --workspace" -- "$cur") ); return ;;
        focus-window)
            COMPREPLY=( $(compgen -W "--window" -- "$cur") ); return ;;
        hooks)
            COMPREPLY=( $(compgen -W "feed setup uninstall --agent --event --project --source" -- "$cur") ); return ;;
        identify)
            COMPREPLY=( $(compgen -W "--no-caller --surface --window --workspace" -- "$cur") ); return ;;
        join-pane)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --no-focus --pane --surface --target-pane --window --workspace" -- "$cur") ); return ;;
        last-pane)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        last-window)
            COMPREPLY=( $(compgen -W "--window" -- "$cur") ); return ;;
        list-log)
            COMPREPLY=( $(compgen -W "--limit --window --workspace" -- "$cur") ); return ;;
        list-pane-surfaces)
            COMPREPLY=( $(compgen -W "--pane --window --workspace" -- "$cur") ); return ;;
        list-panels)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        list-panes)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        list-status)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        list-workspaces)
            COMPREPLY=( $(compgen -W "--window" -- "$cur") ); return ;;
        log)
            COMPREPLY=( $(compgen -W "--level --source --window --workspace" -- "$cur") ); return ;;
        mark-notification-read)
            COMPREPLY=( $(compgen -W "--all --id --surface --window --workspace" -- "$cur") ); return ;;
        markdown)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus" -- "$cur") ); return ;;
        memory)
            COMPREPLY=( $(compgen -W "--all --groups --workspace" -- "$cur") ); return ;;
        move-surface)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--after --before --focus --index --pane --surface --window --workspace" -- "$cur") ); return ;;
        move-tab-to-new-workspace)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --surface --tab --title --window --workspace" -- "$cur") ); return ;;
        move-workspace-to-window)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        new-pane)
            if [[ $prev == --direction ]]; then
                COMPREPLY=( $(compgen -W "left right up down" -- "$cur") ); return
            fi
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            if [[ $prev == --type ]]; then
                COMPREPLY=( $(compgen -W "terminal browser" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--direction --focus --type --url --window --workspace" -- "$cur") ); return ;;
        new-split)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "down left right up --focus --panel --surface --window --workspace" -- "$cur") ); return ;;
        new-surface)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            if [[ $prev == --provider ]]; then
                COMPREPLY=( $(compgen -W "codex claude opencode" -- "$cur") ); return
            fi
            if [[ $prev == --renderer ]]; then
                COMPREPLY=( $(compgen -W "react solid" -- "$cur") ); return
            fi
            if [[ $prev == --type ]]; then
                COMPREPLY=( $(compgen -W "terminal browser agent-session" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --pane --provider --renderer --type --url --window --workspace" -- "$cur") ); return ;;
        new-workspace)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--command --cwd --description --focus --group --group-placement --group-reference --layout --name --window" -- "$cur") ); return ;;
        next-window)
            COMPREPLY=( $(compgen -W "--window" -- "$cur") ); return ;;
        notify)
            COMPREPLY=( $(compgen -W "--body --subtitle --surface --title --window --workspace" -- "$cur") ); return ;;
        open)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --no-focus --pane --surface --window --workspace" -- "$cur") ); return ;;
        open-notification)
            COMPREPLY=( $(compgen -W "--id" -- "$cur") ); return ;;
        paste-buffer)
            COMPREPLY=( $(compgen -W "--name --surface --window --workspace" -- "$cur") ); return ;;
        pipe-pane)
            COMPREPLY=( $(compgen -W "--command --surface --window --workspace" -- "$cur") ); return ;;
        previous-window)
            COMPREPLY=( $(compgen -W "--window" -- "$cur") ); return ;;
        read-screen)
            COMPREPLY=( $(compgen -W "--lines --scrollback --surface --window --workspace" -- "$cur") ); return ;;
        remote-daemon-status)
            if [[ $prev == --arch ]]; then
                COMPREPLY=( $(compgen -W "arm64 amd64" -- "$cur") ); return
            fi
            if [[ $prev == --os ]]; then
                COMPREPLY=( $(compgen -W "darwin linux" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--arch --os" -- "$cur") ); return ;;
        remotes)
            COMPREPLY=( $(compgen -W "add list remove --json --route --tag" -- "$cur") ); return ;;
        rename-tab)
            COMPREPLY=( $(compgen -W "--surface --tab --window --workspace" -- "$cur") ); return ;;
        rename-window)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        rename-workspace)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        reorder-surface)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--after --before --focus --index --surface --window --workspace" -- "$cur") ); return ;;
        reorder-workspace)
            COMPREPLY=( $(compgen -W "--after --before --dry-run --index --window --workspace" -- "$cur") ); return ;;
        reorder-workspaces)
            COMPREPLY=( $(compgen -W "--dry-run --order --window" -- "$cur") ); return ;;
        resize-pane)
            COMPREPLY=( $(compgen -W "--amount --pane --window --workspace" -- "$cur") ); return ;;
        respawn-pane)
            COMPREPLY=( $(compgen -W "--command --surface --window --workspace" -- "$cur") ); return ;;
        right-sidebar)
            COMPREPLY=( $(compgen -W "dock feed files find focus hide mode sessions set show toggle vault --no-focus --window --workspace" -- "$cur") ); return ;;
        select-workspace)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        send)
            COMPREPLY=( $(compgen -W "--surface --window --workspace" -- "$cur") ); return ;;
        send-key)
            COMPREPLY=( $(compgen -W "--surface --window --workspace" -- "$cur") ); return ;;
        send-key-panel)
            COMPREPLY=( $(compgen -W "--panel --window --workspace" -- "$cur") ); return ;;
        send-panel)
            COMPREPLY=( $(compgen -W "--panel --window --workspace" -- "$cur") ); return ;;
        set-app-focus)
            COMPREPLY=( $(compgen -W "active clear inactive" -- "$cur") ); return ;;
        set-buffer)
            COMPREPLY=( $(compgen -W "--name" -- "$cur") ); return ;;
        set-progress)
            COMPREPLY=( $(compgen -W "--label --window --workspace" -- "$cur") ); return ;;
        set-status)
            COMPREPLY=( $(compgen -W "--color --icon --priority --window --workspace" -- "$cur") ); return ;;
        sidebar)
            COMPREPLY=( $(compgen -W "open reload select validate" -- "$cur") ); return ;;
        sidebar-state)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        simulate-sidebar-drag)
            COMPREPLY=( $(compgen -W "--duration-ms --from --steps --to --window" -- "$cur") ); return ;;
        split-off)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --surface --window --workspace" -- "$cur") ); return ;;
        ssh)
            COMPREPLY=( $(compgen -W "--forward-agent --identity --name --no-focus --no-forward-agent --port --ssh-option --window" -- "$cur") ); return ;;
        ssh-session-attach)
            if [[ $prev == --split ]]; then
                COMPREPLY=( $(compgen -W "left right up down" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--pane --session-id --split --workspace" -- "$cur") ); return ;;
        ssh-session-cleanup)
            COMPREPLY=( $(compgen -W "--all --all-workspaces --session-id --workspace" -- "$cur") ); return ;;
        ssh-session-list)
            COMPREPLY=( $(compgen -W "--all-workspaces --workspace" -- "$cur") ); return ;;
        ssh-tmux)
            COMPREPLY=( $(compgen -W "--identity --no-focus --port" -- "$cur") ); return ;;
        surface)
            COMPREPLY=( $(compgen -W "resume --surface --window --workspace" -- "$cur") ); return ;;
        surface-health)
            COMPREPLY=( $(compgen -W "--window --workspace" -- "$cur") ); return ;;
        swap-pane)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--focus --pane --target-pane --window --workspace" -- "$cur") ); return ;;
        tab-action)
            if [[ $prev == --focus ]]; then
                COMPREPLY=( $(compgen -W "true false" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--action --focus --surface --tab --title --url --window --workspace" -- "$cur") ); return ;;
        themes)
            COMPREPLY=( $(compgen -W "clear list set" -- "$cur") ); return ;;
        top)
            if [[ $prev == --format ]]; then
                COMPREPLY=( $(compgen -W "tree tsv" -- "$cur") ); return
            fi
            if [[ $prev == --sort ]]; then
                COMPREPLY=( $(compgen -W "cpu mem proc" -- "$cur") ); return
            fi
            COMPREPLY=( $(compgen -W "--all --flat --format --processes --sort --window --workspace" -- "$cur") ); return ;;
        tree)
            COMPREPLY=( $(compgen -W "--all --window --workspace" -- "$cur") ); return ;;
        trigger-flash)
            COMPREPLY=( $(compgen -W "--surface --window --workspace" -- "$cur") ); return ;;
        vm)
            COMPREPLY=( $(compgen -W "exec ls new rm shell ssh" -- "$cur") ); return ;;
        wait-for)
            COMPREPLY=( $(compgen -W "--signal --timeout" -- "$cur") ); return ;;
        workspace-action)
            COMPREPLY=( $(compgen -W "--action --color --description --title --window --workspace" -- "$cur") ); return ;;
    esac
}
complete -F _cmux cmux
