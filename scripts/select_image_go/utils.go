package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// fileExists 檢查檔案是否存在
func fileExists(path string) bool {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}

// dirExists 檢查目錄是否存在
func dirExists(path string) bool {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return false
	}
	return info.IsDir()
}

// isImageFile 檢查是否為支援的圖片格式
func isImageFile(filename string) bool {
	ext := strings.ToLower(filepath.Ext(filename))
	allowedExts := map[string]bool{
		".jpg":  true,
		".jpeg": true,
		".png":  true,
		".gif":  true,
	}
	return allowedExts[ext]
}

// parseFrameTimestamp 解析幀檔名中的時間戳
// 格式: frame_xx_xx_xx_xxx (小時_分鐘_秒_毫秒)
func parseFrameTimestamp(filename string) *float64 {
	// 正規表達式匹配 frame_xx_xx_xx_xxx 格式
	pattern := regexp.MustCompile(`frame_(\d{2})_(\d{2})_(\d{2})_(\d{3})`)
	matches := pattern.FindStringSubmatch(filename)
	
	if len(matches) != 5 {
		return nil
	}

	hours, err1 := strconv.Atoi(matches[1])
	minutes, err2 := strconv.Atoi(matches[2])
	seconds, err3 := strconv.Atoi(matches[3])
	milliseconds, err4 := strconv.Atoi(matches[4])

	if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
		return nil
	}

	totalSeconds := float64(hours*3600 + minutes*60 + seconds) + float64(milliseconds)/1000.0
	return &totalSeconds
}

// parseTranscriptTimestamp 解析轉錄時間戳
// 格式: hh:mm:ss,mmm 或 hh:mm:ss.mmm
func parseTranscriptTimestamp(timestampStr string) (float64, error) {
	// 處理逗號和點號作為毫秒分隔符
	timestampStr = strings.Replace(timestampStr, ",", ".", 1)
	
	parts := strings.Split(timestampStr, ":")
	if len(parts) != 3 {
		return 0, fmt.Errorf("invalid timestamp format: %s", timestampStr)
	}

	hours, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, fmt.Errorf("invalid hours in timestamp: %s", parts[0])
	}

	minutes, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, fmt.Errorf("invalid minutes in timestamp: %s", parts[1])
	}

	// 處理秒和毫秒
	secondsParts := strings.Split(parts[2], ".")
	seconds, err := strconv.Atoi(secondsParts[0])
	if err != nil {
		return 0, fmt.Errorf("invalid seconds in timestamp: %s", secondsParts[0])
	}

	var milliseconds int
	if len(secondsParts) > 1 {
		// 確保毫秒部分是3位數
		msStr := secondsParts[1]
		if len(msStr) > 3 {
			msStr = msStr[:3]
		} else {
			for len(msStr) < 3 {
				msStr += "0"
			}
		}
		milliseconds, err = strconv.Atoi(msStr)
		if err != nil {
			return 0, fmt.Errorf("invalid milliseconds in timestamp: %s", secondsParts[1])
		}
	}

	totalSeconds := float64(hours*3600 + minutes*60 + seconds) + float64(milliseconds)/1000.0
	return totalSeconds, nil
}

// validatePath 驗證路徑安全性，防止路徑遍歷攻擊
func validatePath(basePath, requestPath string) error {
	cleanPath := filepath.Clean(requestPath)
	if strings.Contains(cleanPath, "..") {
		return fmt.Errorf("invalid path: contains '..'")
	}
	
	// 確保路徑在基礎目錄內
	absPath := filepath.Join(basePath, cleanPath)
	absBasePath, err := filepath.Abs(basePath)
	if err != nil {
		return fmt.Errorf("failed to resolve base path: %v", err)
	}
	
	absRequestPath, err := filepath.Abs(absPath)
	if err != nil {
		return fmt.Errorf("failed to resolve request path: %v", err)
	}
	
	if !strings.HasPrefix(absRequestPath, absBasePath) {
		return fmt.Errorf("path outside base directory")
	}
	
	return nil
}

// ensureDir 確保目錄存在，如果不存在則建立
func ensureDir(dirPath string) error {
	if !dirExists(dirPath) {
		return os.MkdirAll(dirPath, 0755)
	}
	return nil
}
