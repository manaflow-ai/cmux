package syncer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/klauspost/compress/zstd"
	"github.com/manaflow-ai/cmux/vault/internal/agentdirs"
	"github.com/manaflow-ai/cmux/vault/internal/api"
	"github.com/manaflow-ai/cmux/vault/internal/state"
)

const maxUploadBatch = 25

type Printer interface {
	Printf(format string, args ...any)
}

type Options struct {
	Agent  string
	DryRun bool
	Limit  int
}

type Summary struct {
	Uploaded                int   `json:"uploaded"`
	Skipped                 int   `json:"skipped"`
	Failed                  int   `json:"failed"`
	BytesUploaded           int64 `json:"bytesUploaded"`
	CompressedBytesUploaded int64 `json:"compressedBytesUploaded"`
}

type Engine struct {
	Env     agentdirs.Environ
	State   *state.Store
	Client  *api.Client
	TempDir string
	Out     Printer
}

type candidate struct {
	session agentdirs.Session
	// sha256 is the plaintext digest sent to the server. After prepareBatch it
	// is recomputed from the exact bytes that were compressed, so a transcript
	// that changes between scan and upload can never commit a stale hash.
	sha256         string
	plainSize      int64
	compressed     string
	compressedSize int64
}

func (e *Engine) Sync(ctx context.Context, opts Options) (Summary, error) {
	sessions, err := agentdirs.DiscoverAll(e.Env, opts.Agent)
	if err != nil {
		return Summary{}, err
	}
	return e.syncSessions(ctx, sessions, opts)
}

func (e *Engine) syncSessions(ctx context.Context, sessions []agentdirs.Session, opts Options) (Summary, error) {
	var summary Summary

	var candidates []candidate
	for _, session := range sessions {
		key := state.Key(session.AgentName, session.RelPath)
		entry := e.State.Entries[key]
		if entry.SizeBytes == session.SizeBytes && entry.MtimeUnixNs == session.ModTime.UnixNano() {
			summary.Skipped++
			e.print("skip unchanged %s %s\n", session.AgentName, session.RelPath)
			continue
		}
		hash, err := sha256File(session.AbsPath)
		if err != nil {
			summary.Failed++
			e.print("fail hash %s %s: %v\n", session.AgentName, session.RelPath, err)
			continue
		}
		if hash == entry.RemoteSHA256 {
			e.State.Entries[key] = state.Entry{
				SizeBytes:    session.SizeBytes,
				MtimeUnixNs:  session.ModTime.UnixNano(),
				SHA256:       hash,
				RemoteSHA256: entry.RemoteSHA256,
			}
			summary.Skipped++
			e.print("skip already uploaded %s %s\n", session.AgentName, session.RelPath)
			continue
		}
		candidates = append(candidates, candidate{session: session, sha256: hash, plainSize: session.SizeBytes})
		if opts.Limit > 0 && len(candidates) >= opts.Limit {
			break
		}
	}

	if opts.DryRun {
		for _, c := range candidates {
			e.print("would upload %s %s (%d bytes)\n", c.session.AgentName, c.session.RelPath, c.session.SizeBytes)
		}
		summary.Skipped += len(candidates)
		// Dry run must not advance sync bookkeeping, so skip State.Save even
		// though the scan loop may have reconciled entries in memory.
		return summary, nil
	}

	var uploaded []candidate
	for start := 0; start < len(candidates); start += maxUploadBatch {
		end := min(start+maxUploadBatch, len(candidates))
		batch := candidates[start:end]
		prepared, err := e.prepareBatch(batch)
		if err != nil {
			summary.Failed += len(batch)
			e.print("fail prepare batch: %v\n", err)
			continue
		}
		results, err := e.Client.RequestUploads(ctx, uploadItems(prepared))
		if err != nil {
			summary.Failed += len(prepared)
			e.print("fail presign batch: %v\n", err)
			e.cleanup(prepared)
			continue
		}
		resultByKey := map[string]api.UploadResult{}
		for _, result := range results.Items {
			resultByKey[itemKey(result.Agent, result.RelPath)] = result
		}

		var toUpload []candidate
		for _, c := range prepared {
			result := resultByKey[itemKey(c.session.AgentName, c.session.RelPath)]
			switch result.Status {
			case "unchanged":
				e.markUploaded(c)
				summary.Skipped++
				e.print("skip cloud unchanged %s %s\n", c.session.AgentName, c.session.RelPath)
				_ = os.Remove(c.compressed)
			case "upload":
				if result.PutURL == "" {
					summary.Failed++
					e.print("fail presign %s %s: missing putUrl\n", c.session.AgentName, c.session.RelPath)
					_ = os.Remove(c.compressed)
					continue
				}
				toUpload = append(toUpload, c)
			default:
				summary.Failed++
				if result.Error == "" {
					result.Error = "unexpected_presign_status"
				}
				e.print("fail presign %s %s: %s\n", c.session.AgentName, c.session.RelPath, result.Error)
				_ = os.Remove(c.compressed)
			}
		}

		successes, failures := e.uploadBatch(ctx, toUpload, resultByKey)
		summary.Failed += failures
		if len(successes) == 0 {
			continue
		}
		commit, err := e.Client.CommitSessions(ctx, uploadItems(successes))
		if err != nil {
			summary.Failed += len(successes)
			e.print("fail commit batch: %v\n", err)
			e.cleanup(successes)
			continue
		}
		commitByKey := map[string]api.CommitResult{}
		for _, result := range commit.Items {
			commitByKey[itemKey(result.Agent, result.RelPath)] = result
		}
		for _, c := range successes {
			result := commitByKey[itemKey(c.session.AgentName, c.session.RelPath)]
			if result.Status != "committed" && result.Status != "unchanged" {
				summary.Failed++
				if result.Error == "" {
					result.Error = "commit_failed"
				}
				e.print("fail commit %s %s: %s\n", c.session.AgentName, c.session.RelPath, result.Error)
				_ = os.Remove(c.compressed)
				continue
			}
			e.markUploaded(c)
			summary.Uploaded++
			summary.BytesUploaded += c.session.SizeBytes
			summary.CompressedBytesUploaded += c.compressedSize
			e.print("uploaded %s %s (%d -> %d bytes)\n", c.session.AgentName, c.session.RelPath, c.session.SizeBytes, c.compressedSize)
			uploaded = append(uploaded, c)
			_ = os.Remove(c.compressed)
		}
	}

	if err := e.State.Save(); err != nil {
		return summary, err
	}
	if summary.Failed > 0 {
		return summary, fmt.Errorf("%d upload(s) failed", summary.Failed)
	}
	return summary, nil
}

