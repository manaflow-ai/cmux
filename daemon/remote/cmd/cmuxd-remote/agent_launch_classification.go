package main

import "strings"

var agentInformationalOptions = map[string]bool{
	"--help":    true,
	"-h":        true,
	"--version": true,
	"-v":        true,
	"-V":        true,
}

var claudeTeamsInformationalOptions = map[string]bool{
	"--help": true, "-h": true, "--version": true, "-v": true,
}

func claudeTeamsLaunchIsNonLaunch(args []string) bool {
	return claudeTeamsInformationalInvocation(args) || claudeTeamsManagementInvocation(args)
}

func claudeTeamsInformationalInvocation(args []string) bool {
	for index := 0; index < len(args); {
		argument := args[index]
		if argument == "--" {
			return false
		}
		if !strings.HasPrefix(argument, "-") || argument == "-" {
			index++
			continue
		}
		name := agentOptionName(argument)
		if claudeTeamsInformationalOptions[name] {
			return true
		}
		width, recognized := claudeTeamsOptionWidth(args, index)
		if !recognized {
			return false
		}
		index += width
	}
	return false
}

func claudeTeamsManagementInvocation(args []string) bool {
	for index := 0; index < len(args); {
		argument := args[index]
		if argument == "--" {
			return false
		}
		if !strings.HasPrefix(argument, "-") || argument == "-" {
			if argument == "agents" {
				return claudeTeamsAgentsJSONInvocation(args, index+1)
			}
			if allowedSubcommands := claudeTeamsManagementSubcommands[argument]; allowedSubcommands != nil {
				return claudeTeamsManagementSubcommand(args, index+1, allowedSubcommands)
			}
			return claudeTeamsManagementCommands[argument]
		}
		name := agentOptionName(argument)
		if claudeTeamsManagementDisqualifyingOptions[name] {
			return false
		}
		if (name == "--debug" || name == "-d") && !strings.Contains(argument, "=") {
			// Claude's debug filter is optional and accepts arbitrary strings. A
			// following command-shaped token is ambiguous, so fail closed.
			return false
		}
		width, recognized := claudeTeamsOptionWidth(args, index)
		if !recognized || claudeTeamsInformationalOptions[name] {
			return false
		}
		index += width
	}
	return false
}

func claudeTeamsAgentsJSONInvocation(args []string, index int) bool {
	sawJSON := false
	for ; index < len(args); index++ {
		switch args[index] {
		case "--json":
			if sawJSON {
				return false
			}
			sawJSON = true
		case "--all":
		default:
			return false
		}
	}
	return sawJSON
}

func claudeTeamsManagementSubcommand(args []string, index int, allowedSubcommands map[string]bool) bool {
	for index < len(args) {
		argument := args[index]
		if argument == "--" {
			return false
		}
		if !strings.HasPrefix(argument, "-") || argument == "-" {
			return allowedSubcommands[argument]
		}
		name := agentOptionName(argument)
		if name != "--json-path" && name != "--log-file" {
			return false
		}
		if strings.Contains(argument, "=") {
			index++
			continue
		}
		if index+1 >= len(args) {
			return false
		}
		index += 2
	}
	return false
}

func claudeTeamsOptionWidth(args []string, index int) (int, bool) {
	argument := args[index]
	name := agentOptionName(argument)
	if claudeTeamsInformationalOptions[name] || claudeTeamsBooleanOptions[name] {
		return 1, true
	}
	if name == "--tmux" {
		if strings.Contains(argument, "=") {
			return 1, strings.TrimPrefix(argument, "--tmux=") == "classic"
		}
		if index+1 < len(args) && args[index+1] == "classic" {
			return 2, true
		}
		return 0, false
	}
	if claudeTeamsOptionalValueOptions[name] {
		if strings.Contains(argument, "=") {
			return 1, true
		}
		if name == "--prompt-suggestions" && index+1 < len(args) &&
			(args[index+1] == "true" || args[index+1] == "false") {
			return 2, true
		}
		return 1, true
	}
	if !claudeTeamsValueOptions[name] {
		return 0, false
	}
	if strings.Contains(argument, "=") {
		return 1, true
	}
	if index+1 >= len(args) {
		return 0, false
	}
	if claudeTeamsVariadicOptions[name] {
		end := index + 1
		for end < len(args) && !strings.HasPrefix(args[end], "-") {
			end++
		}
		if end == index+1 {
			return 0, false
		}
		return end - index, true
	}
	return 2, true
}

