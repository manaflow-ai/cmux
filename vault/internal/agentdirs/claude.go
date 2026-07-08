package agentdirs

import (
	"io/fs"
	"path/filepath"
	"strings"
)

type Claude struct{}

func (Claude) Name() string { return "claude" }

func claudeRoot(env Environ) (string, error) {
	if root := env.Get("CLAUDE_CONFIG_DIR"); root != "" {
		return root, nil
	}
	return pathUnderHome(env, ".claude")
}

func (a Claude) Discover(env Environ) ([]Session, error) {
	root, err := claudeRoot(env)
	if err != nil {
		return nil, err
	}
	projectsRoot := filepath.Join(root, "projects")
	walkRoot := resolveWalkRoot(env, a.Name(), projectsRoot)
	var sessions []Session
	if err := filepath.WalkDir(walkRoot, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			if filepath.Clean(path) == filepath.Clean(walkRoot) {
				return nil
			}
			env.Warn("claude: skipping unreadable path %s: %v", path, walkErr)
			if entry != nil && entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		if IsSymlinkEntry(entry) {
			env.Warn("claude: skipping symlinked session %s", path)
			return nil
		}
		if filepath.Ext(entry.Name()) != ".jsonl" {
			return nil
		}
		id := strings.TrimSuffix(entry.Name(), ".jsonl")
		if !uuidRE.MatchString(id) {
			return nil
		}
		projectName := filepath.Base(filepath.Dir(path))
		cwd := recoverCWDFromJSONL(path)
		if cwd == "" {
			cwd = cwdFromMunged(projectName)
		}
		logicalPath := logicalWalkPath(projectsRoot, walkRoot, path)
		session, err := statSessionWithLogicalPath(a.Name(), root, path, logicalPath, id, cwd)
		if err != nil {
			env.Warn("claude: skipping session %s after stat failed: %v", path, err)
			return nil
		}
		sessions = append(sessions, session)
		return nil
	}); err != nil {
		return nil, err
	}
	return sessions, nil
}

func (Claude) RestorePath(env Environ, s SessionRef) (string, error) {
	root, err := claudeRoot(env)
	if err != nil {
		return "", err
	}
	return cleanRestorePath(root, s.RelPath)
}

func (Claude) ResumeHint(s SessionRef) string {
	// CWD can be a lossy munged-directory fallback; only emit a cd for a real
	// absolute path.
	if !filepath.IsAbs(strings.TrimSpace(s.CWD)) {
		return "claude --resume " + s.AgentSessionID
	}
	return "cd " + shellQuote(s.CWD) + " && claude --resume " + s.AgentSessionID
}
