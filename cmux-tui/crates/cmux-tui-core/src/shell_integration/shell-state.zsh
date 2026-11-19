
# cmux-tui: a freed (parked) terminal comes back with the shell state the
# person left (shell_state.rs; the bash script, shell-state.bash, says how).
# zsh runs this from .zshenv, before .zshrc, so the first prompt's hook does
# the work: restore a saved state (after every startup file), then take the
# fd baseline and install the SIGWINCH trap (zle catches SIGWINCH, so the
# trap runs at once while zle waits). Nothing runs per prompt.
if [[ -o interactive && -n ${CMUX_TUI_SHELL_STATE-} ]]; then
    # Specials a person sets; every other special is the shell's own.
    typeset -ga _cmux_tui_state_specials=(
        PATH FPATH MANPATH CDPATH MAILPATH HISTFILE HISTSIZE SAVEHIST HISTCHARS
        PROMPT PROMPT2 PROMPT3 PROMPT4 PS1 PS2 PS3 PS4 RPROMPT RPROMPT2 RPS1 RPS2
        SPROMPT PROMPT_EOL_MARK WORDCHARS KEYTIMEOUT LISTMAX REPORTTIME REPORTMEMORY
        TIMEFMT DIRSTACKSIZE NULLCMD READNULLCMD TMOUT IFS HOME LANG LC_ALL LC_COLLATE
        LC_CTYPE LC_MESSAGES LC_NUMERIC LC_TIME MAILCHECK PERIOD POSTEDIT TMPPREFIX
        TMPSUFFIX WATCH WATCHFMT LOGCHECK ZBEEP ZLE_RPROMPT_INDENT ZLE_LINE_ABORTED
    )

    _cmux_tui_state_skip_param() {
        case $1 in
            (CMUX_*|GHOSTTY_*|_ghostty*|_GHOSTTY*|_cmux_tui*|__cmux*) return 0 ;;
            (TERM|TERMINFO|TERM_PROGRAM|TERM_PROGRAM_VERSION|COLORTERM|ZDOTDIR|SHLVL|PWD|_) return 0 ;;
            (precmd_functions|preexec_functions|chpwd_functions|periodic_functions) return 0 ;;
            (zshaddhistory_functions|zshexit_functions|zsh_directory_name_functions) return 0 ;;
        esac
        return 1
    }

    _cmux_tui_state_fd_scan() {
        builtin local _cmux_tui_fd _cmux_tui_list=" "
        for (( _cmux_tui_fd = 3; _cmux_tui_fd < 64; _cmux_tui_fd++ )); do
            [[ -e /dev/fd/$_cmux_tui_fd ]] && _cmux_tui_list+="$_cmux_tui_fd "
        done
        _cmux_tui_fdlist=$_cmux_tui_list
    }

    # The SIGWINCH handler: write the state for the request in PREFIX.request.
    _cmux_tui_state_save() {
        [[ -r $CMUX_TUI_SHELL_STATE.request ]] || builtin return 0
        # The person's options, before this function changes its own.
        builtin local -a _cmux_tui_on _cmux_tui_off
        builtin local _cmux_tui_k
        for _cmux_tui_k in ${(k)options}; do
            case $_cmux_tui_k in
                (interactive|login|shinstdin|singlecommand|restricted|privileged|zle|errexit|errreturn) ;;
                (*) if [[ ${options[$_cmux_tui_k]} == on ]]; then
                        _cmux_tui_on+=($_cmux_tui_k)
                    else
                        _cmux_tui_off+=($_cmux_tui_k)
                    fi ;;
            esac
        done
        builtin emulate -L zsh -o no_aliases -o no_xtrace -o no_err_exit -o no_unset -o extended_glob
        builtin local _cmux_tui_nonce _cmux_tui_why="" _cmux_tui_state=$CMUX_TUI_SHELL_STATE.state _cmux_tui_umask _cmux_tui_fdlist _cmux_tui_name _cmux_tui_type
        builtin local -a _cmux_tui_vars _cmux_tui_specials _cmux_tui_unexport _cmux_tui_funcs
        # Before any redirection opens an fd of its own.
        _cmux_tui_state_fd_scan
        for _cmux_tui_k in ${=_cmux_tui_fdlist}; do
            [[ $_cmux_tui_state_fds == *" $_cmux_tui_k "* ]] || { _cmux_tui_why=open-fd-$_cmux_tui_k; break }
        done
        builtin read -r _cmux_tui_nonce <$CMUX_TUI_SHELL_STATE.request
        [[ -n $_cmux_tui_nonce ]] || builtin return 0
        (( ${#jobstates} )) && _cmux_tui_why=${_cmux_tui_why:-jobs}
        _cmux_tui_umask=$(builtin umask)
        builtin umask 077
        if [[ -n $_cmux_tui_why ]]; then
            builtin print -r -- "# cmux-tui shell state 1 zsh unsaveable $_cmux_tui_why"$'\n'"# end $_cmux_tui_nonce" >|$_cmux_tui_state
            builtin umask $_cmux_tui_umask
            builtin return 0
        fi
        # History: the user's file gets this session's lines, as an exit
        # does; the restore gets the in-memory list. Incognito: none.
        if [[ -z ${CMUX_TUI_INCOGNITO-} ]]; then
            if [[ -n ${HISTFILE-} && $HISTFILE != /dev/null ]] && (( ${SAVEHIST:-0} > 0 )); then
                if [[ ! -o inc_append_history && ! -o share_history && ! -o inc_append_history_time ]]; then
                    if [[ -o append_history ]]; then
                        builtin fc -AI $HISTFILE
                    else
                        builtin fc -W $HISTFILE
                    fi
                fi
            fi
            () { builtin local SAVEHIST=${HISTSIZE:-1000}; builtin fc -W $CMUX_TUI_SHELL_STATE.history }
        else
            command rm -f -- $CMUX_TUI_SHELL_STATE.history
        fi
        for _cmux_tui_name in ${(k)parameters}; do
            _cmux_tui_state_skip_param $_cmux_tui_name && continue
            _cmux_tui_type=${parameters[$_cmux_tui_name]}
            [[ $_cmux_tui_type == *(readonly|local)* ]] && continue
            if [[ $_cmux_tui_type == *special* ]]; then
                (( ${_cmux_tui_state_specials[(Ie)$_cmux_tui_name]} )) && _cmux_tui_specials+=($_cmux_tui_name)
                continue
            fi
            [[ $_cmux_tui_type == *hide* ]] && continue
            _cmux_tui_vars+=($_cmux_tui_name)
            [[ $_cmux_tui_type == *export* ]] || _cmux_tui_unexport+=($_cmux_tui_name)
        done
        for _cmux_tui_name in ${(k)functions}; do
            [[ $_cmux_tui_name == (_cmux_tui_*|_ghostty_*|__ghostty*|ghostty-*) ]] && continue
            # Not yet loaded: the startup files autoload it again.
            [[ ${functions[$_cmux_tui_name]} == *'builtin autoload -X'* ]] && continue
            _cmux_tui_funcs+=($_cmux_tui_name)
        done
        {
            builtin print -r -- "# cmux-tui shell state 1 zsh ok"
            builtin print -r -- "builtin cd -q -- ${(q)PWD}"
            builtin print -r -- "dirstack=( ${(@q)dirstack} )"
            builtin print -r -- "builtin umask $_cmux_tui_umask"
            (( $#_cmux_tui_on )) && builtin print -r -- "builtin setopt ${_cmux_tui_on[*]}"
            (( $#_cmux_tui_off )) && builtin print -r -- "builtin unsetopt ${_cmux_tui_off[*]}"
            # Functions before aliases: an alias would expand in a definition.
            builtin print -r -- "builtin unalias -a; builtin unalias -as"
            (( $#_cmux_tui_funcs )) && builtin functions -- $_cmux_tui_funcs
            # Inside a function, typeset -p prints `typeset -g` for a global.
            (( $#_cmux_tui_vars )) && builtin typeset -p -- $_cmux_tui_vars
            (( $#_cmux_tui_unexport )) && builtin print -r -- "builtin typeset -g +x -- ${_cmux_tui_unexport[*]}"
            for _cmux_tui_name in $_cmux_tui_specials; do
                [[ $_cmux_tui_name == (PS1|PROMPT) && -n ${_ghostty_marked_ps1-} && ${(P)_cmux_tui_name} == $_ghostty_marked_ps1 ]] \
                    && { builtin print -r -- "$_cmux_tui_name=${(q)_ghostty_saved_ps1}"; continue }
                [[ $_cmux_tui_name == (PS2|PROMPT2) && -n ${_ghostty_marked_ps1-} && $PS1 == $_ghostty_marked_ps1 ]] \
                    && { builtin print -r -- "$_cmux_tui_name=${(q)_ghostty_saved_ps2}"; continue }
                builtin print -r -- "$_cmux_tui_name=${(q)${(P)_cmux_tui_name}}"
            done
            builtin trap | while builtin read -r _cmux_tui_name; do
                [[ $_cmux_tui_name == *' WINCH' ]] || builtin print -r -- $_cmux_tui_name
            done
            builtin alias -L
            builtin alias -sL
            builtin print -r -- "# end $_cmux_tui_nonce"
        } >|$_cmux_tui_state 2>/dev/null
        builtin umask $_cmux_tui_umask
    }

    # The first prompt: restore, then arm the save.
    _cmux_tui_state_first_prompt() {
        builtin local -i ret=$?
        precmd_functions=(${precmd_functions:#_cmux_tui_state_first_prompt})
        if [[ -f $CMUX_TUI_SHELL_STATE.restore && -O $CMUX_TUI_SHELL_STATE.restore ]]; then
            builtin source $CMUX_TUI_SHELL_STATE.restore >/dev/null 2>&1
            # History: the saved list replaces the one zsh read from the
            # person's file (HISTSIZE 0 empties it); its lines count as read.
            if [[ -z ${CMUX_TUI_INCOGNITO-} && -f $CMUX_TUI_SHELL_STATE.restore-history ]]; then
                builtin local _cmux_tui_size=${HISTSIZE:-1000}
                HISTSIZE=0
                HISTSIZE=$_cmux_tui_size
                builtin fc -R $CMUX_TUI_SHELL_STATE.restore-history 2>/dev/null
            fi
            command rm -f -- $CMUX_TUI_SHELL_STATE.restore $CMUX_TUI_SHELL_STATE.restore-history 2>/dev/null
        fi
        builtin trap '_cmux_tui_state_save 2>/dev/null' WINCH
        _cmux_tui_state_baseline 2>/dev/null
        builtin return ret
    }
    # In the trap's redirection, so zsh's saved copy of stderr is in it.
    _cmux_tui_state_baseline() {
        builtin local _cmux_tui_fdlist
        _cmux_tui_state_fd_scan
        typeset -g _cmux_tui_state_fds=$_cmux_tui_fdlist
    }
    () {
        builtin emulate -L zsh -o no_aliases
        builtin typeset -ag precmd_functions
        precmd_functions+=(_cmux_tui_state_first_prompt)
    }
fi
