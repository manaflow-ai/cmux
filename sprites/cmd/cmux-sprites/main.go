package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const defaultAPIBase = "https://cmux.com"

type tokens struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
}

type authStart struct {
	DeviceCode       string `json:"deviceCode"`
	UserCode         string `json:"userCode"`
	VerificationURL  string `json:"verificationUrl"`
	ExpiresInSeconds int    `json:"expiresInSeconds"`
	IntervalSeconds  int    `json:"intervalSeconds"`
}

type authPoll struct {
	Status       string `json:"status"`
	Client       string `json:"client"`
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
}

type vm struct {
	ID            string `json:"id"`
	Provider      string `json:"provider"`
	Status        string `json:"status"`
	Image         string `json:"image"`
	ConnectionURL string `json:"connectionUrl"`
}

type vmList struct {
	VMs []vm `json:"vms"`
}

type execResult struct {
	ExitCode int    `json:"exitCode"`
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
}

type apiClient struct {
	baseURL string
	baseErr error
	tokens  *tokens
	http    *http.Client
}

type retryClock interface {
	Now() time.Time
	Sleep(context.Context, time.Duration) error
}

type systemClock struct{}

func (systemClock) Now() time.Time {
	return time.Now()
}

func (systemClock) Sleep(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type enrollmentExecutor interface {
	execWithTimeout(context.Context, string, string, int) (execResult, error)
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	global := flag.NewFlagSet("cmux-sprites", flag.ContinueOnError)
	global.SetOutput(stderr)
	apiBase := global.String("api-base", envOr("CMUX_SPRITES_API_BASE", defaultAPIBase), "cmux web API base URL")
	jsonOutput := global.Bool("json", false, "write JSON output")
	if err := global.Parse(args); err != nil {
		return 2
	}
	remaining := global.Args()
	if len(remaining) == 0 {
		usage(stderr)
		return 2
	}
	configDir, err := configDir()
	if err != nil {
		fmt.Fprintf(stderr, "cmux-sprites: %v\n", err)
		return 1
	}
	ctx := context.Background()

	switch remaining[0] {
	case "login":
		fs := flag.NewFlagSet("login", flag.ContinueOnError)
		fs.SetOutput(stderr)
		openBrowser := fs.Bool("open", false, "open the verification URL after printing its code")
		if err := fs.Parse(remaining[1:]); err != nil {
			return 2
		}
		created, err := login(ctx, newClient(*apiBase, nil), *openBrowser, stdout)
		if err != nil {
			fmt.Fprintf(stderr, "login failed: %v\n", err)
			return 1
		}
		if err := saveTokens(configDir, created); err != nil {
			fmt.Fprintf(stderr, "saving login failed: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "Logged in to cmux Sprites.")
		return 0
	case "logout":
		if err := os.Remove(filepath.Join(configDir, "auth.json")); err != nil && !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(stderr, "logout failed: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "Logged out.")
		return 0
	case "status":
		loaded, err := loadTokens(configDir)
		if err != nil {
			fmt.Fprintf(stderr, "status failed: %v\n", err)
			return 1
		}
		return write(stdout, *jsonOutput, map[string]any{
			"loggedIn": loaded != nil,
			"apiBase":  strings.TrimRight(*apiBase, "/"),
		})
	case "list", "ls":
		client, ok := authedClient(*apiBase, configDir, stderr)
		if !ok {
			return 1
		}
		var result vmList
		if err := client.request(ctx, http.MethodGet, "/api/vm", nil, &result); err != nil {
			fmt.Fprintf(stderr, "list failed: %v\n", err)
			return 1
		}
		filtered := make([]vm, 0, len(result.VMs))
		for _, entry := range result.VMs {
			if entry.Provider == "sprites" {
				filtered = append(filtered, entry)
			}
		}
		if *jsonOutput {
			return writeJSON(stdout, map[string]any{"sprites": filtered})
		}
		for _, entry := range filtered {
			fmt.Fprintf(stdout, "%s\t%s\t%s\n", entry.ID, entry.Status, entry.ConnectionURL)
		}
		return 0
	case "create":
		fs := flag.NewFlagSet("create", flag.ContinueOnError)
		fs.SetOutput(stderr)
		teamID := fs.String("team", "", "Stack team id for ownership and billing")
		if err := fs.Parse(remaining[1:]); err != nil {
			return 2
		}
		client, ok := authedClient(*apiBase, configDir, stderr)
		if !ok {
			return 1
		}
		body := map[string]any{"provider": "sprites"}
		if strings.TrimSpace(*teamID) != "" {
			body["teamId"] = strings.TrimSpace(*teamID)
		}
		var created vm
		if err := client.request(ctx, http.MethodPost, "/api/vm", body, &created); err != nil {
			fmt.Fprintf(stderr, "create failed: %v\n", err)
			return 1
		}
		return write(stdout, *jsonOutput, created)
	case "destroy", "rm":
		if len(remaining) != 2 {
			fmt.Fprintln(stderr, "destroy requires a Sprite id")
			return 2
		}
		client, ok := authedClient(*apiBase, configDir, stderr)
		if !ok {
			return 1
		}
		if err := client.request(ctx, http.MethodDelete, "/api/vm/"+url.PathEscape(remaining[1]), nil, nil); err != nil {
			fmt.Fprintf(stderr, "destroy failed: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "Destroyed %s.\n", remaining[1])
		return 0
	case "exec":
		if len(remaining) < 3 {
			fmt.Fprintln(stderr, "exec requires a Sprite id and command")
			return 2
		}
		commandArgs := remaining[2:]
		if commandArgs[0] == "--" {
			commandArgs = commandArgs[1:]
		}
		if len(commandArgs) == 0 {
			fmt.Fprintln(stderr, "exec requires a command after --")
			return 2
		}
		client, ok := authedClient(*apiBase, configDir, stderr)
		if !ok {
			return 1
		}
		result, err := client.exec(ctx, remaining[1], shellJoin(commandArgs))
		if err != nil {
			fmt.Fprintf(stderr, "exec failed: %v\n", err)
			return 1
		}
		if *jsonOutput {
			return writeJSON(stdout, result)
		}
		fmt.Fprint(stdout, result.Stdout)
		fmt.Fprint(stderr, result.Stderr)
		return result.ExitCode
	case "connect":
		return connect(ctx, remaining[1:], *apiBase, configDir, stdout, stderr)
	case "help", "-h", "--help":
		usage(stdout)
		return 0
	default:
		fmt.Fprintf(stderr, "cmux-sprites: unknown command %q\n", remaining[0])
		usage(stderr)
		return 2
	}
}

func login(ctx context.Context, client *apiClient, openBrowser bool, out io.Writer) (tokens, error) {
	return loginWithClock(ctx, client, openBrowser, out, systemClock{})
}

func loginWithClock(
	ctx context.Context,
	client *apiClient,
	openBrowser bool,
	out io.Writer,
	clock retryClock,
) (tokens, error) {
	var started authStart
	if err := client.request(ctx, http.MethodPost, "/api/vault/cli/auth/start", map[string]string{
		"client": "cmux-sprites",
	}, &started); err != nil {
		return tokens{}, err
	}
	fmt.Fprintf(out, "Sign in at:\n  %s\n\nCopy and paste this code:\n  %s\n\n", started.VerificationURL, started.UserCode)
	if openBrowser {
		switch runtime.GOOS {
		case "darwin":
			_ = exec.Command("open", started.VerificationURL).Start()
		case "linux":
			_ = exec.Command("xdg-open", started.VerificationURL).Start()
		}
	}
	interval := time.Duration(max(started.IntervalSeconds, 1)) * time.Second
	expires := time.Duration(max(started.ExpiresInSeconds, 60)) * time.Second
	deadline := clock.Now().Add(expires)
	for {
		remaining := deadline.Sub(clock.Now())
		if remaining <= 0 {
			return tokens{}, errors.New("login expired before approval")
		}
		delay := min(interval, remaining)
		if err := clock.Sleep(ctx, delay); err != nil {
			return tokens{}, err
		}
		var polled authPoll
		if err := client.request(ctx, http.MethodPost, "/api/vault/cli/auth/poll", map[string]string{
			"deviceCode": started.DeviceCode,
		}, &polled); err != nil {
			return tokens{}, err
		}
		switch polled.Status {
		case "pending":
			continue
		case "approved":
			if polled.Client != "cmux-sprites" {
				return tokens{}, fmt.Errorf("server returned credentials for %q", polled.Client)
			}
			if polled.AccessToken == "" || polled.RefreshToken == "" {
				return tokens{}, errors.New("server approved login without credentials")
			}
			return tokens{AccessToken: polled.AccessToken, RefreshToken: polled.RefreshToken}, nil
		default:
			return tokens{}, fmt.Errorf("login %s", polled.Status)
		}
	}
}

func connect(ctx context.Context, args []string, apiBase, configDir string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("connect", flag.ContinueOnError)
	fs.SetOutput(stderr)
	cmuxBin := fs.String("cmux-bin", "cmux", "cmux TUI binary")
	deviceName := fs.String("device-name", hostname(), "enrolled device name")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(stderr, "connect requires a Sprite id")
		return 2
	}
	vmID := fs.Arg(0)
	client, ok := authedClient(apiBase, configDir, stderr)
	if !ok {
		return 1
	}
	var listed vmList
	if err := client.request(ctx, http.MethodGet, "/api/vm", nil, &listed); err != nil {
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	var selected *vm
	for i := range listed.VMs {
		if listed.VMs[i].ID == vmID && listed.VMs[i].Provider == "sprites" {
			selected = &listed.VMs[i]
			break
		}
	}
	if selected == nil || selected.ConnectionURL == "" {
		fmt.Fprintf(stderr, "connect failed: Sprite %s was not found or has no connection URL\n", vmID)
		return 1
	}
	advertise, err := enrollmentURL(selected.ConnectionURL)
	if err != nil {
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	createCommand := fmt.Sprintf(
		"/usr/local/bin/cmux enroll create --session sprite --state-dir %s --advertise %s --ttl 300 --json",
		shellQuote("/home/sprite/.local/share/cmux-sprite/remote"),
		shellQuote(advertise),
	)
	created, err := client.exec(ctx, vmID, createCommand)
	if err != nil {
		fmt.Fprintf(stderr, "connect failed to create enrollment: %v\n", err)
		return 1
	}
	if created.ExitCode != 0 {
		fmt.Fprintf(stderr, "connect failed to create enrollment: remote command exited %d\n", created.ExitCode)
		return 1
	}
	var invitation struct {
		URI string `json:"uri"`
	}
	if err := json.Unmarshal([]byte(created.Stdout), &invitation); err != nil || invitation.URI == "" {
		fmt.Fprintln(stderr, "connect failed: Sprite returned an invalid enrollment invitation")
		return 1
	}
	invitationID, err := invitationID(invitation.URI)
	if err != nil {
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	stateDir := filepath.Join(configDir, "devices", safePath(vmID))
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	inviteFile, err := os.CreateTemp(stateDir, ".invite-*.txt")
	if err != nil {
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	invitePath := inviteFile.Name()
	defer os.Remove(invitePath)
	if err := inviteFile.Chmod(0o600); err != nil {
		inviteFile.Close()
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	if _, err := fmt.Fprintln(inviteFile, invitation.URI); err != nil {
		inviteFile.Close()
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	if err := inviteFile.Close(); err != nil {
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}

	connectContext, cancelConnect := context.WithCancel(ctx)
	defer cancelConnect()
	command := exec.CommandContext(
		connectContext,
		*cmuxBin,
		"connect",
		"--invite-file",
		invitePath,
		"--device-name",
		*deviceName,
		"--state-dir",
		stateDir,
	)
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, stdout, stderr
	if err := command.Start(); err != nil {
		fmt.Fprintf(stderr, "connect failed to start cmux: %v\n", err)
		return 1
	}
	approval := make(chan error, 1)
	go func() {
		approval <- approveEnrollment(connectContext, client, vmID, invitationID)
	}()
	processDone := make(chan error, 1)
	go func() {
		processDone <- command.Wait()
	}()
	select {
	case err := <-approval:
		if err != nil {
			cancelConnect()
			<-processDone
			fmt.Fprintf(stderr, "connect approval failed: %v\n", err)
			return 1
		}
		return processExitCode(<-processDone, stderr)
	case err := <-processDone:
		cancelConnect()
		return processExitCode(err, stderr)
	}
}

func processExitCode(err error, stderr io.Writer) int {
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return exitErr.ExitCode()
		}
		fmt.Fprintf(stderr, "connect failed: %v\n", err)
		return 1
	}
	return 0
}

func approveEnrollment(ctx context.Context, client *apiClient, vmID, invitationID string) error {
	return approveEnrollmentWithClock(
		ctx,
		client,
		vmID,
		invitationID,
		systemClock{},
		45*time.Second,
	)
}

func approveEnrollmentWithClock(
	ctx context.Context,
	client enrollmentExecutor,
	vmID string,
	invitationID string,
	clock retryClock,
	timeout time.Duration,
) error {
	deadline := clock.Now().Add(timeout)
	var latestError error
	attempt := 0
	for {
		remaining := deadline.Sub(clock.Now())
		if remaining <= 0 {
			return enrollmentTimeoutError(latestError)
		}
		commandContext, cancelCommand := context.WithTimeout(ctx, remaining)
		pending, err := client.execWithTimeout(
			commandContext,
			vmID,
			"/usr/local/bin/cmux enroll pending --session sprite --state-dir "+
				shellQuote("/home/sprite/.local/share/cmux-sprite/remote")+" --json",
			enrollmentCommandTimeoutMs(remaining),
		)
		cancelCommand()
		if err != nil {
			latestError = err
		} else if pending.ExitCode != 0 {
			latestError = fmt.Errorf("pending-enrollment command exited %d", pending.ExitCode)
		}
		if deadline.Sub(clock.Now()) <= 0 {
			return enrollmentTimeoutError(latestError)
		}
		if err == nil && pending.ExitCode == 0 {
			var requests []struct {
				InvitationID string `json:"invitation_id"`
			}
			if json.Unmarshal([]byte(pending.Stdout), &requests) == nil {
				for _, request := range requests {
					if request.InvitationID == invitationID {
						approvalRemaining := deadline.Sub(clock.Now())
						if approvalRemaining <= 0 {
							return enrollmentTimeoutError(latestError)
						}
						approvalContext, cancelApproval := context.WithTimeout(
							ctx,
							approvalRemaining,
						)
						approved, err := client.execWithTimeout(
							approvalContext,
							vmID,
							"/usr/local/bin/cmux enroll approve "+shellQuote(invitationID)+
								" --session sprite --state-dir "+
								shellQuote("/home/sprite/.local/share/cmux-sprite/remote"),
							enrollmentCommandTimeoutMs(approvalRemaining),
						)
						cancelApproval()
						if err != nil {
							return err
						}
						if approved.ExitCode != 0 {
							return fmt.Errorf("enrollment approval command exited %d", approved.ExitCode)
						}
						return nil
					}
				}
			}
		}
		remaining = deadline.Sub(clock.Now())
		if remaining <= 0 {
			return enrollmentTimeoutError(latestError)
		}
		delay := min(time.Second<<min(attempt, 1), remaining)
		if err := clock.Sleep(ctx, delay); err != nil {
			return err
		}
		attempt++
	}
}

func enrollmentCommandTimeoutMs(remaining time.Duration) int {
	const maximum = 8_000
	milliseconds := int(remaining.Milliseconds())
	if milliseconds < 1 {
		return 1
	}
	return min(milliseconds, maximum)
}

func enrollmentTimeoutError(latestError error) error {
	if latestError != nil {
		return fmt.Errorf(
			"timed out waiting for the device enrollment claim; last check: %w",
			latestError,
		)
	}
	return errors.New("timed out waiting for the device enrollment claim")
}

func (c *apiClient) exec(ctx context.Context, vmID, command string) (execResult, error) {
	return c.execWithTimeout(ctx, vmID, command, 60_000)
}

func (c *apiClient) execWithTimeout(
	ctx context.Context,
	vmID string,
	command string,
	timeoutMs int,
) (execResult, error) {
	var result execResult
	err := c.request(ctx, http.MethodPost, "/api/vm/"+url.PathEscape(vmID)+"/exec", map[string]any{
		"command":   command,
		"timeoutMs": timeoutMs,
	}, &result)
	return result, err
}

func (c *apiClient) request(ctx context.Context, method, path string, body any, out any) error {
	if c.baseErr != nil {
		return c.baseErr
	}
	var payload []byte
	var err error
	if body != nil {
		payload, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	request, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if c.tokens != nil {
		request.Header.Set("Authorization", "Bearer "+c.tokens.AccessToken)
		request.Header.Set("X-Stack-Refresh-Token", c.tokens.RefreshToken)
	}
	response, err := c.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 12*1024*1024))
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return apiResponseError(response.StatusCode, data)
	}
	if out != nil && len(data) > 0 {
		return json.Unmarshal(data, out)
	}
	return nil
}

func newClient(baseURL string, value *tokens) *apiClient {
	normalized, baseErr := normalizedAPIBase(baseURL, value != nil)
	httpClient := &http.Client{
		Timeout: 90 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) == 0 {
				return nil
			}
			original := via[0].URL
			if request.URL.Scheme != original.Scheme || request.URL.Host != original.Host {
				return errors.New("refusing cross-origin API redirect")
			}
			return nil
		},
	}
	if baseErr == nil {
		httpClient.Transport, baseErr = customCARootTransport(
			strings.TrimSpace(os.Getenv("CMUX_SPRITES_CA_FILE")),
		)
	}
	return &apiClient{
		baseURL: normalized,
		baseErr: baseErr,
		tokens:  value,
		http:    httpClient,
	}
}

func customCARootTransport(path string) (http.RoundTripper, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("could not read CMUX_SPRITES_CA_FILE")
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(data) {
		return nil, errors.New("CMUX_SPRITES_CA_FILE contains no certificates")
	}
	return &http.Transport{
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			RootCAs:    roots,
		},
	}, nil
}

func normalizedAPIBase(raw string, credentialed bool) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" || parsed.User != nil ||
		parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", errors.New("invalid cmux API base URL")
	}
	if parsed.Scheme != "https" {
		host := parsed.Hostname()
		if parsed.Scheme != "http" ||
			(host != "localhost" && host != "127.0.0.1" && host != "::1") {
			return "", errors.New("cmux API base URL must use HTTPS")
		}
		if credentialed {
			return "", errors.New("credentialed cmux API requests require HTTPS")
		}
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return parsed.String(), nil
}

func apiResponseError(status int, data []byte) error {
	code := ""
	var envelope struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal(data, &envelope) == nil && len(envelope.Error) > 0 {
		var direct string
		if json.Unmarshal(envelope.Error, &direct) == nil {
			code = direct
		} else {
			var nested struct {
				Code string `json:"code"`
			}
			if json.Unmarshal(envelope.Error, &nested) == nil {
				code = nested.Code
			}
		}
	}
	if code != "" {
		for _, char := range code {
			if !((char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') ||
				char == '_' || char == '-' || char == '.') {
				code = ""
				break
			}
		}
	}
	if code != "" && len(code) <= 80 {
		return fmt.Errorf("cmux API request failed (status %d, code %s)", status, code)
	}
	return fmt.Errorf("cmux API request failed (status %d)", status)
}

func authedClient(apiBase, dir string, stderr io.Writer) (*apiClient, bool) {
	loaded, err := loadTokens(dir)
	if err != nil {
		fmt.Fprintf(stderr, "loading login failed: %v\n", err)
		return nil, false
	}
	if loaded == nil {
		fmt.Fprintln(stderr, "not logged in; run cmux-sprites login")
		return nil, false
	}
	return newClient(apiBase, loaded), true
}

func configDir() (string, error) {
	if configured := strings.TrimSpace(os.Getenv("CMUX_SPRITES_CONFIG_DIR")); configured != "" {
		return configured, nil
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "", errors.New("could not resolve the home directory")
	}
	return filepath.Join(home, ".config", "cmux-sprites"), nil
}

func loadTokens(dir string) (*tokens, error) {
	data, err := os.ReadFile(filepath.Join(dir, "auth.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var loaded tokens
	if err := json.Unmarshal(data, &loaded); err != nil {
		return nil, err
	}
	if loaded.AccessToken == "" || loaded.RefreshToken == "" {
		return nil, nil
	}
	return &loaded, nil
}

func saveTokens(dir string, value tokens) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	temp, err := os.CreateTemp(dir, ".auth-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), filepath.Join(dir, "auth.json"))
}

func enrollmentURL(raw string) (string, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return "", errors.New("Sprite returned an invalid HTTPS URL")
	}
	parsed.Scheme = "wss"
	parsed.Path = "/v1/link"
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

func invitationID(uri string) (string, error) {
	const prefix = "cmux://enroll/"
	if !strings.HasPrefix(uri, prefix) || len(uri) > len(prefix)+16*1024 {
		return "", errors.New("invalid enrollment invitation URI")
	}
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(uri, prefix))
	if err != nil {
		return "", errors.New("invalid enrollment invitation encoding")
	}
	var invitation struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(decoded, &invitation); err != nil {
		return "", errors.New("invalid enrollment invitation payload")
	}
	if invitation.ID == "" || strings.ContainsAny(invitation.ID, " \t\r\n'\"") {
		return "", errors.New("invalid enrollment invitation id")
	}
	return invitation.ID, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func shellJoin(args []string) string {
	quoted := make([]string, len(args))
	for i, value := range args {
		quoted[i] = shellQuote(value)
	}
	return strings.Join(quoted, " ")
}

func safePath(value string) string {
	var builder strings.Builder
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '-' || char == '_' {
			builder.WriteRune(char)
		}
	}
	if builder.Len() == 0 {
		return "sprite"
	}
	return builder.String()
}

func hostname() string {
	value, err := os.Hostname()
	if err != nil || strings.TrimSpace(value) == "" {
		return "cmux-sprites"
	}
	return value
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func write(out io.Writer, asJSON bool, value any) int {
	if asJSON {
		return writeJSON(out, value)
	}
	switch typed := value.(type) {
	case vm:
		fmt.Fprintf(out, "%s\t%s\t%s\n", typed.ID, typed.Status, typed.ConnectionURL)
	default:
		data, _ := json.Marshal(value)
		fmt.Fprintln(out, string(data))
	}
	return 0
}

func writeJSON(out io.Writer, value any) int {
	encoder := json.NewEncoder(out)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return 1
	}
	return 0
}

func usage(out io.Writer) {
	fmt.Fprintln(out, `usage: cmux-sprites [--api-base URL] [--json] <command>

commands:
  login [--open]             sign in with a copy-paste device code
  logout                     delete locally stored Stack credentials
  status                     show local authentication state
  create [--team ID]         create a cmux Sprite through cmux.com
  list                       list your cmux Sprites
  exec <id> -- <command>     execute a command through cmux.com
  connect <id>               enroll this device and open the cmux TUI
  destroy <id>               destroy a Sprite`)
}
