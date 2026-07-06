package agentdirs

import (
	"io/fs"
	"path/filepath"
	"regexp"
	"strings"
)

type Pi struct{}

var piFileRE = regexp.MustCompile(`(?i)^.+_(` + uuidPattern + `)\.jsonl$`)

func (Pi) Name() string { return "pi" }

func piRoot(env Environ) (string, error) {
	return pathUnderHome(env, ".pi", "agent", "sessions")
}

func (a Pi) Discover(env Environ) ([]Session, error) {
	root, err := piRoot(env)
	if err != nil {
		return nil, err
	}
	walkRoot := resolveWalkRoot(env, a.Name(), root)
	var sessions []Session
	if err := filepath.WalkDir(walkRoot, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			if filepath.Clean(path) == filepath.Clean(walkRoot) {
				return nil
			}
			env.Warn("pi: skipping unreadable path %s: %v", path, walkErr)
			if entry != nil && entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		matches := piFileRE.FindStringSubmatch(entry.Name())
		if len(matches) != 2 {
			return nil
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			env.Warn("pi: skipping symlinked transcript %s", path)
			return nil
		}
		cwd := recoverCWDFromJSONL(path)
		if cwd == "" {
			cwd = cwdFromMunged(filepath.Base(filepath.Dir(path)))
		}
		logicalPath := logicalWalkPath(root, walkRoot, path)
		session, err := statSessionWithLogicalPath(a.Name(), root, path, logicalPath, strings.ToLower(matches[1]), cwd)
		if err != nil {
			env.Warn("pi: skipping session %s after stat failed: %v", path, err)
			return nil
		}
		sessions = append(sessions, session)
		return nil
	}); err != nil {
		return nil, err
	}
	return sessions, nil
}

func (Pi) RestorePath(env Environ, s SessionRef) (string, error) {
	root, err := piRoot(env)
	if err != nil {
		return "", err
	}
	return cleanRestorePath(root, s.RelPath)
}

func (Pi) ResumeHint(s SessionRef) string {
	// CWD can be a lossy munged-directory fallback; only emit a cd for a real
	// absolute path.
	if !filepath.IsAbs(strings.TrimSpace(s.CWD)) {
		return "open pi and resume session " + s.AgentSessionID
	}
	return "cd " + shellQuote(s.CWD) + " && open pi to resume session " + s.AgentSessionID
}
