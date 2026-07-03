# cmux shell completions (bash) -- AUTO-GENERATED, DO NOT EDIT.
#
# Regenerate with:  scripts/generate-cli-completions.py --write
# Source of truth:  topLevelCommandNames in CLI/cmux.swift + its usage() help.

__cmux_compgen() {
    local wordlist="$1" current="$2" match
    COMPREPLY=()
    while IFS= read -r match; do
        COMPREPLY+=("$match")
    done < <(compgen -W "$wordlist" -- "$current")
}

_cmux() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    # Locate the command word: first non-option after `cmux`,
    # skipping value-bearing global options and their values.
    local i cmd=""
    for ((i=1; i < COMP_CWORD; i++)); do
        case "${COMP_WORDS[i]}" in
            --socket|--id-format|--window|--password) ((i++)) ;;
            -*) ;;
            *) cmd="${COMP_WORDS[i]}"; break ;;
        esac
    done
    local commands="agent-hibernation auth bind-key break-pane browser browser-back browser-forward browser-reload browser-status capabilities capture-pane claude-teams clear-history clear-log clear-notifications clear-progress clear-status close-surface close-window close-workspace cloud codex codex-teams config copy-mode current-window current-workspace debug-terminals detach-tab diff disable-browser dismiss-notification display-message docs drag-surface-to-split enable-browser events feed feedback find-window focus-pane focus-panel focus-webview focus-window get-url help hooks identify is-webview-focused join-pane jump-to-unread last-pane last-window list-buffers list-log list-notifications list-pane-surfaces list-panels list-panes list-status list-windows list-workspaces log login logout mark-notification-read markdown memory mobile move-surface move-tab-to-new-workspace move-workspace-to-window navigate new-pane new-split new-surface new-window new-workspace next-window notify omc omo omx open open-browser open-notification paste-buffer ping pipe-pane popup previous-window read-screen refresh-surfaces reload-config remote remote-daemon-status remotes rename-tab rename-window rename-workspace reorder-surface reorder-workspace reorder-workspaces resize-pane respawn-pane restore-session right-sidebar rpc select-workspace send send-key send-key-panel send-panel set-app-focus set-buffer set-hook set-progress set-status settings shortcuts sidebar sidebar-state simulate-app-active simulate-sidebar-drag split-off ssh ssh-session-attach ssh-session-cleanup ssh-session-list ssh-tmux surface surface-health surface-resume swap-pane tab-action themes top tree trigger-flash unbind-key version vm wait-for welcome workspace workspace-action workspace-group"
    if [[ -z $cmd ]]; then
        __cmux_compgen "$commands" "$cur"
        return
    fi
    case "$cmd" in
        agent-hibernation)
            __cmux_compgen "off on" "$cur"; return ;;
        auth)
            __cmux_compgen "login logout status" "$cur"; return ;;
        break-pane)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus --no-focus --pane --surface --window --workspace" "$cur"; return ;;
        browser)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            if [[ $prev == --load-state ]]; then
                __cmux_compgen "interactive complete" "$cur"; return
            fi
            __cmux_compgen "addinitscript addscript addstyle back check click console cookies dblclick devtools dialog disable download enable errors eval fill find focus focus-mode forward frame get get-url goto highlight history hover identify import is keydown keyup navigate open open-split press profiles react-grab reload screenshot scroll scroll-into-view select snapshot state status storage tab type uncheck url wait zoom --all --compact --cursor --dx --dy --focus --force --function --interactive --json --load-state --max-depth --out --path --return-to --selector --snapshot-after --surface --text --timeout-ms --url-contains" "$cur"; return ;;
        capture-pane)
            __cmux_compgen "--lines --scrollback --surface --window --workspace" "$cur"; return ;;
        clear-history)
            __cmux_compgen "--surface --window --workspace" "$cur"; return ;;
        clear-log)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        clear-notifications)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        clear-progress)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        clear-status)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        close-surface)
            __cmux_compgen "--surface --window --workspace" "$cur"; return ;;
        close-window)
            __cmux_compgen "--window" "$cur"; return ;;
        close-workspace)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        cloud)
            __cmux_compgen "exec ls new rm shell ssh" "$cur"; return ;;
        config)
            __cmux_compgen "check docs doctor documentation path paths reload validate" "$cur"; return ;;
        current-workspace)
            __cmux_compgen "--window" "$cur"; return ;;
        diff)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            if [[ $prev == --layout ]]; then
                __cmux_compgen "split unified" "$cur"; return
            fi
            if [[ $prev == --source ]]; then
                __cmux_compgen "unstaged staged branch last-turn" "$cur"; return
            fi
            __cmux_compgen "--base --branch --cwd --focus --font-size --last-turn --layout --no-focus --source --staged --surface --title --unstaged --window --workspace" "$cur"; return ;;
        dismiss-notification)
            __cmux_compgen "--all-read --id" "$cur"; return ;;
        display-message)
            __cmux_compgen "--print" "$cur"; return ;;
        docs)
            __cmux_compgen "agents api browser dock settings shortcuts sidebars" "$cur"; return ;;
        drag-surface-to-split)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus --surface --window --workspace" "$cur"; return ;;
        events)
            __cmux_compgen "--after --category --cursor-file --limit --name --no-ack --no-heartbeat --reconnect" "$cur"; return ;;
        feed)
            __cmux_compgen "clear tui" "$cur"; return ;;
        feedback)
            __cmux_compgen "--body --email --image" "$cur"; return ;;
        find-window)
            __cmux_compgen "--content --select --window" "$cur"; return ;;
        focus-pane)
            __cmux_compgen "--pane --window --workspace" "$cur"; return ;;
        focus-panel)
            __cmux_compgen "--panel --window --workspace" "$cur"; return ;;
        focus-window)
            __cmux_compgen "--window" "$cur"; return ;;
        hooks)
            __cmux_compgen "feed setup uninstall --agent --event --project --source" "$cur"; return ;;
        identify)
            __cmux_compgen "--no-caller --surface --window --workspace" "$cur"; return ;;
        join-pane)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus --no-focus --pane --surface --target-pane --window --workspace" "$cur"; return ;;
        last-pane)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        last-window)
            __cmux_compgen "--window" "$cur"; return ;;
        list-log)
            __cmux_compgen "--limit --window --workspace" "$cur"; return ;;
        list-pane-surfaces)
            __cmux_compgen "--pane --window --workspace" "$cur"; return ;;
        list-panels)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        list-panes)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        list-status)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        list-workspaces)
            __cmux_compgen "--window" "$cur"; return ;;
        log)
            __cmux_compgen "--level --source --window --workspace" "$cur"; return ;;
        mark-notification-read)
            __cmux_compgen "--all --id --surface --window --workspace" "$cur"; return ;;
        markdown)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus" "$cur"; return ;;
        memory)
            __cmux_compgen "--all --groups --workspace" "$cur"; return ;;
        move-surface)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--after --before --focus --index --pane --surface --window --workspace" "$cur"; return ;;
        move-tab-to-new-workspace)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus --surface --tab --title --window --workspace" "$cur"; return ;;
        move-workspace-to-window)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        new-pane)
            if [[ $prev == --direction ]]; then
                __cmux_compgen "left right up down" "$cur"; return
            fi
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            if [[ $prev == --type ]]; then
                __cmux_compgen "terminal browser" "$cur"; return
            fi
            __cmux_compgen "--direction --focus --type --url --window --workspace" "$cur"; return ;;
        new-split)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "down left right up --focus --panel --surface --window --workspace" "$cur"; return ;;
        new-surface)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            if [[ $prev == --provider ]]; then
                __cmux_compgen "codex claude opencode" "$cur"; return
            fi
            if [[ $prev == --renderer ]]; then
                __cmux_compgen "react solid" "$cur"; return
            fi
            if [[ $prev == --type ]]; then
                __cmux_compgen "terminal browser agent-session" "$cur"; return
            fi
            __cmux_compgen "--focus --pane --provider --renderer --type --url --window --workspace" "$cur"; return ;;
        new-workspace)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--command --cwd --description --focus --group --group-placement --group-reference --layout --name --window" "$cur"; return ;;
        next-window)
            __cmux_compgen "--window" "$cur"; return ;;
        notify)
            __cmux_compgen "--body --subtitle --surface --title --window --workspace" "$cur"; return ;;
        open)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus --no-focus --pane --surface --window --workspace" "$cur"; return ;;
        open-notification)
            __cmux_compgen "--id" "$cur"; return ;;
        paste-buffer)
            __cmux_compgen "--name --surface --window --workspace" "$cur"; return ;;
        pipe-pane)
            __cmux_compgen "--command --surface --window --workspace" "$cur"; return ;;
        previous-window)
            __cmux_compgen "--window" "$cur"; return ;;
        read-screen)
            __cmux_compgen "--lines --scrollback --surface --window --workspace" "$cur"; return ;;
        remote)
            __cmux_compgen "add list remove --json --route --tag" "$cur"; return ;;
        remote-daemon-status)
            if [[ $prev == --arch ]]; then
                __cmux_compgen "arm64 amd64" "$cur"; return
            fi
            if [[ $prev == --os ]]; then
                __cmux_compgen "darwin linux" "$cur"; return
            fi
            __cmux_compgen "--arch --os" "$cur"; return ;;
        remotes)
            __cmux_compgen "add list remove --json --route --tag" "$cur"; return ;;
        rename-tab)
            __cmux_compgen "--surface --tab --window --workspace" "$cur"; return ;;
        rename-window)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        rename-workspace)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        reorder-surface)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--after --before --focus --index --surface --window --workspace" "$cur"; return ;;
        reorder-workspace)
            __cmux_compgen "--after --before --dry-run --index --window --workspace" "$cur"; return ;;
        reorder-workspaces)
            __cmux_compgen "--dry-run --order --window" "$cur"; return ;;
        resize-pane)
            __cmux_compgen "--amount --pane --window --workspace" "$cur"; return ;;
        respawn-pane)
            __cmux_compgen "--command --surface --window --workspace" "$cur"; return ;;
        right-sidebar)
            __cmux_compgen "dock feed files find focus hide mode sessions set show toggle vault --no-focus --window --workspace" "$cur"; return ;;
        select-workspace)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        send)
            __cmux_compgen "--surface --window --workspace" "$cur"; return ;;
        send-key)
            __cmux_compgen "--surface --window --workspace" "$cur"; return ;;
        send-key-panel)
            __cmux_compgen "--panel --window --workspace" "$cur"; return ;;
        send-panel)
            __cmux_compgen "--panel --window --workspace" "$cur"; return ;;
        set-app-focus)
            __cmux_compgen "active clear inactive" "$cur"; return ;;
        set-buffer)
            __cmux_compgen "--name" "$cur"; return ;;
        set-hook)
            __cmux_compgen "--list --unset" "$cur"; return ;;
        set-progress)
            __cmux_compgen "--label --window --workspace" "$cur"; return ;;
        set-status)
            __cmux_compgen "--color --icon --priority --window --workspace" "$cur"; return ;;
        sidebar)
            __cmux_compgen "open reload select validate" "$cur"; return ;;
        sidebar-state)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        simulate-sidebar-drag)
            __cmux_compgen "--duration-ms --from --steps --to --window" "$cur"; return ;;
        split-off)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus --surface --window --workspace" "$cur"; return ;;
        ssh)
            __cmux_compgen "--forward-agent --identity --name --no-focus --no-forward-agent --port --ssh-option --window" "$cur"; return ;;
        ssh-session-attach)
            if [[ $prev == --split ]]; then
                __cmux_compgen "left right up down" "$cur"; return
            fi
            __cmux_compgen "--pane --session-id --split --workspace" "$cur"; return ;;
        ssh-session-cleanup)
            __cmux_compgen "--all --all-workspaces --session-id --workspace" "$cur"; return ;;
        ssh-session-list)
            __cmux_compgen "--all-workspaces --workspace" "$cur"; return ;;
        ssh-tmux)
            __cmux_compgen "--identity --no-focus --port" "$cur"; return ;;
        surface)
            __cmux_compgen "resume --surface --window --workspace" "$cur"; return ;;
        surface-health)
            __cmux_compgen "--window --workspace" "$cur"; return ;;
        swap-pane)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--focus --pane --target-pane --window --workspace" "$cur"; return ;;
        tab-action)
            if [[ $prev == --focus ]]; then
                __cmux_compgen "true false" "$cur"; return
            fi
            __cmux_compgen "--action --focus --surface --tab --title --url --window --workspace" "$cur"; return ;;
        themes)
            __cmux_compgen "clear list set" "$cur"; return ;;
        top)
            if [[ $prev == --format ]]; then
                __cmux_compgen "tree tsv" "$cur"; return
            fi
            if [[ $prev == --sort ]]; then
                __cmux_compgen "cpu mem proc" "$cur"; return
            fi
            __cmux_compgen "--all --flat --format --processes --sort --window --workspace" "$cur"; return ;;
        tree)
            __cmux_compgen "--all --window --workspace" "$cur"; return ;;
        trigger-flash)
            __cmux_compgen "--surface --window --workspace" "$cur"; return ;;
        vm)
            __cmux_compgen "exec ls new rm shell ssh" "$cur"; return ;;
        wait-for)
            __cmux_compgen "--signal --timeout" "$cur"; return ;;
        workspace-action)
            __cmux_compgen "--action --color --description --title --window --workspace" "$cur"; return ;;
    esac
}
complete -F _cmux cmux
