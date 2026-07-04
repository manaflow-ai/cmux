package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/manaflow-ai/cmux/vault/internal/agentdirs"
	"github.com/manaflow-ai/cmux/vault/internal/api"
	"github.com/manaflow-ai/cmux/vault/internal/authflow"
	"github.com/manaflow-ai/cmux/vault/internal/authstore"
	"github.com/manaflow-ai/cmux/vault/internal/resume"
	"github.com/manaflow-ai/cmux/vault/internal/state"
	"github.com/manaflow-ai/cmux/vault/internal/syncer"
)

var version = "dev"

type printer struct {
	w io.Writer
}

func (p printer) Printf(format string, args ...any) {
	_, _ = fmt.Fprintf(p.w, format, args...)
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	global := flag.NewFlagSet("cmux-vault", flag.ContinueOnError)
	global.SetOutput(stderr)
	apiBase := global.String("api-base", defaultAPIBase(), "cmux web API base URL")
	jsonOutput := global.Bool("json", false, "write JSON output where supported")
	if err := global.Parse(args); err != nil {
		return 2
	}
	remaining := global.Args()
	if len(remaining) == 0 {
		usage(stderr)
		return 2
	}

	env, err := agentdirs.RealEnviron()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "cmux-vault: %v\n", err)
		return 1
	}
	var warnings []string
	env.Warnings = &warnings
	defer func() {
		for _, warning := range warnings {
			_, _ = fmt.Fprintf(stderr, "warning: %s\n", warning)
		}
	}()
	ctx := context.Background()
	cmd := remaining[0]
	cmdArgs := remaining[1:]

	switch cmd {
	case "version":
		if *jsonOutput {
			return writeJSON(stdout, map[string]string{"version": version})
		}
		_, _ = fmt.Fprintln(stdout, version)
		return 0
	case "login":
		client := api.New(*apiBase, nil)
		tokens, err := authflow.Login(ctx, client, printer{w: stdout})
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "login failed: %v\n", err)
			return 1
		}
		if err := authstore.Save(env.HomeDir, env.Vars, tokens); err != nil {
			_, _ = fmt.Fprintf(stderr, "saving tokens failed: %v\n", err)
			return 1
		}
		if *jsonOutput {
			return writeJSON(stdout, map[string]any{"ok": true})
		}
		_, _ = fmt.Fprintln(stdout, "Logged in.")
		return 0
	case "logout":
		if err := authstore.Delete(env.HomeDir, env.Vars); err != nil {
			_, _ = fmt.Fprintf(stderr, "logout failed: %v\n", err)
			return 1
		}
		if *jsonOutput {
			return writeJSON(stdout, map[string]any{"ok": true})
		}
		_, _ = fmt.Fprintln(stdout, "Logged out.")
		return 0
	case "scan":
		return runScan(cmdArgs, env, *jsonOutput, stdout, stderr)
	case "sync":
		return runSync(ctx, cmdArgs, env, *apiBase, *jsonOutput, stdout, stderr)
	case "resume":
		return runResume(ctx, cmdArgs, env, *apiBase, *jsonOutput, stdout, stderr)
	case "status":
		return runStatus(cmdArgs, env, *jsonOutput, stdout, stderr)
	case "help", "-h", "--help":
		usage(stdout)
		return 0
	default:
		_, _ = fmt.Fprintf(stderr, "cmux-vault: unknown command %q\n", cmd)
		usage(stderr)
		return 2
	}
}

func runScan(args []string, env agentdirs.Environ, jsonOutput bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("scan", flag.ContinueOnError)
	fs.SetOutput(stderr)
	agent := fs.String("agent", "", "agent to scan (claude, codex, pi)")
	localJSON := fs.Bool("json", jsonOutput, "write JSON output")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	sessions, err := agentdirs.DiscoverAll(env, *agent)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "scan failed: %v\n", err)
		return 1
	}
	if *localJSON {
		return writeJSON(stdout, map[string]any{"sessions": sessions})
	}
	for _, session := range sessions {
		_, _ = fmt.Fprintf(stdout, "%s\t%s\t%d\t%s\t%s\n",
			session.AgentName,
			session.AgentSessionID,
			session.SizeBytes,
			session.ModTime.Format(time.RFC3339),
			session.AbsPath,
		)
	}
	return 0
}

