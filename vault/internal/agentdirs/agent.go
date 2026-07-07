package agentdirs

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const uuidPattern = `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`

var uuidRE = regexp.MustCompile(`(?i)^` + uuidPattern + `$`)

type Environ struct {
	HomeDir  string
	Vars     map[string]string
	Warnings *[]string
}

func RealEnviron() (Environ, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Environ{}, err
	}
	vars := make(map[string]string)
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			vars[key] = value
		}
	}
	return Environ{HomeDir: home, Vars: vars}, nil
}

func (e Environ) Get(key string) string {
	return strings.TrimSpace(e.Vars[key])
}

func (e Environ) Warn(format string, args ...any) {
	if e.Warnings == nil {
		return
	}
	*e.Warnings = append(*e.Warnings, fmt.Sprintf(format, args...))
}

type Agent interface {
	Name() string
	Discover(env Environ) ([]Session, error)
	RestorePath(env Environ, s SessionRef) (string, error)
	ResumeHint(s SessionRef) string
}

type Session struct {
	AgentName      string    `json:"agent"`
	AgentSessionID string    `json:"agentSessionId"`
	AbsPath        string    `json:"path"`
	RelPath        string    `json:"relPath"`
	CWD            string    `json:"cwd,omitempty"`
	SizeBytes      int64     `json:"sizeBytes"`
	ModTime        time.Time `json:"modTime"`
}

type SessionRef struct {
	AgentName      string `json:"agent"`
	AgentSessionID string `json:"agentSessionId"`
	RelPath        string `json:"relPath"`
	CWD            string `json:"cwd,omitempty"`
}

func All() []Agent {
	return []Agent{Claude{}, Codex{}, Pi{}}
}

func ByName(name string) (Agent, bool) {
	normalized := strings.ToLower(strings.TrimSpace(name))
	for _, agent := range All() {
		if agent.Name() == normalized {
			return agent, true
		}
	}
	return nil, false
}

func DiscoverAll(env Environ, agentFilter string) ([]Session, error) {
	var agents []Agent
	if strings.TrimSpace(agentFilter) != "" {
		agent, ok := ByName(agentFilter)
		if !ok {
			return nil, fmt.Errorf("unknown agent %q", agentFilter)
		}
		agents = []Agent{agent}
	} else {
		agents = All()
	}

	var sessions []Session
	for _, agent := range agents {
		found, err := agent.Discover(env)
		if err != nil {
			return nil, err
		}
		sessions = append(sessions, found...)
	}
	sort.Slice(sessions, func(i, j int) bool {
		if sessions[i].AgentName != sessions[j].AgentName {
			return sessions[i].AgentName < sessions[j].AgentName
		}
		return sessions[i].RelPath < sessions[j].RelPath
	})
	return sessions, nil
}

func pathUnderHome(env Environ, parts ...string) (string, error) {
	if strings.TrimSpace(env.HomeDir) == "" {
		return "", errors.New("home directory is empty")
	}
	all := append([]string{env.HomeDir}, parts...)
	return filepath.Join(all...), nil
}

func relPath(root, path string) (string, error) {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return "", err
	}
	if rel == "." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || rel == ".." {
		return "", fmt.Errorf("%s is not under %s", path, root)
	}
	return filepath.ToSlash(rel), nil
}

func cleanRestorePath(root, rel string) (string, error) {
	rel = filepath.FromSlash(strings.TrimSpace(rel))
	if rel == "" || filepath.IsAbs(rel) {
		return "", fmt.Errorf("invalid relative path %q", rel)
	}
	cleaned := filepath.Clean(rel)
	if cleaned == "." || strings.HasPrefix(cleaned, ".."+string(filepath.Separator)) || cleaned == ".." {
		return "", fmt.Errorf("invalid relative path %q", rel)
	}
	return filepath.Join(root, cleaned), nil
}

func resolveWalkRoot(env Environ, agentName, path string) string {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return path
		}
		env.Warn("%s: using literal walk root %s after symlink resolution failed: %v", agentName, path, err)
		return path
	}
	return resolved
}

func logicalWalkPath(literalRoot, resolvedRoot, path string) string {
	rel, err := filepath.Rel(resolvedRoot, path)
	if err != nil {
		return path
	}
	return filepath.Join(literalRoot, rel)
}

func statSession(agentName, root, path, id, cwd string) (Session, error) {
	return statSessionWithLogicalPath(agentName, root, path, path, id, cwd)
}

func statSessionWithLogicalPath(agentName, root, path, logicalPath, id, cwd string) (Session, error) {
	info, err := os.Stat(path)
	if err != nil {
		return Session{}, err
	}
	rel, err := relPath(root, logicalPath)
	if err != nil {
		return Session{}, err
	}
	return Session{
		AgentName:      agentName,
		AgentSessionID: id,
		AbsPath:        path,
		RelPath:        rel,
		CWD:            cwd,
		SizeBytes:      info.Size(),
		ModTime:        info.ModTime(),
	}, nil
}

func recoverCWDFromJSONL(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	lines := 0
	for scanner.Scan() {
		lines++
		if cwd := cwdFromJSON(scanner.Bytes()); cwd != "" {
			return cwd
		}
		if lines >= 128 {
			break
		}
	}
	return ""
}

func cwdFromJSON(data []byte) string {
	var value any
	if err := json.Unmarshal(data, &value); err != nil {
		return ""
	}
	return findStringKey(value, "cwd")
}

func findStringKey(value any, key string) string {
	switch typed := value.(type) {
	case map[string]any:
		if v, ok := typed[key].(string); ok && strings.TrimSpace(v) != "" {
			return v
		}
		for _, child := range typed {
			if found := findStringKey(child, key); found != "" {
				return found
			}
		}
	case []any:
		for _, child := range typed {
			if found := findStringKey(child, key); found != "" {
				return found
			}
		}
	}
	return ""
}

func cwdFromMunged(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	return name
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
