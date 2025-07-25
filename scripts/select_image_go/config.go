package main

import (
	"flag"
	"fmt"
	"path/filepath"
)

// ParseArgs 解析命令列參數
func ParseArgs() (*Config, error) {
	var (
		baseDir       = flag.String("base-dir", "", "Directory containing images (required)")
		refreshSecs   = flag.Int("refresh-secs", 15, "Directory rescan interval in seconds")
		port          = flag.Int("port", 15687, "HTTP port to listen on")
		transcriptPath = flag.String("transcript", "", "Transcript text file (optional)")
		outputDir     = flag.String("output-dir", "./output", "Directory to save exported markdown files")
		help          = flag.Bool("help", false, "Show help message")
	)

	flag.Parse()

	if *help {
		fmt.Println("Image Selection Server - Golang版本")
		fmt.Println()
		fmt.Println("用法:")
		flag.PrintDefaults()
		fmt.Println()
		fmt.Println("範例:")
		fmt.Println("  ./select_image_go \\")
		fmt.Println("    --base-dir /path/to/images \\")
		fmt.Println("    --transcript /path/to/transcript.txt \\")
		fmt.Println("    --output-dir /path/to/output \\")
		fmt.Println("    --port 15687 \\")
		fmt.Println("    --refresh-secs 15")
		return nil, fmt.Errorf("help requested")
	}

	if *baseDir == "" {
		return nil, fmt.Errorf("--base-dir is required")
	}

	// 驗證並標準化路徑
	absBaseDir, err := filepath.Abs(*baseDir)
	if err != nil {
		return nil, fmt.Errorf("invalid base-dir path: %v", err)
	}

	absOutputDir, err := filepath.Abs(*outputDir)
	if err != nil {
		return nil, fmt.Errorf("invalid output-dir path: %v", err)
	}

	var absTranscriptPath string
	if *transcriptPath != "" {
		absTranscriptPath, err = filepath.Abs(*transcriptPath)
		if err != nil {
			return nil, fmt.Errorf("invalid transcript path: %v", err)
		}
	}

	// 驗證參數範圍
	if *refreshSecs < 5 {
		return nil, fmt.Errorf("refresh-secs must be at least 5 seconds")
	}

	if *port < 1 || *port > 65535 {
		return nil, fmt.Errorf("port must be between 1 and 65535")
	}

	return &Config{
		BaseDir:       absBaseDir,
		RefreshSecs:   *refreshSecs,
		Port:          *port,
		TranscriptPath: absTranscriptPath,
		OutputDir:     absOutputDir,
	}, nil
}

// ValidateConfig 驗證配置
func ValidateConfig(config *Config) error {
	// 檢查基礎目錄是否存在
	if !dirExists(config.BaseDir) {
		return fmt.Errorf("base directory does not exist: %s", config.BaseDir)
	}

	// 檢查轉錄文件是否存在（如果提供）
	if config.TranscriptPath != "" && !fileExists(config.TranscriptPath) {
		return fmt.Errorf("transcript file does not exist: %s", config.TranscriptPath)
	}

	return nil
}
