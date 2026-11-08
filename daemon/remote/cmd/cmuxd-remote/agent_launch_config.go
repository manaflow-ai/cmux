package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

func writeOmoShadowConfig(userDir, shadowDir string) error {
	omoConfigPath := filepath.Join(shadowDir, "oh-my-opencode.json")
	var omoConfig map[string]any
	if data, err := os.ReadFile(omoConfigPath); err == nil {
		json.Unmarshal(data, &omoConfig)
	}
	if omoConfig == nil {
		userOmoConfig := filepath.Join(userDir, "oh-my-opencode.json")
		if data, err := os.ReadFile(userOmoConfig); err == nil {
			json.Unmarshal(data, &omoConfig)
		}
	}
	if omoConfig == nil {
		omoConfig = map[string]any{}
	}

	tmuxConfig, _ := omoConfig["tmux"].(map[string]any)
	if tmuxConfig == nil {
		tmuxConfig = map[string]any{}
	}
	if enabled, _ := tmuxConfig["enabled"].(bool); !enabled {
		tmuxConfig["enabled"] = true
	}
	if tmuxConfig["main_pane_min_width"] == nil {
		tmuxConfig["main_pane_min_width"] = 60
	}
	if tmuxConfig["agent_pane_min_width"] == nil {
		tmuxConfig["agent_pane_min_width"] = 30
	}
	if tmuxConfig["main_pane_size"] == nil {
		tmuxConfig["main_pane_size"] = 50
	}
	omoConfig["tmux"] = tmuxConfig
	data, err := json.MarshalIndent(omoConfig, "", "  ")
	if err != nil {
		return err
	}
	// Replace old copies and links even when settings are already configured,
	// before running an installer or exposing the shadow directory to the agent.
	return writePrivateAgentConfig(omoConfigPath, data)
}

// Install configuration containing provider credentials atomically with private
// permissions. Replacing the directory entry also avoids following old links.
func writePrivateAgentConfig(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".cmux-config-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
