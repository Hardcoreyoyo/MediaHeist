#!/usr/bin/env bash
# build.sh - 編譯圖片選擇伺服器的跨平台二進制檔案

set -euo pipefail

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 版本資訊
VERSION=$(date +%Y%m%d_%H%M%S)
APP_NAME="select_image_go"

echo -e "${BLUE}=== 圖片選擇伺服器編譯腳本 ===${NC}"
echo "版本: $VERSION"
echo

# 檢查 Go 版本
echo -e "${YELLOW}檢查 Go 版本...${NC}"
if ! command -v go &> /dev/null; then
    echo -e "${RED}錯誤: 未找到 Go 命令，請先安裝 Go 1.24+${NC}"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
echo "當前 Go 版本: $GO_VERSION"

# 檢查 Go 版本是否符合要求 (1.24+)
if ! go version | grep -q "go1\.2[4-9]\|go1\.[3-9][0-9]\|go[2-9]\."; then
    echo -e "${YELLOW}警告: 建議使用 Go 1.24 或更高版本${NC}"
fi

# 確保依賴已下載
echo -e "${YELLOW}下載依賴...${NC}"
go mod tidy

# 建立 dist 目錄
DIST_DIR="dist"
mkdir -p "$DIST_DIR"

# 編譯函數
build_binary() {
    local os=$1
    local arch=$2
    local ext=$3
    local output_name="${APP_NAME}_${os}_${arch}${ext}"
    
    echo -e "${YELLOW}編譯 ${os}/${arch}...${NC}"
    
    GOOS=$os GOARCH=$arch go build \
        -ldflags "-s -w -X main.Version=$VERSION" \
        -o "$DIST_DIR/$output_name" \
        .
    
    if [ $? -eq 0 ]; then
        size=$(du -h "$DIST_DIR/$output_name" | cut -f1)
        echo -e "${GREEN}✓ $output_name ($size)${NC}"
    else
        echo -e "${RED}✗ 編譯 $output_name 失敗${NC}"
        return 1
    fi
}

# 編譯當前平台版本
echo -e "${YELLOW}編譯當前平台版本...${NC}"
go build -ldflags "-s -w -X main.Version=$VERSION" -o "$APP_NAME" .
if [ $? -eq 0 ]; then
    size=$(du -h "$APP_NAME" | cut -f1)
    echo -e "${GREEN}✓ $APP_NAME ($size)${NC}"
else
    echo -e "${RED}✗ 編譯當前平台版本失敗${NC}"
    exit 1
fi

# 編譯跨平台版本
echo
echo -e "${YELLOW}編譯跨平台版本...${NC}"

# Linux
# build_binary "linux" "amd64" ""
# build_binary "linux" "arm64" ""

# Windows
# build_binary "windows" "amd64" ".exe"
# build_binary "windows" "arm64" ".exe"

# macOS
# build_binary "darwin" "amd64" ""
build_binary "darwin" "arm64" ""

echo
echo -e "${GREEN}=== 編譯完成 ===${NC}"
echo "檔案位置:"
echo "  當前平台: ./$APP_NAME"
echo "  跨平台版本: ./$DIST_DIR/"
echo

# 顯示檔案列表
echo -e "${BLUE}編譯結果:${NC}"
ls -lh "$APP_NAME" 2>/dev/null || true
ls -lh "$DIST_DIR"/ 2>/dev/null || true

echo
echo -e "${GREEN}使用方法:${NC}"
echo "  ./$APP_NAME --help"
echo "  ./$APP_NAME --base-dir /path/to/images"
echo

echo -e "${BLUE}=== 編譯腳本執行完成 ===${NC}"