func runSync(ctx context.Context, args []string, env agentdirs.Environ, apiBase string, jsonOutput bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("sync", flag.ContinueOnError)
	fs.SetOutput(stderr)
	agent := fs.String("agent", "", "agent to sync (claude, codex, pi)")
	dryRun := fs.Bool("dry-run", false, "scan and diff without uploading")
	limit := fs.Int("limit", 0, "maximum changed sessions to upload")
	localJSON := fs.Bool("json", jsonOutput, "write JSON output")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	tokens, err := authstore.Load(env.HomeDir, env.Vars)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "loading auth failed: %v\n", err)
		return 1
	}
	if tokens == nil && !*dryRun {
		_, _ = fmt.Fprintln(stderr, "not logged in; run cmux-vault login")
		return 1
	}
	store, err := state.Load(env.HomeDir, env.Vars)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "loading state failed: %v\n", err)
		return 1
	}
	engine := syncer.Engine{
		Env:    env,
		State:  store,
		Client: api.New(apiBase, tokens),
		Out:    printer{w: stdout},
	}
	if *localJSON {
		engine.Out = nil
	}
	summary, err := engine.Sync(ctx, syncer.Options{
		Agent:  *agent,
		DryRun: *dryRun,
		Limit:  *limit,
	})
	if *localJSON {
		if code := writeJSON(stdout, summary); code != 0 {
			return code
		}
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "sync failed: %v\n", err)
		return 1
	}
	if !*localJSON {
		_, _ = fmt.Fprintf(stdout, "summary: uploaded=%d skipped=%d failed=%d bytes=%d compressedBytes=%d\n",
			summary.Uploaded,
			summary.Skipped,
			summary.Failed,
			summary.BytesUploaded,
			summary.CompressedBytesUploaded,
		)
	}
	return 0
}

func runResume(ctx context.Context, args []string, env agentdirs.Environ, apiBase string, jsonOutput bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("resume", flag.ContinueOnError)
	fs.SetOutput(stderr)
	agent := fs.String("agent", "", "agent to resume (claude, codex, pi)")
	force := fs.Bool("force", false, "overwrite an existing local transcript")
	localJSON := fs.Bool("json", jsonOutput, "write JSON output")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		_, _ = fmt.Fprintln(stderr, "resume requires a session id")
		return 2
	}
	tokens, err := authstore.Load(env.HomeDir, env.Vars)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "loading auth failed: %v\n", err)
		return 1
	}
	if tokens == nil {
		_, _ = fmt.Fprintln(stderr, "not logged in; run cmux-vault login")
		return 1
	}
	restorer := resume.Restorer{
		Env:    env,
		Client: api.New(apiBase, tokens),
		Out:    printer{w: stdout},
	}
	if *localJSON {
		restorer.Out = nil
	}
	hint, err := restorer.Resume(ctx, fs.Arg(0), resume.Options{Agent: *agent, Force: *force})
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "resume failed: %v\n", err)
		return 1
	}
	if *localJSON {
		return writeJSON(stdout, map[string]string{"hint": hint})
	}
	return 0
}

func runStatus(args []string, env agentdirs.Environ, jsonOutput bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	localJSON := fs.Bool("json", jsonOutput, "write JSON output")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	tokens, err := authstore.Load(env.HomeDir, env.Vars)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "loading auth failed: %v\n", err)
		return 1
	}
	store, err := state.Load(env.HomeDir, env.Vars)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "loading state failed: %v\n", err)
		return 1
	}
	status := map[string]any{
		"loggedIn":     tokens != nil,
		"trackedFiles": len(store.Entries),
	}
	if *localJSON {
		return writeJSON(stdout, status)
	}
	if tokens != nil {
		_, _ = fmt.Fprintln(stdout, "Logged in.")
	} else {
		_, _ = fmt.Fprintln(stdout, "Not logged in.")
	}
	_, _ = fmt.Fprintf(stdout, "Tracked files: %d\n", len(store.Entries))
	return 0
}

func writeJSON(stdout io.Writer, value any) int {
	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return 1
	}
	return 0
}

func defaultAPIBase() string {
	if value := strings.TrimSpace(os.Getenv("CMUX_VAULT_API_BASE")); value != "" {
		return value
	}
	return api.DefaultBaseURL
}

func usage(w io.Writer) {
	_, _ = fmt.Fprintln(w, `Usage: cmux-vault [--api-base URL] [--json] <command> [options]

Commands:
  login      Start device-code login
  logout     Delete local auth tokens
  scan       Discover local agent sessions
  sync       Upload changed sessions
  resume     Restore a missing session from cmux Vault and print the resume command
  status     Show auth and local sync state
  version    Print version`)
}
