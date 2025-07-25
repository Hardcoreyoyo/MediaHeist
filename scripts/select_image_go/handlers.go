package main

import (
	"log"
	"net/http"
	"sync"

	"github.com/gin-gonic/gin"
)

// AppHandlers 應用程式處理器
type AppHandlers struct {
	config            *Config
	imageService      *ImageService
	transcriptService *TranscriptService
	exportService     *ExportService
	selections        map[string]bool
	selectionsMutex   sync.RWMutex
}

// NewAppHandlers 建立新的應用程式處理器
func NewAppHandlers(config *Config, imageService *ImageService, transcriptService *TranscriptService, exportService *ExportService) *AppHandlers {
	return &AppHandlers{
		config:            config,
		imageService:      imageService,
		transcriptService: transcriptService,
		exportService:     exportService,
		selections:        make(map[string]bool),
	}
}

// IndexHandler 主頁處理器
// 完全按照原版 Python create_app.index 的邏輯實現
func (h *AppHandlers) IndexHandler(c *gin.Context) {
	// 獲取圖片和段落資料
	images := h.imageService.GetImages()
	segments := h.transcriptService.GetSegments()
	
	// 在伺服器端進行圖片分組（如果有轉錄）
	var groupedImages map[string][]string
	if len(segments) > 0 {
		// 使用 ImageService 的分組功能
		groupedImagesInfo := h.imageService.GroupImagesBySegments(segments)
		
		// 轉換為字符串格式以便模板使用
		groupedImages = make(map[string][]string)
		for key, imageInfos := range groupedImagesInfo {
			var imagePaths []string
			for _, imgInfo := range imageInfos {
				imagePaths = append(imagePaths, imgInfo.RelPath)
			}
			groupedImages[key] = imagePaths
		}
	} else {
		// 沒有轉錄時，所有圖片都是 ungrouped
		groupedImages = make(map[string][]string)
		var allImagePaths []string
		for _, img := range images {
			allImagePaths = append(allImagePaths, img.RelPath)
		}
		groupedImages["ungrouped"] = allImagePaths
	}
	
	// 所有圖片列表（用於備用）
	allImages := []string{}
	for _, img := range images {
		allImages = append(allImages, img.RelPath)
	}
	
	// 傳遞給模板的資料（完全按照原版 Python 的格式）
	c.HTML(http.StatusOK, "gallery.html", gin.H{
		"images":         allImages,
		"grouped_images": groupedImages,
		"segments":       segments,
	})
}

// SelectHandler 選擇圖片處理器
func (h *AppHandlers) SelectHandler(c *gin.Context) {
	var payload SelectionPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{
			Error:  "無效的請求格式",
			Detail: err.Error(),
		})
		return
	}
	
	// 驗證檔案名稱
	if payload.Filename == "" {
		c.JSON(http.StatusBadRequest, ErrorResponse{
			Error: "檔案名稱不能為空",
		})
		return
	}
	
	// 驗證路徑安全性
	if err := validatePath(h.config.BaseDir, payload.Filename); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{
			Error:  "無效的檔案路徑",
			Detail: err.Error(),
		})
		return
	}
	
	// 檢查圖片是否存在
	image := h.imageService.FindImageByPath(payload.Filename)
	if image == nil {
		c.JSON(http.StatusNotFound, ErrorResponse{
			Error: "圖片檔案不存在",
		})
		return
	}
	
	h.selectionsMutex.Lock()
	defer h.selectionsMutex.Unlock()
	
	// 切換選擇狀態
	if h.selections[payload.Filename] {
		delete(h.selections, payload.Filename)
		log.Printf("取消選擇圖片: %s", payload.Filename)
	} else {
		h.selections[payload.Filename] = true
		log.Printf("選擇圖片: %s", payload.Filename)
	}
	
	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"selected": h.selections[payload.Filename],
		"filename": payload.Filename,
	})
}

// SegmentsHandler 段落資料處理器
func (h *AppHandlers) SegmentsHandler(c *gin.Context) {
	segments := h.transcriptService.GetSegments()
	c.JSON(http.StatusOK, segments)
}

// ImagesHandler 圖片列表處理器
func (h *AppHandlers) ImagesHandler(c *gin.Context) {
	images := h.imageService.GetImages()
	c.JSON(http.StatusOK, images)
}

// ExportHandler 匯出處理器
func (h *AppHandlers) ExportHandler(c *gin.Context) {
	var payload ExportPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, ErrorResponse{
			Error:  "無效的請求格式",
			Detail: err.Error(),
		})
		return
	}
	
	// 匯出功能
	result, err := h.exportService.ExportMarkdown(payload.Selections)
	if err != nil {
		log.Printf("匯出失敗: %v", err)
		c.JSON(http.StatusInternalServerError, ErrorResponse{
			Error:  "匯出失敗",
			Detail: err.Error(),
		})
		return
	}
	
	c.JSON(http.StatusOK, result)
}

// GetSelectionsHandler 獲取選擇狀態處理器
func (h *AppHandlers) GetSelectionsHandler(c *gin.Context) {
	h.selectionsMutex.RLock()
	selections := make(map[string]bool)
	for k, v := range h.selections {
		selections[k] = v
	}
	h.selectionsMutex.RUnlock()
	
	c.JSON(http.StatusOK, gin.H{
		"selections": selections,
		"count":      len(selections),
	})
}
