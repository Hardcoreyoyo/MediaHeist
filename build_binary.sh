#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# MediaHeist Go 二進制建置腳本
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
BINARY_NAME="mediaheist"

# 清理建置目錄
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "正在建置 MediaHeist Go 二進制檔案..."

# 檢查 Go 是否已安裝
if ! command -v go >/dev/null 2>&1; then
    echo "錯誤：請先安裝 Go (https://golang.org/dl/)"
    exit 1
fi

# 更新 assets 目錄（確保打包最新檔案）
echo "更新 assets 目錄..."
rm -rf "$SCRIPT_DIR/cmd/mediaheist/assets"
mkdir -p "$SCRIPT_DIR/cmd/mediaheist/assets"
cp -r "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/cmd/mediaheist/assets/"
echo "✓ assets 目錄更新完成"

# 初始化 Go 模組（如果尚未初始化）
if [[ ! -f "$SCRIPT_DIR/cmd/mediaheist/go.mod" ]]; then
    echo "初始化 Go 模組..."
    cd "$SCRIPT_DIR/cmd/mediaheist"
    go mod init mediaheist
fi


cd "$SCRIPT_DIR/cmd/mediaheist"
echo "now path: $(pwd)"

# 建置不同平台的二進制檔案
platforms=(
    "darwin/arm64"
)

# "darwin/amd64"   # macOS Intel
# "darwin/arm64"   # macOS Apple Silicon
# "linux/amd64"    # Linux x64
# "linux/arm64"    # Linux ARM64
# "windows/amd64"  # Windows x64

for platform in "${platforms[@]}"; do
    IFS='/' read -r GOOS GOARCH <<< "$platform"
    output_name="$BUILD_DIR/${BINARY_NAME}-${GOOS}-${GOARCH}"
    
    if [[ "$GOOS" == "windows" ]]; then
        output_name="${output_name}.exe"
    fi
    
    echo "建置 $GOOS/$GOARCH..."
    
    GOOS="$GOOS" GOARCH="$GOARCH" go build \
        -ldflags="-s -w" \
        -o "$output_name" \
        ./
    
    echo "✓ 完成: $output_name ($(du -h "$output_name" | cut -f1))"
done

# 建立當前平台的預設執行檔
current_os=$(uname -s | tr '[:upper:]' '[:lower:]')
current_arch=$(uname -m)

case "$current_arch" in
    x86_64) current_arch="amd64" ;;
    arm64|aarch64) current_arch="arm64" ;;
esac

case "$current_os" in
    darwin) current_platform="darwin" ;;
    linux) current_platform="linux" ;;
    mingw*|cygwin*|msys*) current_platform="windows" ;;
esac

if [[ -n "${current_platform:-}" ]]; then
    current_binary="$BUILD_DIR/${BINARY_NAME}-${current_platform}-${current_arch}"
    if [[ "$current_platform" == "windows" ]]; then
        current_binary="${current_binary}.exe"
    fi
    
    if [[ -f "$current_binary" ]]; then
        cp "$current_binary" "$BUILD_DIR/$BINARY_NAME"
        echo "✓ 建立當前平台執行檔: $BUILD_DIR/$BINARY_NAME"
    fi
fi

echo "clean assets..."
rm -rf "$SCRIPT_DIR/cmd/mediaheist/assets"

echo ""
echo "建置完成！輸出檔案位於: $BUILD_DIR/"
echo "檔案列表:"
ls -lh "$BUILD_DIR/"
echo ""
echo "使用方式:"
echo "  ./$BUILD_DIR/$BINARY_NAME download URL=\"https://youtu.be/xxxx\""
echo "  ./$BUILD_DIR/$BINARY_NAME all LIST=urls.txt MAX_JOBS=8"
