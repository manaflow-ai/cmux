package main

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// SessionStart carries the minimal resume binding the Mac admits from a relay
// host: the session's directory on this host and redacted argv words of the
// agent's nearest ancestors, so the Mac can match a launcher declared in its
// own cmux.json. The Mac builds the resume command itself; nothing here is a
// command, and argv values that could hold secrets are never sent.

const (
	claudeRelayRemoteCwdMaximumBytes    = 1024
	claudeRelayAncestorMaximumCount     = 8
	claudeRelayAncestorMaximumWords     = 6
	claudeRelayAncestorMaximumWordBytes = 128
	claudeRelayAncestorMaximumBytes     = 2048
	// Stands in for an option's separate value word, which is never sent.
	claudeRelayRedactedValue = "?"
	// Mirrors AgentExternalLauncher.maximumForwardingDepth.
	claudeRelayMaximumForwardingDepth = 2
)

// The following sets mirror AgentExternalLauncher in
// Packages/macOS/CMUXAgentLaunch. Only words the Swift matcher reads to reach a
// forwarded executable are sent; everything after it is dropped.
var (
	claudeRelayForwardingCommands = stringSet(
		"env",
		"node", "nodejs", "bun", "bunx", "deno",
		"npx", "pnpm", "pnpx", "yarn",
		"python", "python3", "uv", "uvx", "pipx",
		"ruby", "perl", "php",
		"tsx", "ts-node",
	)
	claudeRelayInterpreterCommands = stringSet(
		"node", "nodejs", "bun", "deno",
		"python", "python3",
		"ruby", "perl", "php",
		"tsx", "ts-node",
	)
	claudeRelayEnvFlagOptions = stringSet(
		"-i", "--ignore-environment",
		"-0", "--null",
		"-v", "--debug",
		"--list-signal-handling",
	)
	claudeRelayEnvValueOptions = stringSet(
		"-u", "--unset",
		"-C", "--chdir",
		"-S", "--split-string",
		"-P", "--default-signal", "--ignore-signal", "--block-signal",
	)
	claudeRelayPackageRunnerFlagOptions = stringSet(
		"-y", "--yes",
		"-q", "--quiet", "--silent",
		"--offline", "--prefer-offline", "--no-install", "--ignore-existing",
	)
	claudeRelayEnvAssignment = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
)

// stringSet builds a membership set from values.
func stringSet(values ...string) map[string]bool {
	set := make(map[string]bool, len(values))
	for _, value := range values {
		set[value] = true
	}
	return set
}

// The process tree (claudeProcessTree, claudeRelayProcessTree) is shared
// with hook routing in claude_hook_route.go.

// addClaudeRelayResumeContext adds `remote_cwd` and `ancestor_executables`
// to a SessionStart admission request when they are available and in bounds.
func addClaudeRelayResumeContext(params map[string]any, input []byte, claudePID string, tree claudeProcessTree) {
	if cwd := claudeRelayRemoteCwd(input); cwd != "" {
		params["remote_cwd"] = cwd
	}
	pid, err := strconv.Atoi(strings.TrimSpace(claudePID))
	if err != nil || pid <= 1 || tree == nil {
		return
	}
	if ancestors := claudeRelayAncestorExecutables(pid, tree); len(ancestors) > 0 {
		params["ancestor_executables"] = ancestors
	}
}