func (e *Engine) prepareBatch(batch []candidate) ([]candidate, error) {
	prepared := make([]candidate, 0, len(batch))
	for _, c := range batch {
		result, err := compressFile(c.session.AbsPath, e.TempDir)
		if err != nil {
			e.cleanup(prepared)
			return nil, err
		}
		// Re-anchor the hash and size to the snapshot that will actually be
		// uploaded; the scan-time hash may be stale if the agent kept writing.
		c.sha256 = result.plainSHA256
		c.plainSize = result.plainSize
		c.compressed = result.path
		c.compressedSize = result.compressedSize
		prepared = append(prepared, c)
	}
	return prepared, nil
}

func (e *Engine) uploadBatch(ctx context.Context, batch []candidate, results map[string]api.UploadResult) ([]candidate, int) {
	if len(batch) == 0 {
		return nil, 0
	}
	jobs := make(chan candidate)
	var successesMu sync.Mutex
	var successes []candidate
	var failures int32
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for c := range jobs {
				result := results[itemKey(c.session.AgentName, c.session.RelPath)]
				file, err := os.Open(c.compressed)
				if err == nil {
					err = e.Client.PutObject(ctx, result.PutURL, file, c.compressedSize)
				}
				if file != nil {
					_ = file.Close()
				}
				if err != nil {
					atomic.AddInt32(&failures, 1)
					e.print("fail upload %s %s: %v\n", c.session.AgentName, c.session.RelPath, err)
					_ = os.Remove(c.compressed)
					continue
				}
				successesMu.Lock()
				successes = append(successes, c)
				successesMu.Unlock()
			}
		}()
	}
	for _, c := range batch {
		jobs <- c
	}
	close(jobs)
	wg.Wait()
	return successes, int(failures)
}

func (e *Engine) markUploaded(c candidate) {
	e.State.Entries[state.Key(c.session.AgentName, c.session.RelPath)] = state.Entry{
		SizeBytes:    c.session.SizeBytes,
		MtimeUnixNs:  c.session.ModTime.UnixNano(),
		SHA256:       c.sha256,
		RemoteSHA256: c.sha256,
	}
}

func (e *Engine) cleanup(batch []candidate) {
	for _, c := range batch {
		if c.compressed != "" {
			_ = os.Remove(c.compressed)
		}
	}
}

func (e *Engine) print(format string, args ...any) {
	if e.Out != nil {
		e.Out.Printf(format, args...)
	}
}

func uploadItems(candidates []candidate) []api.UploadItem {
	items := make([]api.UploadItem, 0, len(candidates))
	for _, c := range candidates {
		items = append(items, api.UploadItem{
			Agent:               c.session.AgentName,
			AgentSessionID:      c.session.AgentSessionID,
			RelPath:             c.session.RelPath,
			CWD:                 c.session.CWD,
			SHA256:              c.sha256,
			SizeBytes:           c.plainSize,
			CompressedSizeBytes: c.compressedSize,
		})
	}
	return items
}

func itemKey(agent, relPath string) string {
	return strings.TrimSpace(agent) + "\x00" + strings.TrimSpace(relPath)
}

func sha256File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

type compressResult struct {
	path           string
	compressedSize int64
	plainSHA256    string
	plainSize      int64
}

func compressFile(path, tempDir string) (compressResult, error) {
	var result compressResult
	if strings.TrimSpace(tempDir) == "" {
		tempDir = os.TempDir()
	}
	if err := os.MkdirAll(tempDir, 0o700); err != nil {
		return result, err
	}
	in, err := os.Open(path)
	if err != nil {
		return result, err
	}
	defer in.Close()

	tmp, err := os.CreateTemp(tempDir, "cmux-vault-*.jsonl.zst")
	if err != nil {
		return result, err
	}
	tmpPath := tmp.Name()
	encoder, err := zstd.NewWriter(tmp)
	if err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return result, err
	}
	// Hash the plaintext while compressing so the digest always matches the
	// exact bytes inside the uploaded snapshot.
	hash := sha256.New()
	plainSize, copyErr := io.Copy(encoder, io.TeeReader(in, hash))
	closeErr := encoder.Close()
	fileCloseErr := tmp.Close()
	if copyErr != nil || closeErr != nil || fileCloseErr != nil {
		_ = os.Remove(tmpPath)
		if copyErr != nil {
			return result, copyErr
		}
		if closeErr != nil {
			return result, closeErr
		}
		return result, fileCloseErr
	}
	info, err := os.Stat(tmpPath)
	if err != nil {
		_ = os.Remove(tmpPath)
		return result, err
	}
	result.path = tmpPath
	result.compressedSize = info.Size()
	result.plainSHA256 = hex.EncodeToString(hash.Sum(nil))
	result.plainSize = plainSize
	return result, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
