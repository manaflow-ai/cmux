#!/usr/bin/env zsh

set -e

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Directories
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBVIEW_PROJECT="$PROJECT_DIR/WebView"
BUILD_DIR="$PROJECT_DIR/.build"
RELEASE_DIR="$PROJECT_DIR/Release"

# Function to print colored output
log_info() {
    echo "${BLUE}ℹ ${1}${NC}"
}

log_success() {
    echo "${GREEN}✓ ${1}${NC}"
}

log_warning() {
    echo "${YELLOW}⚠ ${1}${NC}"
}

log_error() {
    echo "${RED}✗ ${1}${NC}"
}

# Build CEF dependencies
build_cef() {
    log_info "Building CEF dependencies..."

    cd "$PROJECT_DIR"
    ./build_cpp.sh > /dev/null 2>&1 || {
        log_error "CEF build failed"
        return 1
    }

    log_success "CEF dependencies built"
}

# Clean action
clean() {
    log_info "Cleaning build artifacts..."

    # Clean Xcode derived data
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        log_success "Cleaned .build directory"
    fi

    log_success "Clean complete"
}

# Build action
build() {
    log_info "Building WebView..."

    # Build CEF first
    build_cef

    # Build the Xcode project
    log_info "Building Xcode project with Swift package..."
    cd "$WEBVIEW_PROJECT"

    xcodebuild -project WebView.xcodeproj \
        -scheme WebView \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR/xcode" \
        build 2>&1 | tee "$PROJECT_DIR/build.log" || {
        log_error "Xcode build failed. See build.log for details."
        return 1
    }

    log_success "WebView built successfully"
}

# Release action
release() {
    log_info "Preparing release build..."

    # Clean first
    clean

    # Build CEF dependencies
    build_cef

    # Build release configuration
    log_info "Building release configuration..."
    cd "$WEBVIEW_PROJECT"

    xcodebuild -project WebView.xcodeproj \
        -scheme WebView \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR/xcode" \
        build 2>&1 | tee "$PROJECT_DIR/release.log" || {
        log_error "Release build failed. See release.log for details."
        return 1
    }

    # Create release directory
    mkdir -p "$RELEASE_DIR"

    # Copy release artifacts
    log_info "Copying release artifacts..."
    RELEASE_APP="$BUILD_DIR/xcode/Build/Products/Release/WebView.app"
    if [ -d "$RELEASE_APP" ]; then
        cp -R "$RELEASE_APP" "$RELEASE_DIR/"
        log_success "App copied to $RELEASE_DIR"
    fi

    # Generate release notes
    RELEASE_NOTES="$RELEASE_DIR/RELEASE_NOTES.txt"
    cat > "$RELEASE_NOTES" << EOF
# WebView Release
Generated: $(date)

## Build Info
- Configuration: Release
- Xcode Version: $(xcodebuild -version)
- CEF Version: 146.0.10

## Contents
- WebView.app: macOS application
- Build artifacts in .build/release

## Notes
- See release.log for detailed build output
- Swift package (CEFWebView) built as app dependency
EOF

    log_success "Release package created in $RELEASE_DIR"
    log_info "Release notes: $RELEASE_NOTES"
}

# Version check
version() {
    log_info "Version Information:"
    echo "  Xcode: $(xcodebuild -version)"
    echo "  Project: $PROJECT_DIR"
    echo "  Swift: $(swift --version 2>/dev/null | head -1)"
}

# Help message
show_help() {
    echo -e "${BLUE}WebView Build Script${NC}\n"
    echo -e "${GREEN}Usage:${NC}"
    echo "  ./build.sh [action]"
    echo ""
    echo -e "${GREEN}Actions:${NC}"
    echo "  clean      - Remove all build artifacts"
    echo "  build      - Build debug configuration (includes CEF and Swift package)"
    echo "  release    - Build release configuration with artifacts"
    echo "  version    - Show version information"
    echo "  help       - Show this help message"
    echo ""
    echo -e "${GREEN}Examples:${NC}"
    echo "  ./build.sh clean"
    echo "  ./build.sh build"
    echo "  ./build.sh release"
    echo ""
    echo -e "${YELLOW}Note:${NC} Run from project root directory"
    echo -e "${YELLOW}Note:${NC} Builds WebView.xcodeproj with the root CEFWebView Swift package"
}

# Main script logic
main() {
    # If no arguments provided, show help
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    # Execute each action in sequence
    for action in "$@"; do
        case "$action" in
            clean)
                clean
                ;;
            build)
                build
                ;;
            release)
                release
                ;;
            version)
                version
                ;;
            help)
                show_help
                ;;
            *)
                log_error "Unknown action: $action"
                show_help
                exit 1
                ;;
        esac
    done
}

# Run main script
main "$@"
