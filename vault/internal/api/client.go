package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/manaflow-ai/cmux/vault/internal/authstore"
)

const DefaultBaseURL = "https://cmux.com"

type Client struct {
	BaseURL        string
	Tokens         *authstore.Tokens
	HTTPClient     *http.Client
	BlobHTTPClient *http.Client
}

type AuthStartResponse struct {
	DeviceCode       string `json:"deviceCode"`
	UserCode         string `json:"userCode"`
	VerificationURL  string `json:"verificationUrl"`
	ExpiresInSeconds int    `json:"expiresInSeconds"`
	IntervalSeconds  int    `json:"intervalSeconds"`
}

type AuthPollResponse struct {
	Status       string `json:"status"`
	AccessToken  string `json:"accessToken,omitempty"`
	RefreshToken string `json:"refreshToken,omitempty"`
}

type UploadItem struct {
	Agent               string `json:"agent"`
	AgentSessionID      string `json:"agentSessionId"`
	RelPath             string `json:"relPath"`
	CWD                 string `json:"cwd,omitempty"`
	SHA256              string `json:"sha256"`
	SizeBytes           int64  `json:"sizeBytes"`
	CompressedSizeBytes int64  `json:"compressedSizeBytes"`
}

type UploadResult struct {
	Agent          string `json:"agent"`
	AgentSessionID string `json:"agentSessionId"`
	RelPath        string `json:"relPath"`
	Status         string `json:"status"`
	ObjectKey      string `json:"objectKey,omitempty"`
	PutURL         string `json:"putUrl,omitempty"`
	Error          string `json:"error,omitempty"`
}

type UploadsResponse struct {
	Items []UploadResult `json:"items"`
}

type CommitResult struct {
	Agent          string `json:"agent"`
	AgentSessionID string `json:"agentSessionId"`
	RelPath        string `json:"relPath"`
	Status         string `json:"status"`
	Error          string `json:"error,omitempty"`
	SessionID      string `json:"sessionId,omitempty"`
}

type CommitResponse struct {
	Items []CommitResult `json:"items"`
}

type Session struct {
	ID             string `json:"id"`
	Agent          string `json:"agent"`
	AgentSessionID string `json:"agentSessionId"`
	RelPath        string `json:"relPath"`
	CWD            string `json:"cwd,omitempty"`
	LatestSHA256   string `json:"latestSha256"`
	SizeBytes      int64  `json:"sizeBytes"`
	LastUploadedAt string `json:"lastUploadedAt"`
	DownloadURL    string `json:"downloadUrl,omitempty"`
}

type SessionsResponse struct {
	Sessions   []Session `json:"sessions"`
	NextCursor string    `json:"nextCursor,omitempty"`
}

type Snapshot struct {
	SHA256              string `json:"sha256"`
	SizeBytes           int64  `json:"sizeBytes"`
	CompressedSizeBytes int64  `json:"compressedSizeBytes"`
	UploadedAt          string `json:"uploadedAt"`
}

type SessionDetail struct {
	Session
	Snapshots []Snapshot `json:"snapshots"`
}

func New(baseURL string, tokens *authstore.Tokens) *Client {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	return &Client{
		BaseURL: baseURL,
		Tokens:  tokens,
		HTTPClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		// Blob transfers can be large, so allow far more than the JSON timeout,
		// but still bound the request so a stalled S3 PUT/GET cannot hang the
		// CLI forever.
		BlobHTTPClient: &http.Client{
			Timeout: 15 * time.Minute,
		},
	}
}

func (c *Client) StartAuth(ctx context.Context) (AuthStartResponse, error) {
	var out AuthStartResponse
	err := c.doJSON(ctx, "POST", "/api/vault/cli/auth/start", map[string]any{}, false, &out)
	return out, err
}

func (c *Client) PollAuth(ctx context.Context, deviceCode string) (AuthPollResponse, error) {
	var out AuthPollResponse
	err := c.doJSON(ctx, "POST", "/api/vault/cli/auth/poll", map[string]string{"deviceCode": deviceCode}, false, &out)
	return out, err
}

func (c *Client) RequestUploads(ctx context.Context, items []UploadItem) (UploadsResponse, error) {
	var out UploadsResponse
	err := c.doJSON(ctx, "POST", "/api/vault/uploads", map[string]any{"items": items}, true, &out)
	return out, err
}