// claudeRelayRemoteCwd returns the hook payload's top-level `cwd` when it is
// an absolute path within bounds and free of control characters.
func claudeRelayRemoteCwd(input []byte) string {
	var object struct {
		Cwd string `json:"cwd"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(input), &object); err != nil {
		return ""
	}
	cwd := object.Cwd
	if !strings.HasPrefix(cwd, "/") || len(cwd) > claudeRelayRemoteCwdMaximumBytes || !claudeRelayPathIsPortable(cwd) {
		return ""
	}
	return cwd
}

// claudeRelayAncestorExecutables walks at most eight ancestors of the agent,
// nearest first, and keeps each one's redacted identifying words within the
// relay bounds.
func claudeRelayAncestorExecutables(agentPID int, tree claudeProcessTree) [][]string {
	var ancestors [][]string
	total := 0
	current := agentPID
	for depth := 0; depth < claudeRelayAncestorMaximumCount; depth++ {
		parent := tree.parent(current)
		if parent <= 1 {
			break
		}
		current = parent
		words := claudeRelayAncestorWords(tree.argv(parent))
		if len(words) == 0 {
			continue
		}
		size := 0
		for _, word := range words {
			size += len(word)
		}
		if total+size > claudeRelayAncestorMaximumBytes {
			break
		}
		total += size
		ancestors = append(ancestors, words)
	}
	return ancestors
}

// claudeRelayAncestorWords keeps the words AgentExternalLauncher reads to
// identify a launcher: argv[0], and when that is a forwarding command, the
// words up to the program it runs. Values are redacted: `NAME=` for env
// assignments, `--opt=` for inline option values, and a placeholder for an
// option's separate value word. Arguments after the identified program are
// never included.
func claudeRelayAncestorWords(argv []string) []string {
	var words []string
	full := false
	emit := func(word string) bool {
		if len(words) >= claudeRelayAncestorMaximumWords || len(word) > claudeRelayAncestorMaximumWordBytes ||
			!claudeRelayWordIsClean(word) || claudeRelayWordMayCarryCredential(word) {
			full = true
			return false
		}
		words = append(words, word)
		return true
	}
	index := 0
	forwardsRemaining := claudeRelayMaximumForwardingDepth
	for index < len(argv) && !full {
		word := strings.TrimSpace(argv[index])
		if word == "" {
			index++
			continue
		}
		// A long install path still identifies a launcher declared by name.
		if len(word) > claudeRelayAncestorMaximumWordBytes {
			word = filepath.Base(word)
		}
		if !emit(word) {
			break
		}
		command := filepath.Base(word)
		if forwardsRemaining == 0 || !claudeRelayForwardingCommands[command] {
			break
		}
		forwardsRemaining--
		next, ok := claudeRelayForwardedExecutableIndex(argv, index, command, emit)
		if !ok {
			break
		}
		index = next
	}
	return words
}

// claudeRelayForwardedExecutableIndex mirrors
// AgentExternalLauncher.indexOfForwardedExecutable, emitting the redacted form
// of each skipped word. It returns false when no program follows.
func claudeRelayForwardedExecutableIndex(argv []string, index int, command string, emit func(string) bool) (int, bool) {
	cursor := index + 1
	for cursor < len(argv) {
		word := strings.TrimSpace(argv[cursor])
		switch {
		case word == "":
			cursor++
			continue
		case claudeRelayEnvAssignment.MatchString(word):
			if !emit(word[:strings.IndexByte(word, '=')+1]) {
				return 0, false
			}
			cursor++
			continue
		case word == "--":
			if !emit(word) {
				return 0, false
			}
			cursor++
			continue
		case word == "-":
			if command != "env" || !emit(word) {
				return 0, false
			}
			cursor++
			continue
		case !strings.HasPrefix(word, "-"):
			return cursor, true
		}
		optionName, joined := word, false
		if equals := strings.IndexByte(word, '='); equals >= 0 {
			optionName, joined = word[:equals], true
		}
		redacted := optionName
		if joined {
			redacted += "="
		}
		if command == "env" {
			switch {
			case claudeRelayEnvFlagOptions[optionName]:
				if !emit(redacted) {
					return 0, false
				}
				cursor++
			case claudeRelayEnvValueOptions[optionName]:
				if !emit(redacted) {
					return 0, false
				}
				if joined {
					cursor++
				} else {
					if cursor+1 < len(argv) && !emit(claudeRelayRedactedValue) {
						return 0, false
					}
					cursor += 2
				}
			default:
				return 0, false
			}
			continue
		}
		if claudeRelayInterpreterCommands[command] || !claudeRelayPackageRunnerFlagOptions[optionName] {
			return 0, false
		}
		if !emit(redacted) {
			return 0, false
		}
		cursor++
	}
	return 0, false
}

// claudeRelayWordIsClean rejects invalid UTF-8, C0 and C1 control
// characters, line and paragraph separators, and bidirectional overrides.
func claudeRelayWordIsClean(word string) bool {
	if !utf8.ValidString(word) {
		return false
	}
	for _, r := range word {
		switch {
		case r < 0x20, r >= 0x7f && r <= 0x9f,
			r == 0x2028, r == 0x2029, r == 0x200e, r == 0x200f,
			r >= 0x202a && r <= 0x202e, r >= 0x2066 && r <= 0x2069:
			return false
		}
	}
	return true
}

// claudeRelayPortablePathPunctuation is the punctuation a relayed remote cwd
// may use. The Mac types the path into a remote shell whose dialect it cannot
// see (fish reads `\'` inside single quotes), so quotes, backslashes and
// shell metacharacters are refused rather than escaped.
const claudeRelayPortablePathPunctuation = " /._-+,@:=~%"

// claudeRelayPathIsPortable reports whether a path uses only letters,
// digits, combining marks and claudeRelayPortablePathPunctuation.
func claudeRelayPathIsPortable(path string) bool {
	if !utf8.ValidString(path) {
		return false
	}
	for _, r := range path {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && !unicode.IsMark(r) &&
			!strings.ContainsRune(claudeRelayPortablePathPunctuation, r) {
			return false
		}
	}
	return true
}

// claudeRelayWordMayCarryCredential reports words shaped like URLs or
// user:password@host, which a package runner may be given and which must not
// leave the host. The scan stops there.
func claudeRelayWordMayCarryCredential(word string) bool {
	return strings.Contains(word, "://") || (strings.Contains(word, "@") && strings.Contains(word, ":"))
}
