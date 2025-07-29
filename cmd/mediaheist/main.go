package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

//go:embed assets/*
var embeddedFiles embed.FS

const (
	tempDirPrefix = "mediaheist-"
)

func main() {
	// 處理 --help 參數
	if len(os.Args) > 1 && (os.Args[1] == "--help" || os.Args[1] == "-h" || os.Args[1] == "help") {
		showHelp()
		return
	}

	// 取得當前工作目錄
	currentDir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：無法取得當前目錄: %v\n", err)
		os.Exit(1)
	}

	// 檢查是否已經解壓縮過（避免重複解壓縮）
	if !isAlreadyExtracted(currentDir) {
		fmt.Println("ℹ️ 正在解壓縮 MediaHeist 檔案到當前目錄...")
		// 解壓縮嵌入的檔案到當前目錄
		if err := extractEmbeddedFiles(currentDir); err != nil {
			fmt.Fprintf(os.Stderr, "錯誤：解壓縮檔案失敗: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("✓ 檔案解壓縮完成")
	} else {
		fmt.Println("✓ 檢測到已存在的 MediaHeist 檔案，跳過解壓縮")
	}

	// 檢查配置檔案
	checkConfigFiles(currentDir)

	// 準備 make 命令參數
	args := []string{"make"}
	if len(os.Args) > 1 {
		args = append(args, os.Args[1:]...)
	} else {
		// 如果沒有參數，顯示幫助資訊
		args = append(args, "help")
	}

	// 執行 make 命令（在當前目錄）
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	cmd.Dir = currentDir // 確保在當前目錄執行

	if err := cmd.Run(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			if status, ok := exitError.Sys().(syscall.WaitStatus); ok {
				os.Exit(status.ExitStatus())
			}
		}
		fmt.Fprintf(os.Stderr, "錯誤：執行 make 失敗: %v\n", err)
		os.Exit(1)
	}
}

// isAlreadyExtracted 檢查是否已經解壓縮過 MediaHeist 檔案
func isAlreadyExtracted(dir string) bool {
	// 檢查關鍵檔案是否存在
	makefilePath := filepath.Join(dir, "Makefile")
	scriptsPath := filepath.Join(dir, "scripts")

	// 檢查 Makefile 和 scripts 目錄是否都存在
	if _, err := os.Stat(makefilePath); os.IsNotExist(err) {
		return false
	}
	if _, err := os.Stat(scriptsPath); os.IsNotExist(err) {
		return false
	}

	return true
}

// checkConfigFiles 檢查配置檔案狀態並顯示資訊
func checkConfigFiles(dir string) {
	var foundFiles []string
	var missingFiles []string

	// 要檢查的配置檔案
	configFiles := map[string]string{
		".env":       "環境變數配置（必需）",
		"prompt.txt": "自定義提示詞（可選）",
	}

	for filename, description := range configFiles {
		filePath := filepath.Join(dir, filename)
		if _, err := os.Stat(filePath); err == nil {
			foundFiles = append(foundFiles, fmt.Sprintf("%s (%s)", filename, description))
		} else {
			missingFiles = append(missingFiles, fmt.Sprintf("%s (%s)", filename, description))
		}
	}

	// 顯示找到的配置檔案
	if len(foundFiles) > 0 {
		fmt.Printf("✓ 找到配置檔案: %s\n", strings.Join(foundFiles, ", "))
	}

	// 顯示缺少的配置檔案
	if len(missingFiles) > 0 {
		fmt.Printf("⚠️  缺少配置檔案: %s\n", strings.Join(missingFiles, ", "))

		// 如果缺少 .env，顯示警告
		if _, err := os.Stat(filepath.Join(dir, ".env")); os.IsNotExist(err) {
			fmt.Println("⚠️  警告: .env 檔案不存在，可能會導致執行失敗")
			fmt.Println("   請在當前目錄建立 .env 檔案並設定必要的環境變數")
		}
	}
}