func (c *Client) CommitSessions(ctx context.Context, items []UploadItem) (CommitResponse, error) {
	var out CommitResponse
	err := c.doJSON(ctx, "POST", "/api/vault/sessions/commit", map[string]any{"items": items}, true, &out)
	return out, err
}

func (c *Client) FindSession(ctx context.Context, agent, agentSessionID string) (*Session, error) {
	// Resume lookup uses the sessions collection route filtered by
	// agent+agentSessionId; callers then use GetSession(id) to fetch the
	// presigned download URL for the latest snapshot.
	values := url.Values{}
	if strings.TrimSpace(agent) != "" {
		values.Set("agent", agent)
	}
	values.Set("agentSessionId", agentSessionID)
	// Ask for two rows so an id shared by multiple agents is detected instead
	// of restoring an arbitrary one.
	values.Set("limit", "2")
	var out SessionsResponse
	if err := c.doJSON(ctx, "GET", "/api/vault/sessions?"+values.Encode(), nil, true, &out); err != nil {
		return nil, err
	}
	if len(out.Sessions) == 0 {
		return nil, nil
	}
	if len(out.Sessions) > 1 {
		return nil, fmt.Errorf("session %s exists for multiple agents in cmux vault; pass --agent to disambiguate", agentSessionID)
	}
	return &out.Sessions[0], nil
}

func (c *Client) GetSession(ctx context.Context, id string) (SessionDetail, error) {
	var out SessionDetail
	err := c.doJSON(ctx, "GET", "/api/vault/sessions/"+url.PathEscape(id), nil, true, &out)
	return out, err
}

func (c *Client) PutObject(ctx context.Context, putURL string, body io.ReadSeeker, size int64) error {
	req, err := http.NewRequestWithContext(ctx, "PUT", putURL, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/zstd")
	req.ContentLength = size
	resp, err := c.blobHTTPClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		limited, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("storage PUT failed: status %d: %s", resp.StatusCode, strings.TrimSpace(string(limited)))
	}
	return nil
}

func (c *Client) Download(ctx context.Context, downloadURL string) (io.ReadCloser, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", downloadURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.blobHTTPClient().Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		defer resp.Body.Close()
		limited, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("storage GET failed: status %d: %s", resp.StatusCode, strings.TrimSpace(string(limited)))
	}
	return resp.Body, nil
}

func (c *Client) doJSON(ctx context.Context, method, path string, body any, auth bool, out any) error {
	var payload []byte
	var err error
	if body != nil {
		payload, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(250 * time.Millisecond):
			}
		}
		err := c.doJSONOnce(ctx, method, path, payload, auth, out)
		if err == nil {
			return nil
		}
		lastErr = err
		var statusErr statusError
		if errors.As(err, &statusErr) {
			if statusErr.StatusCode < 500 {
				return err
			}
			continue
		}
		continue
	}
	return lastErr
}

func (c *Client) doJSONOnce(ctx context.Context, method, path string, payload []byte, auth bool, out any) error {
	endpoint := c.BaseURL + path
	req, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if auth {
		if c.Tokens == nil || c.Tokens.AccessToken == "" || c.Tokens.RefreshToken == "" {
			return errors.New("not logged in; run cmux-vault login")
		}
		req.Header.Set("Authorization", "Bearer "+c.Tokens.AccessToken)
		req.Header.Set("X-Stack-Refresh-Token", c.Tokens.RefreshToken)
	}
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024))
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return statusError{StatusCode: resp.StatusCode, Body: string(data)}
	}
	if out == nil {
		return nil
	}
	if len(data) == 0 {
		return nil
	}
	return json.Unmarshal(data, out)
}

func (c *Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return http.DefaultClient
}

func (c *Client) blobHTTPClient() *http.Client {
	if c.BlobHTTPClient != nil {
		return c.BlobHTTPClient
	}
	return http.DefaultClient
}

type statusError struct {
	StatusCode int
	Body       string
}

func (e statusError) Error() string {
	return fmt.Sprintf("api request failed: status %d: %s", e.StatusCode, strings.TrimSpace(e.Body))
}
