package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ExportService 匯出服務
type ExportService struct {
	config            *Config
	imageService      *ImageService
	transcriptService *TranscriptService
}

// NewExportService 建立新的匯出服務
func NewExportService(config *Config, imageService *ImageService, transcriptService *TranscriptService) *ExportService {
	return &ExportService{
		config:            config,
		imageService:      imageService,
		transcriptService: transcriptService,
	}
}

// ExportMarkdown 匯出選擇的圖片和 Markdown
func (s *ExportService) ExportMarkdown(selections map[string][]string) (*ExportResult, error) {
	// 建立輸出目錄
	if err := ensureDir(s.config.OutputDir); err != nil {
		return nil, fmt.Errorf("無法建立輸出目錄: %v", err)
	}
	
	// 生成唯一的匯出目錄名稱
	timestamp := time.Now().Format("20060102_150405")
	exportDirName := fmt.Sprintf("export_%s", timestamp)
	exportDir := filepath.Join(s.config.OutputDir, exportDirName)
	
	if err := ensureDir(exportDir); err != nil {
		return nil, fmt.Errorf("無法建立匯出目錄: %v", err)
	}
	
	// 建立圖片目錄
	imagesDirName := "images"
	imagesDir := filepath.Join(exportDir, imagesDirName)
	if err := ensureDir(imagesDir); err != nil {
		return nil, fmt.Errorf("無法建立圖片目錄: %v", err)
	}
	
	// 收集所有唯一的圖片檔案
	uniqueImages := make(map[string]bool)
	for _, filenames := range selections {
		for _, filename := range filenames {
			uniqueImages[filename] = true
		}
	}
	
	// 複製圖片檔案
	copiedImages := make(map[string]string) // 原始路徑 -> 新路徑
	for filename := range uniqueImages {
		if err := s.copyImageFile(filename, imagesDir, copiedImages); err != nil {
			log.Printf("複製圖片檔案失敗 %s: %v", filename, err)
			continue
		}
	}
	
	// 生成 Markdown 內容
	markdownContent, err := s.generateMarkdown(selections, copiedImages, imagesDirName)
	if err != nil {
		return nil, fmt.Errorf("生成 Markdown 失敗: %v", err)
	}
	
	// 寫入 Markdown 檔案
	markdownFilename := fmt.Sprintf("transcript_%s.md", timestamp)
	markdownPath := filepath.Join(exportDir, markdownFilename)
	
	if err := s.writeMarkdownFile(markdownPath, markdownContent); err != nil {
		return nil, fmt.Errorf("寫入 Markdown 檔案失敗: %v", err)
	}
	
	log.Printf("匯出完成: %s", exportDir)
	
	return &ExportResult{
		Success:  true,
		Filename: markdownFilename,
		Message:  fmt.Sprintf("成功匯出到: %s", exportDir),
	}, nil
}

// copyImageFile 複製圖片檔案到匯出目錄
func (s *ExportService) copyImageFile(relPath string, targetDir string, copiedImages map[string]string) error {
	// 驗證路徑安全性
	if err := validatePath(s.config.BaseDir, relPath); err != nil {
		return fmt.Errorf("路徑驗證失敗: %v", err)
	}
	
	sourcePath := filepath.Join(s.config.BaseDir, relPath)
	
	// 檢查來源檔案是否存在
	if !fileExists(sourcePath) {
		return fmt.Errorf("來源檔案不存在: %s", sourcePath)
	}
	
	// 建立目標路徑，保持目錄結構
	targetPath := filepath.Join(targetDir, relPath)
	targetDirPath := filepath.Dir(targetPath)
	
	if err := ensureDir(targetDirPath); err != nil {
		return fmt.Errorf("無法建立目標目錄: %v", err)
	}
	
	// 複製檔案
	if err := s.copyFile(sourcePath, targetPath); err != nil {
		return fmt.Errorf("複製檔案失敗: %v", err)
	}
	
	// 記錄複製的檔案映射
	copiedImages[relPath] = relPath
	
	return nil
}

// copyFile 複製檔案
func (s *ExportService) copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()
	
	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()
	
	_, err = io.Copy(destFile, sourceFile)
	if err != nil {
		return err
	}
	
	// 同步檔案系統
	return destFile.Sync()
}

// generateMarkdown 生成 Markdown 內容
func (s *ExportService) generateMarkdown(selections map[string][]string, copiedImages map[string]string, imagesDirName string) (string, error) {
	var content strings.Builder
	
	segments := s.transcriptService.GetSegments()
	
	for i, segment := range segments {
		segmentID := fmt.Sprintf("segment_%d", i)
		
		// 寫入段落文字
		content.WriteString(segment.Text)
		content.WriteString("\n\n")
		
		// 檢查是否有選擇的圖片
		if selectedImages, exists := selections[segmentID]; exists && len(selectedImages) > 0 {
			for _, imagePath := range selectedImages {
				if _, copied := copiedImages[imagePath]; copied {
					// 生成 Markdown 圖片連結
					imageMarkdownPath := filepath.Join(imagesDirName, imagePath)
					// 在 Windows 上將反斜線轉換為正斜線
					imageMarkdownPath = strings.ReplaceAll(imageMarkdownPath, "\\", "/")
					content.WriteString(fmt.Sprintf("![%s](%s)\n\n", imagePath, imageMarkdownPath))
				}
			}
		}
	}
	
	return content.String(), nil
}

// writeMarkdownFile 寫入 Markdown 檔案
func (s *ExportService) writeMarkdownFile(path string, content string) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	
	_, err = file.WriteString(content)
	if err != nil {
		return err
	}
	
	return file.Sync()
}
