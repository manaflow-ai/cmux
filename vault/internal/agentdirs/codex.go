package agentdirs

import (
	"bufio"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type Codex struct{}

var codexRolloutRE = regexp.MustCompile(`(?i)^rollout-.+-(` + uuidPattern + `)\.jsonl$`)

func (Codex) Name() string { return "codex" }

func codexRoot(env Environ) (string, error) {
	if root := env.Get("CODEX_HOME"); root != "" {
		return root, nil
	}
	return pathUnderHome(env, ".codex")
}

func (a Codex) Discover(env Environ) ([]Session, error) {
	root, err := codexRoot(env)
	if err != nil {
		return nil, err
	}
	var sessions []Session
	for _, dir := range []string{"sessions", "archived_sessions"} {
		walkRoot := filepath.Join(root, dir)
		resolvedWalkRoot := resolveWalkRoot(env, a.Name(), walkRoot)
		if err := filepath.WalkDir(resolvedWalkRoot, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				if filepath.Clean(path) == filepath.Clean(resolvedWalkRoot) {
					return nil
				}
				env.Warn("codex: skipping unreadable path %s: %v", path, walkErr)
				if entry != nil && entry.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if entry.IsDir() {
				return nil
			}
			id := codexIDFromFilename(entry.Name())
			if id == "" {
				return nil
			}
			metaID, cwd := codexMeta(path)
			if metaID != "" {
				id = metaID
			}
			logicalPath := logicalWalkPath(walkRoot, resolvedWalkRoot, path)
			session, err := statSessionWithLogicalPath(a.Name(), root, path, logicalPath, id, cwd)
			if err != nil {
				env.Warn("codex: skipping session %s after stat failed: %v", path, err)
				return nil
			}
			sessions = append(sessions, session)
			return nil
		}); err != nil {
			return nil, err
		}
	}
	return sessions, nil
}

func codexIDFromFilename(name string) string {
	matches := codexRolloutRE.FindStringSubmatch(name)
	if len(matches) != 2 {
		return ""
	}
	return strings.ToLower(matches[1])
}

func codexMeta(path string) (string, string) {
	file, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	if !scanner.Scan() {
		return "", ""
	}
	var line struct {
		Type    string `json:"type"`
		Payload struct {
			ID  string `json:"id"`
			CWD string `json:"cwd"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &line); err != nil {
		return "", ""
	}
	if line.Type != "session_meta" {
		return "", recoverCWDFromJSONL(path)
	}
	id := strings.TrimSpace(line.Payload.ID)
	if !uuidRE.MatchString(id) {
		id = ""
	}
	return strings.ToLower(id), strings.TrimSpace(line.Payload.CWD)
}

func (Codex) RestorePath(env Environ, s SessionRef) (string, error) {
	root, err := codexRoot(env)
	if err != nil {
		return "", err
	}
	return cleanRestorePath(root, s.RelPath)
}

func (Codex) ResumeHint(s SessionRef) string {
	return "codex resume " + s.AgentSessionID
}