// showHelp 顯示幫助資訊
func showHelp() {
	fmt.Print(`MediaHeist - 媒體處理工具包

使用方式:
  mediaheist <target> [參數...]

常用目標:
  download URL="<url>"              下載並處理單一媒體
  download LIST="<file>"            批次處理媒體列表
  all LIST="<file>" MAX_JOBS=<n>    平行處理所有步驟
  transcribe                        僅執行轉錄步驟
  frames                           僅執行影格擷取
  summary                          僅執行摘要生成
  clean                            清理暫存檔案
  help                             顯示 Makefile 說明

支援的輸入格式:
  - YouTube URLs: https://www.youtube.com/watch?v=VIDEO_ID
  - YouTube 短網址: https://youtu.be/VIDEO_ID
  - YouTube 影片 ID: VIDEO_ID (11 字元)
  - 本地檔案路徑: /absolute/path/to/video.mp4

配置檔案設定:
  請在執行 mediaheist 的目錄下放置以下檔案：
  
  .env - 環境變數配置（必需）:
    GEMINI_API_KEY=your_gemini_api_key
    GEMINI_MODEL_ID=gemini-1.5-flash
    WHISPER_BIN=/usr/local/bin/whisper
    WHISPER_MODEL=base
  
  prompt.txt - 自定義提示詞（可選）:
    用於自定義 AI 摘要生成的提示詞模板

執行方式:
  - 程式會自動將 Makefile 和 scripts 解壓縮到當前目錄
  - 所有產生的檔案（下載、轉錄、摘要等）都會在當前目錄
  - 配置檔案直接從當前目錄讀取，無需複製

除錯資訊:
  - 如果出現 "Missing required variables" 錯誤，請檢查:
    1. .env 檔案是否存在於當前目錄
    2. .env 檔案格式是否正確（KEY=VALUE，無空格）
    3. 所有必需變數是否都已設定
  - 執行時會顯示找到的配置檔案清單
  - 首次執行會解壓縮檔案，之後會自動跳過

範例:
  # 在任意目錄下建立 .env 檔案
  echo "GEMINI_API_KEY=your_key" > .env
  echo "GEMINI_MODEL_ID=gemini-1.5-flash" >> .env
  echo "WHISPER_BIN=/usr/local/bin/whisper" >> .env
  echo "WHISPER_MODEL=base" >> .env
  
  # 執行 MediaHeist
  mediaheist download URL="https://youtu.be/dQw4w9WgXcQ"
  mediaheist download URL="dQw4w9WgXcQ"
  mediaheist download LIST="urls.txt"
  mediaheist all LIST="batch.txt" MAX_JOBS=4
`)
}

// extractEmbeddedFiles 將嵌入的檔案解壓縮到指定目錄
func extractEmbeddedFiles(destDir string) error {
	return fs.WalkDir(embeddedFiles, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		// 跳過根目錄
		if path == "." {
			return nil
		}

		// 移除 "assets/" 前綴
		cleanPath := strings.TrimPrefix(path, "assets/")
		destPath := filepath.Join(destDir, cleanPath)

		if d.IsDir() {
			return os.MkdirAll(destPath, 0755)
		}

		// 讀取嵌入的檔案內容
		content, err := embeddedFiles.ReadFile(path)
		if err != nil {
			return fmt.Errorf("讀取嵌入檔案 %s 失敗: %w", path, err)
		}

		// 寫入到目標位置
		if err := os.WriteFile(destPath, content, 0644); err != nil {
			return fmt.Errorf("寫入檔案 %s 失敗: %w", destPath, err)
		}

		// 如果是 shell 腳本或特定檔案，設定執行權限
		if strings.HasSuffix(cleanPath, ".sh") || strings.Contains(cleanPath, "scripts/select_image") {
			if err := os.Chmod(destPath, 0755); err != nil {
				return fmt.Errorf("設定執行權限失敗 %s: %w", destPath, err)
			}
		}

		return nil
	})
}