func omoLaunchIsNonLaunch(args []string) bool {
	return conservativeAgentNonLaunchInvocation(
		args,
		omoManagementCommands,
		map[string]map[string]bool{
			"github":  {"install": true},
			"session": {"delete": true, "list": true},
		},
		map[string]bool{"--mdns": true, "--print-logs": true, "--pure": true},
		map[string]bool{
			"--cors": true, "--hostname": true, "--log-level": true,
			"--mdns-domain": true, "--port": true,
		},
	)
}

func omcLaunchIsNonLaunch(args []string) bool {
	return conservativeAgentNonLaunchInvocation(
		args,
		omcManagementCommands,
		map[string]map[string]bool{
			"team": {"--help": true, "-h": true, "api": true, "shutdown": true, "status": true},
		},
		nil,
		nil,
	)
}

func omxLaunchIsNonLaunch(args []string) bool {
	if len(args) == 0 {
		return false
	}
	if !strings.HasPrefix(args[0], "-") || args[0] == "-" {
		if agentNestedInformationalInvocation(args, 1, nil, nil) {
			return true
		}
	}
	if args[0] == "team" {
		if len(args) < 2 {
			return false
		}
		switch args[1] {
		case "--help", "-h", "api", "shutdown", "status":
			return true
		default:
			return false
		}
	}
	return agentInformationalOptions[args[0]] || omxManagementCommands[args[0]]
}

func conservativeAgentNonLaunchInvocation(
	args []string,
	managementCommands map[string]bool,
	managementSubcommands map[string]map[string]bool,
	booleanOptions map[string]bool,
	valueOptions map[string]bool,
) bool {
	for index := 0; index < len(args); {
		argument := args[index]
		if argument == "--" {
			return false
		}
		if !strings.HasPrefix(argument, "-") || argument == "-" {
			if agentNestedInformationalInvocation(args, index+1, booleanOptions, valueOptions) {
				return true
			}
			if allowedSubcommands := managementSubcommands[argument]; allowedSubcommands != nil {
				return agentManagementSubcommandInvocation(
					args,
					index+1,
					allowedSubcommands,
					booleanOptions,
					valueOptions,
				)
			}
			return managementCommands[argument]
		}
		name := agentOptionName(argument)
		if agentInformationalOptions[name] {
			return true
		}
		nextIndex, recognized := agentIndexAfterRecognizedOption(args, index, booleanOptions, valueOptions)
		if !recognized {
			return false
		}
		index = nextIndex
	}
	return false
}

func agentManagementSubcommandInvocation(
	args []string,
	index int,
	allowedSubcommands map[string]bool,
	booleanOptions map[string]bool,
	valueOptions map[string]bool,
) bool {
	for index < len(args) {
		argument := args[index]
		if argument == "--" {
			return false
		}
		if !strings.HasPrefix(argument, "-") || argument == "-" {
			return allowedSubcommands[argument]
		}
		nextIndex, recognized := agentIndexAfterRecognizedOption(args, index, booleanOptions, valueOptions)
		if !recognized {
			return false
		}
		index = nextIndex
	}
	return false
}

func agentNestedInformationalInvocation(
	args []string,
	index int,
	booleanOptions map[string]bool,
	valueOptions map[string]bool,
) bool {
	for index < len(args) {
		argument := args[index]
		if argument == "--" {
			return false
		}
		if !strings.HasPrefix(argument, "-") || argument == "-" {
			index++
			continue
		}
		option := agentOptionName(argument)
		if agentInformationalOptions[option] {
			return true
		}
		nextIndex, recognized := agentIndexAfterRecognizedOption(args, index, booleanOptions, valueOptions)
		if !recognized {
			return false
		}
		index = nextIndex
	}
	return false
}

func agentIndexAfterRecognizedOption(
	args []string,
	index int,
	booleanOptions map[string]bool,
	valueOptions map[string]bool,
) (int, bool) {
	argument := args[index]
	option := agentOptionName(argument)
	if booleanOptions[option] {
		return index + 1, true
	}
	if !valueOptions[option] {
		return 0, false
	}
	if strings.Contains(argument, "=") {
		return index + 1, true
	}
	if index+1 >= len(args) {
		return 0, false
	}
	return index + 2, true
}

func agentOptionName(argument string) string {
	if equals := strings.IndexByte(argument, '='); equals >= 0 {
		return argument[:equals]
	}
	return argument
}

