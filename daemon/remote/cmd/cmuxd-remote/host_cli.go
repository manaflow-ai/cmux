package main

// host_cli.go implements CLI commands for the host attach feature.
// These commands allow remote callers to interact with the host machine's
// local cmux instance through cmuxd-remote's relay.

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// runHostList lists surfaces on the host machine's cmux.
func runHostList(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	params := map[string]any{"all": true}

	parsed, err := parseFlags(args, []string{"workspace"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux host-list: %v\n", err)
		return 2
	}
	if ws, ok := parsed.flags["workspace"]; ok {
		params["workspace_id"] = ws
	}

	resp, err := socketRoundTripV2(socketPath, "host.surface.list", params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}

	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(formatHostList(resp))
	}
	return 0
}

// runHostRead reads the screen content of a host cmux surface.
func runHostRead(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	parsed, err := parseFlags(args, []string{"surface", "lines"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux host-read: %v\n", err)
		return 2
	}

	surfaceID, ok := parsed.flags["surface"]
	if !ok {
		fmt.Fprintln(os.Stderr, "cmux host-read: --surface is required")
		return 2
	}

	params := map[string]any{"surface_id": surfaceID}
	if lines, ok := parsed.flags["lines"]; ok {
		params["lines"] = lines
	}

	resp, err := socketRoundTripV2(socketPath, "host.surface.read_screen", params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}

	if jsonOutput {
		fmt.Println(resp)
	} else {
		// Try to extract just the screen text
		var result map[string]any
		if json.Unmarshal([]byte(resp), &result) == nil {
			text := extractScreenText(result)
			if text != "" {
				fmt.Print(text)
				if !strings.HasSuffix(text, "\n") {
					fmt.Println()
				}
				return 0
			}
		}
		fmt.Println(resp)
	}
	return 0
}

// runHostSend sends text to a host cmux surface.
func runHostSend(socketPath string, args []string, refreshAddr func() string) int {
	parsed, err := parseFlags(args, []string{"surface"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux host-send: %v\n", err)
		return 2
	}

	surfaceID, ok := parsed.flags["surface"]
	if !ok {
		fmt.Fprintln(os.Stderr, "cmux host-send: --surface is required")
		return 2
	}

	if len(parsed.positional) == 0 {
		fmt.Fprintln(os.Stderr, "cmux host-send: text argument is required")
		return 2
	}
	text := strings.Join(parsed.positional, " ")

	params := map[string]any{
		"surface_id": surfaceID,
		"text":       text,
	}

	_, err = socketRoundTripV2(socketPath, "host.surface.send_text", params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	fmt.Printf("OK surface=%s\n", surfaceID)
	return 0
}

// runHostSendKey sends a key event to a host cmux surface.
func runHostSendKey(socketPath string, args []string, refreshAddr func() string) int {
	parsed, err := parseFlags(args, []string{"surface"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux host-send-key: %v\n", err)
		return 2
	}

	surfaceID, ok := parsed.flags["surface"]
	if !ok {
		fmt.Fprintln(os.Stderr, "cmux host-send-key: --surface is required")
		return 2
	}

	if len(parsed.positional) == 0 {
		fmt.Fprintln(os.Stderr, "cmux host-send-key: key argument is required")
		return 2
	}
	key := parsed.positional[0]

	params := map[string]any{
		"surface_id": surfaceID,
		"key":        key,
	}

	_, err = socketRoundTripV2(socketPath, "host.surface.send_key", params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	fmt.Printf("OK surface=%s key=%s\n", surfaceID, key)
	return 0
}

// formatHostList formats the host surface list response for human-readable output.
func formatHostList(resp string) string {
	var result any
	if err := json.Unmarshal([]byte(resp), &result); err != nil {
		return resp
	}

	encoded, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return resp
	}
	return string(encoded)
}
