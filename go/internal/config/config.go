package config

import (
	"fmt"
	"os"

	yaml "go.yaml.in/yaml/v3"
)

const DefaultMaxLogLines = 1000

type ProcessConfig struct {
	Name    string   `yaml:"name"`
	Command []string `yaml:"command"`
	Dir     string   `yaml:"dir"`
	LogFile string   `yaml:"log_file,omitempty"`
	JsonLog bool     `yaml:"json_log,omitempty"`
	Watch   bool     `yaml:"watch,omitempty"`
}

type Configuration struct {
	Processes   []ProcessConfig `yaml:"processes"`
	MaxLogLines int             `yaml:"max_log_lines,omitempty"`
}

func Read(path string) (*Configuration, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	cfg := &Configuration{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if cfg.MaxLogLines <= 0 {
		cfg.MaxLogLines = DefaultMaxLogLines
	}
	return cfg, nil
}