var claudeTeamsManagementCommands = map[string]bool{
	"auth": true, "auto-mode": true, "doctor": true,
	"gateway": true, "install": true, "kill": true, "logs": true,
	"mcp": true, "plugin": true, "plugins": true, "project": true,
	"rm": true, "setup-token": true, "stop": true,
	"update": true, "upgrade": true,
}

var claudeTeamsManagementSubcommands = map[string]map[string]bool{
	"daemon": {"logs": true, "status": true, "stop": true, "uninstall": true},
}

var claudeTeamsManagementDisqualifyingOptions = map[string]bool{
	"--background": true, "--bg": true, "--continue": true, "-c": true,
	"--fork-session": true, "--from-pr": true, "--no-session-persistence": true,
	"--print": true, "-p": true, "--remote-control": true, "--resume": true,
	"-r": true, "--session-id": true, "--worktree": true, "-w": true,
}

var claudeTeamsBooleanOptions = map[string]bool{
	"--allow-dangerously-skip-permissions": true, "--ax-screen-reader": true,
	"--background": true, "--bare": true, "--bg": true, "--brief": true,
	"--chrome": true, "--continue": true, "-c": true,
	"--dangerously-skip-permissions": true, "--disable-slash-commands": true,
	"--exclude-dynamic-system-prompt-sections": true, "--fork-session": true,
	"--forward-subagent-text": true, "--ide": true, "--include-hook-events": true,
	"--include-partial-messages": true,
	"--no-chrome":                true, "--no-session-persistence": true, "--print": true,
	"-p": true, "--replay-user-messages": true, "--safe-mode": true,
	"--strict-mcp-config": true, "--use-system-ca": true, "--verbose": true,
}

var claudeTeamsOptionalValueOptions = map[string]bool{
	"--debug": true, "-d": true, "--prompt-suggestions": true,
	"--remote-control": true, "--worktree": true, "-w": true,
}

var claudeTeamsValueOptions = map[string]bool{
	"--add-dir": true, "--agent": true, "--agents": true, "--allowedTools": true,
	"--allowed-tools": true, "--append-system-prompt": true,
	"--append-system-prompt-file": true, "--betas": true,
	"--dangerously-load-development-channels": true, "--debug-file": true,
	"--disallowedTools": true, "--disallowed-tools": true, "--effort": true,
	"--fallback-model": true, "--file": true, "--from-pr": true,
	"--input-format": true, "--json-schema": true, "--max-budget-usd": true,
	"--mcp-config": true, "--model": true, "--name": true, "-n": true,
	"--output-format": true, "--permission-mode": true, "--plugin-dir": true,
	"--plugin-url": true, "--remote-control-session-name-prefix": true,
	"--resume": true, "-r": true, "--session-id": true,
	"--setting-sources": true, "--settings": true, "--system-prompt": true,
	"--system-prompt-file": true, "--teammate-mode": true, "--tools": true,
}

var claudeTeamsVariadicOptions = map[string]bool{
	"--add-dir": true, "--allowedTools": true, "--allowed-tools": true,
	"--betas": true, "--dangerously-load-development-channels": true,
	"--disallowedTools": true, "--disallowed-tools": true, "--file": true,
	"--mcp-config": true, "--tools": true,
}

var omoManagementCommands = map[string]bool{
	"agent": true, "auth": true, "completion": true, "db": true, "debug": true,
	"export": true, "import": true, "mcp": true, "models": true, "plugin": true,
	"plug": true, "providers": true, "stats": true, "uninstall": true, "upgrade": true,
}

var omcManagementCommands = map[string]bool{
	"ask": true, "capabilities": true, "config": true, "config-notify-profile": true,
	"config-stop-callback": true, "doctor": true, "help": true, "info": true,
	"install": true, "postinstall": true, "session": true, "setup": true,
	"teleport": true, "test-prompt": true, "update": true,
	"update-reconcile": true, "version": true,
}

var omxManagementCommands = map[string]bool{
	"agents": true, "agents-init": true, "ask": true, "auth": true,
	"cancel": true, "capabilities": true, "deepinit": true, "doctor": true,
	"explore": true, "help": true, "hooks": true, "hud": true,
	"list": true, "reasoning": true, "session": true, "setup": true,
	"sparkshell": true, "status": true, "tmux-hook": true, "uninstall": true,
	"update": true, "version": true,
}
