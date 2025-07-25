package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"

	"github.com/gin-gonic/gin"
)

//go:embed templates/*
var templatesFS embed.FS

func main() {
	// 解析命令列參數
	config, err := ParseArgs()
	if err != nil {
		if err.Error() != "help requested" {
			fmt.Fprintf(os.Stderr, "錯誤: %v\n", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	// 驗證配置
	if err := ValidateConfig(config); err != nil {
		fmt.Fprintf(os.Stderr, "配置錯誤: %v\n", err)
		os.Exit(1)
	}

	// 建立服務
	imageService := NewImageService(config)
	transcriptService := NewTranscriptService(config)
	exportService := NewExportService(config, imageService, transcriptService)

	// 啟動背景重新整理任務
	imageService.StartBackgroundRefresh()

	// 建立處理器
	handlers := NewAppHandlers(config, imageService, transcriptService, exportService)

	// 建立 Gin 路由器
	router := setupRouter(config, handlers)

	// 啟動伺服器
	addr := fmt.Sprintf("127.0.0.1:%d", config.Port)
	log.Printf("啟動圖片選擇伺服器")
	log.Printf("基礎目錄: %s", config.BaseDir)
	if config.TranscriptPath != "" {
		log.Printf("轉錄檔案: %s", config.TranscriptPath)
	}
	log.Printf("輸出目錄: %s", config.OutputDir)
	log.Printf("伺服器地址: http://%s", addr)
	log.Printf("重新整理間隔: %d 秒", config.RefreshSecs)

	if err := router.Run(addr); err != nil {
		log.Fatalf("啟動伺服器失敗: %v", err)
	}
	log.Printf("伺服器已停止")
}

// setupRouter 設定路由器
func setupRouter(config *Config, handlers *AppHandlers) *gin.Engine {
	// 設定 Gin 模式
	gin.SetMode(gin.ReleaseMode)

	router := gin.New()

	// 中介軟體
	router.Use(gin.Logger())
	router.Use(gin.Recovery())
	router.Use(corsMiddleware())
	router.Use(errorHandlerMiddleware())

	// 載入內嵌模板
	router.SetHTMLTemplate(loadTemplates())

	// 靜態檔案服務
	router.Static("/static", config.BaseDir)

	// 路由
	router.GET("/", handlers.IndexHandler)
	router.POST("/select", handlers.SelectHandler)
	router.GET("/segments", handlers.SegmentsHandler)
	router.GET("/images", handlers.ImagesHandler)
	router.POST("/export", handlers.ExportHandler)
	router.GET("/selections", handlers.GetSelectionsHandler)

	// 健康檢查端點
	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"status": "ok",
			"service": "select_image_go",
		})
	})

	return router
}

// loadTemplates 載入內嵌模板
func loadTemplates() *template.Template {
	// 添加自定義函數
	funcMap := template.FuncMap{
		"toJSON": func(v interface{}) string {
			b, _ := json.Marshal(v)
			return string(b)
		},
	}
	
	tmpl := template.New("").Funcs(funcMap)
	
	// 讀取模板檔案
	templateData, err := templatesFS.ReadFile("templates/gallery.html")
	if err != nil {
		log.Fatalf("載入模板失敗: %v", err)
	}
	
	_, err = tmpl.New("gallery.html").Parse(string(templateData))
	if err != nil {
		log.Fatalf("解析模板失敗: %v", err)
	}
	
	return tmpl
}

// corsMiddleware CORS 中介軟體
func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}

		c.Next()
	}
}

// errorHandlerMiddleware 錯誤處理中介軟體
func errorHandlerMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()

		// 處理錯誤
		if len(c.Errors) > 0 {
			err := c.Errors.Last()
			log.Printf("請求錯誤: %v", err)

			// 如果還沒有回應，發送錯誤回應
			if !c.Writer.Written() {
				c.JSON(http.StatusInternalServerError, ErrorResponse{
					Error:  "內部伺服器錯誤",
					Detail: err.Error(),
				})
			}
		}
	}
}
