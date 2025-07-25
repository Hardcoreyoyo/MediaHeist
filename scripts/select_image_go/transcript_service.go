package main

import (
	"io"
	"log"
	"os"
	"regexp"
	"strings"
	"sync"
)

// TranscriptService 轉錄服務
type TranscriptService struct {
	config   *Config
	segments []Segment
	mutex    sync.RWMutex
}

// NewTranscriptService 建立新的轉錄服務
func NewTranscriptService(config *Config) *TranscriptService {
	service := &TranscriptService{
		config:   config,
		segments: make([]Segment, 0),
	}
	
	if config.TranscriptPath != "" {
		if err := service.LoadTranscript(); err != nil {
			log.Printf("載入轉錄檔案失敗: %v", err)
		}
	}
	
	return service
}

// LoadTranscript 載入並解析轉錄檔案
func (s *TranscriptService) LoadTranscript() error {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	
	if s.config.TranscriptPath == "" {
		return nil
	}
	
	log.Printf("載入轉錄檔案: %s", s.config.TranscriptPath)
	
	file, err := os.Open(s.config.TranscriptPath)
	if err != nil {
		return err
	}
	defer file.Close()
	
	segments, err := s.parseTranscript(file)
	if err != nil {
		return err
	}
	
	s.segments = segments
	log.Printf("載入轉錄檔案完成，共 %d 個段落", len(segments))
	
	return nil
}

// parseTranscript 解析轉錄檔案
// 完全按照原始 Python 版本的邏輯實現
func (s *TranscriptService) parseTranscript(file *os.File) ([]Segment, error) {
	// 讀取整個檔案內容
	content, err := io.ReadAll(file)
	if err != nil {
		return nil, err
	}
	contentStr := string(content)
	
	// 正規表達式匹配 ### Timestamp: **hh:mm:ss,mmm** ~ **hh:mm:ss,mmm**
	headingPattern := regexp.MustCompile(`(?m)^###\s*Timestamp:\s*\*\*(\d{2}:\d{2}:\d{2}[,.]\d{3})\*\*\s*~\s*\*\*(\d{2}:\d{2}:\d{2}[,.]\d{3})\*\*.*?$`)
	
	matches := headingPattern.FindAllStringSubmatchIndex(contentStr, -1)
	
	// 如果沒有找到任何時間戳，整篇視為單一段落
	if len(matches) == 0 {
		return []Segment{{
			Start:     0.0,
			End:       0.0,
			StartStr:  "",
			EndStr:    "",
			Text:      strings.TrimSpace(contentStr),
		}}, nil
	}
	
	var segments []Segment
	
	for i, match := range matches {
		// 提取時間戳字符串
		startTimeStr := contentStr[match[2]:match[3]]
		endTimeStr := contentStr[match[4]:match[5]]
		
		// 解析時間戳為數字（用於排序和比較）
		startTime, err := parseTranscriptTimestamp(startTimeStr)
		if err != nil {
			log.Printf("解析開始時間失敗: %v", err)
			continue
		}
		
		endTime, err := parseTranscriptTimestamp(endTimeStr)
		if err != nil {
			log.Printf("解析結束時間失敗: %v", err)
			continue
		}
		
		// 計算內容範圍（關鍵：排除 Timestamp 標題行）
		var contentStart, contentEnd int
		
		if i == 0 {
			// 第一個段落：保留文件前言 + Timestamp 標題行
            contentStart = 0 // 檔案起始
            // 內容結束位置：到下一個 Timestamp 行開始之前，或文件結尾
            if i+1 < len(matches) {
                contentEnd = matches[i+1][0]
            } else {
                contentEnd = len(contentStr)
            }
            // 擷取段落內容（不包含 Timestamp 行且排除前言）
            segmentContent := strings.TrimSpace(contentStr[contentStart:contentEnd])
            // 針對預覽文字進行清理
            cleanText := cleanTextForPreview(segmentContent)
			segments = append(segments, Segment{
				Start:     startTime,
				End:       endTime,
				StartStr:  startTimeStr,
				EndStr:    endTimeStr,
				Text:      segmentContent,
				CleanText: cleanText,
			})
		} else {
			// 後續段落：保留 Timestamp 標題行
            contentStart = match[0]
			
			// 內容結束位置：到下一個 Timestamp 行開始之前，或文件結尾
			if i+1 < len(matches) {
				contentEnd = matches[i+1][0]
			} else {
				contentEnd = len(contentStr)
			}
			
			// 擷取段落內容（不包含 Timestamp 行）
			segmentContent := strings.TrimSpace(contentStr[contentStart:contentEnd])
			
			cleanText := cleanTextForPreview(segmentContent)
			segments = append(segments, Segment{
				Start:     startTime,
				End:       endTime,
				StartStr:  startTimeStr,
				EndStr:    endTimeStr,
				Text:      segmentContent,
				CleanText: cleanText,
			})
		}
	}
	
	return segments, nil
}

// cleanTextForPreview 清理文本用於左側預覽，移除 Timestamp 行和多餘空白
func cleanTextForPreview(text string) string {
    lines := strings.Split(text, "\n")
    var cleanLines []string

    started := false // 是否已進入真正段落（過了 Timestamp 標題）

    for _, line := range lines {
        line = strings.TrimSpace(line)

        // 決定何時開始收集文字：遇到第一個 Timestamp 標題後
        if strings.HasPrefix(line, "### Timestamp:") {
            started = true
            continue // 不要顯示 Timestamp 行本身
        }

        // 尚未開始，代表屬於前言/Summary，直接忽略
        if !started {
            continue
        }

        // 跳過空行、分隔線與其他標題
        if line == "" || line == "---" || strings.HasPrefix(line, "#") {
            continue
        }

        cleanLines = append(cleanLines, line)
    }

    return strings.TrimSpace(strings.Join(cleanLines, " "))
}

// GetSegments 取得所有段落
func (s *TranscriptService) GetSegments() []Segment {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	
	// 返回副本以避免併發問題
	segments := make([]Segment, len(s.segments))
	copy(segments, s.segments)
	return segments
}

// GetSegmentCount 取得段落數量
func (s *TranscriptService) GetSegmentCount() int {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return len(s.segments)
}

// HasTranscript 檢查是否有轉錄檔案
func (s *TranscriptService) HasTranscript() bool {
	return s.config.TranscriptPath != ""
}
