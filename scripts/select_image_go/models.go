package main

import (
	"time"
)

// Config 配置結構
type Config struct {
	BaseDir       string `json:"base_dir"`
	RefreshSecs   int    `json:"refresh_secs"`
	Port          int    `json:"port"`
	TranscriptPath string `json:"transcript_path,omitempty"`
	OutputDir     string `json:"output_dir"`
}

// SelectionPayload 選擇圖片的請求結構
type SelectionPayload struct {
	Filename string `json:"filename" binding:"required"`
}

// ExportPayload 匯出請求結構
type ExportPayload struct {
	Selections map[string][]string `json:"selections" binding:"required"`
}

// Segment 轉錄段落結構
type Segment struct {
	Start     float64 `json:"start"`
	End       float64 `json:"end"`
	StartStr  string  `json:"start_str,omitempty"`
	EndStr    string  `json:"end_str,omitempty"`
	Text      string  `json:"text"`
	CleanText string  `json:"clean_text,omitempty"` // 用於左側預覽的清理後文字
}

// ImageInfo 圖片資訊結構
type ImageInfo struct {
	Path      string    `json:"path"`
	RelPath   string    `json:"rel_path"`
	Timestamp *float64  `json:"timestamp,omitempty"`
	ModTime   time.Time `json:"mod_time"`
}

// AppState 應用程式狀態
type AppState struct {
	Images     []ImageInfo       `json:"images"`
	Segments   []Segment         `json:"segments"`
	Selections map[string]bool   `json:"selections"`
	LastScan   time.Time         `json:"last_scan"`
}

// ExportResult 匯出結果
type ExportResult struct {
	Success   bool   `json:"success"`
	Filename  string `json:"filename,omitempty"`
	Message   string `json:"message,omitempty"`
	Error     string `json:"error,omitempty"`
}

// ErrorResponse 錯誤回應結構
type ErrorResponse struct {
	Error  string `json:"error"`
	Detail string `json:"detail,omitempty"`
}
