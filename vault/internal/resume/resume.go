package resume

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
	"github.com/manaflow-ai/cmux/vault/internal/agentdirs"
	"github.com/manaflow-ai/cmux/vault/internal/api"
)

type Printer interface {
	Printf(format string, args ...any)
}

type Options struct {
	Agent string
	Force bool
}

type Restorer struct {
	Env    agentdirs.Environ
	Client *api.Client
	Out    Printer
}

func (r *Restorer) Resume(ctx context.Context, sessionID string, opts Options) (string, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return "", errors.New("session id is required")
	}
	local, err := r.findLocal(sessionID, opts.Agent)
	if err != nil {
		return "", err
	}
	// --force means "replace whatever is on disk from the vault", so skip the
	// local fast path and let the cloud restore overwrite it.
	if local != nil && !opts.Force {
		agent, _ := agentdirs.ByName(local.AgentName)
		hint := agent.ResumeHint(agentdirs.SessionRef{
			AgentName:      local.AgentName,
			AgentSessionID: local.AgentSessionID,
			RelPath:        local.RelPath,
			CWD:            local.CWD,
		})
		r.print("%s\n", hint)
		return hint, nil
	}

	cloudSession, err := r.Client.FindSession(ctx, opts.Agent, sessionID)
	if err != nil {
		return "", err
	}
	if cloudSession == nil {
		return "", fmt.Errorf("session %s not found locally or in cmux vault", sessionID)
	}
	detail, err := r.Client.GetSession(ctx, cloudSession.ID)
	if err != nil {
		return "", err
	}
	if detail.DownloadURL == "" {
		return "", errors.New("server did not return a download URL")
	}
	agent, ok := agentdirs.ByName(detail.Agent)
	if !ok {
		return "", fmt.Errorf("unknown agent %q from server", detail.Agent)
	}
	ref := agentdirs.SessionRef{
		AgentName:      detail.Agent,
		AgentSessionID: detail.AgentSessionID,
		RelPath:        detail.RelPath,
		CWD:            detail.CWD,
	}
	restorePath, err := agent.RestorePath(r.Env, ref)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(restorePath); err == nil && !opts.Force {
		return "", fmt.Errorf("%s already exists; pass --force to overwrite", restorePath)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(restorePath), 0o700); err != nil {
		return "", err
	}
	reader, err := r.Client.Download(ctx, detail.DownloadURL)
	if err != nil {
		return "", err
	}
	defer reader.Close()
	if err := decompressToPath(reader, restorePath); err != nil {
		return "", err
	}
	hint := agent.ResumeHint(ref)
	r.print("restored %s\n%s\n", restorePath, hint)
	return hint, nil
}

func (r *Restorer) findLocal(sessionID, agentFilter string) (*agentdirs.Session, error) {
	sessions, err := agentdirs.DiscoverAll(r.Env, agentFilter)
	if err != nil {
		return nil, err
	}
	var found *agentdirs.Session
	for i := range sessions {
		if sessions[i].AgentSessionID != sessionID {
			continue
		}
		if found != nil {
			return nil, fmt.Errorf("session id %s exists for multiple agents; pass --agent", sessionID)
		}
		copy := sessions[i]
		found = &copy
	}
	return found, nil
}

func (r *Restorer) print(format string, args ...any) {
	if r.Out != nil {
		r.Out.Printf(format, args...)
	}
}

func decompressToPath(reader io.Reader, target string) error {
	tmp, err := os.CreateTemp(filepath.Dir(target), ".restore-*.jsonl")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer func() {
		_ = os.Remove(tmpPath)
	}()
	decoder, err := zstd.NewReader(reader)
	if err != nil {
		_ = tmp.Close()
		return err
	}
	_, copyErr := io.Copy(tmp, decoder)
	decoder.Close()
	closeErr := tmp.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Chmod(tmpPath, 0o600); err != nil {
		return err
	}
	return os.Rename(tmpPath, target)
}
