package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// ImageService 圖片服務
type ImageService struct {
	config     *Config
	images     []ImageInfo
	mutex      sync.RWMutex
	lastScan   time.Time
}

// NewImageService 建立新的圖片服務
func NewImageService(config *Config) *ImageService {
	service := &ImageService{
		config: config,
		images: make([]ImageInfo, 0),
	}
	
	// 初始掃描
	service.RefreshImages()
	
	return service
}

// RefreshImages 重新掃描圖片目錄
func (s *ImageService) RefreshImages() error {
	s.mutex.Lock()
	defer s.mutex.Unlock()

	log.Printf("開始掃描圖片目錄: %s", s.config.BaseDir)
	
	var newImages []ImageInfo
	
	err := filepath.Walk(s.config.BaseDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			log.Printf("掃描檔案時發生錯誤 %s: %v", path, err)
			return nil // 繼續掃描其他檔案
		}
		
		// 跳過目錄
		if info.IsDir() {
			return nil
		}
		
		// 檢查是否為圖片檔案
		if !isImageFile(info.Name()) {
			return nil
		}
		
		// 計算相對路徑
		relPath, err := filepath.Rel(s.config.BaseDir, path)
		if err != nil {
			log.Printf("無法計算相對路徑 %s: %v", path, err)
			return nil
		}
		
		// 解析時間戳
		timestamp := parseFrameTimestamp(info.Name())
		
		imageInfo := ImageInfo{
			Path:      path,
			RelPath:   relPath,
			Timestamp: timestamp,
			ModTime:   info.ModTime(),
		}
		
		newImages = append(newImages, imageInfo)
		return nil
	})
	
	if err != nil {
		log.Printf("掃描目錄時發生錯誤: %v", err)
		return err
	}
	
	// 按檔案名排序
	sort.Slice(newImages, func(i, j int) bool {
		return newImages[i].RelPath < newImages[j].RelPath
	})
	
	s.images = newImages
	s.lastScan = time.Now()
	
	log.Printf("掃描完成，找到 %d 個圖片檔案", len(newImages))
	return nil
}

// GetImages 取得所有圖片列表
func (s *ImageService) GetImages() []ImageInfo {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	
	// 返回副本以避免併發問題
	images := make([]ImageInfo, len(s.images))
	copy(images, s.images)
	return images
}

// GetImageCount 取得圖片數量
func (s *ImageService) GetImageCount() int {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return len(s.images)
}

// GetLastScanTime 取得最後掃描時間
func (s *ImageService) GetLastScanTime() time.Time {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.lastScan
}

// GroupImagesBySegments 將圖片按轉錄段落分組
// 完全按照原版 Python 的 group_images_by_segments 邏輯實現
func (s *ImageService) GroupImagesBySegments(segments []Segment) map[string][]ImageInfo {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	
	// 初始化每個段落的分組
	grouped := make(map[string][]ImageInfo)
	for i := range segments {
		segmentKey := fmt.Sprintf("segment_%d", i)
		grouped[segmentKey] = []ImageInfo{}
	}
	
	// 邊界情況：沒有段落定義時，所有圖片歸入 segment_0
	if len(segments) == 0 {
		grouped["segment_0"] = append([]ImageInfo{}, s.images...)
		return grouped
	}
	
	lastSegKey := fmt.Sprintf("segment_%d", len(segments)-1)
	
	for _, img := range s.images {
		// 解析圖片檔名中的時間戳
		frameTime := parseFrameTimestamp(filepath.Base(img.RelPath))
		if frameTime == nil {
			// 檔名中沒有時間戳，歸入最後一個段落
			grouped[lastSegKey] = append(grouped[lastSegKey], img)
			continue
		}
		
		// 找出這個幀屬於哪個段落
		assigned := false
		for i, segment := range segments {
			if *frameTime >= segment.Start && *frameTime <= segment.End {
				segmentKey := fmt.Sprintf("segment_%d", i)
				grouped[segmentKey] = append(grouped[segmentKey], img)
				assigned = true
				break
			}
		}
		
		// 超出最後段落結束時間的幀也歸入最後段落
		if !assigned {
			grouped[lastSegKey] = append(grouped[lastSegKey], img)
		}
	}
	
	return grouped
}

// FindImageByPath 根據相對路徑查找圖片
func (s *ImageService) FindImageByPath(relPath string) *ImageInfo {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	
	for _, image := range s.images {
		if image.RelPath == relPath {
			return &image
		}
	}
	return nil
}

// StartBackgroundRefresh 啟動背景重新整理任務
func (s *ImageService) StartBackgroundRefresh() {
	go func() {
		ticker := time.NewTicker(time.Duration(s.config.RefreshSecs) * time.Second)
		defer ticker.Stop()
		
		log.Printf("啟動背景圖片掃描任務，間隔: %d 秒", s.config.RefreshSecs)
		
		for range ticker.C {
			if err := s.RefreshImages(); err != nil {
				log.Printf("背景掃描失敗: %v", err)
			}
		}
	}()
}
