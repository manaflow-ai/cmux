#!/bin/zsh
# capture_logs.sh - Capture co.sstools.WebView app logs (Swift + C++ + CEF)

BUNDLE_ID="co.sstools.WebView"
SUBSYSTEMS='subsystem == "co.sstools.WebView" OR subsystem == "co.sstools.CEFWebView"'

# Create logs directory if it doesn't exist
mkdir -p logs

# Generate timestamp for filename
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="logs/logs_${TIMESTAMP}.txt"

echo "📋 Capturing logs from the past 2 minutes..."
echo "   Bundle ID: $BUNDLE_ID"
echo "💾 Writing to: $LOG_FILE"

# Capture all logs for the app
{
    echo "=========================================="
    echo "WebView App Logs - Captured at: $(date)"
    echo "Bundle ID: $BUNDLE_ID"
    echo "=========================================="
    echo ""

    # 1. Main app process and Logger subsystems
    echo "--- Swift Logger + NSLog (App Subsystems) ---"
    echo ""
    /usr/bin/log show --predicate "$SUBSYSTEMS" --debug --info --last 2m 2>/dev/null || {
        echo "⚠️  Could not read system logs."
    }

    echo ""
    echo "--- NSLog Output from WebView Process ---"
    echo ""
    /usr/bin/log show --predicate 'process == "WebView"' --debug --info --last 2m 2>/dev/null || {
        echo "⚠️  Could not read WebView process logs."
    }

    echo ""
    echo "--- System Logs (All App-Related Processes) ---"
    echo ""
    /usr/bin/log show --predicate "processImagePath CONTAINS \"$BUNDLE_ID\" OR process == \"CEFHelper\" OR process == \"CEFHelperRenderer\" OR process == \"WebView\"" --debug --info --last 2m 2>/dev/null || {
        echo "⚠️  Could not read system logs. You may need to run with elevated permissions."
        echo "Try: sudo $0"
    }

    echo ""
    echo "--- CEF Helper Debug Log (/tmp) ---"
    echo ""

    # Capture CEF helper debug log from /tmp
    if [ -f "/tmp/cef_helper_debug.log" ]; then
        echo "Found: /tmp/cef_helper_debug.log (last 100 lines):"
        echo ""
        tail -100 "/tmp/cef_helper_debug.log"
    else
        echo "⚠️  CEF helper debug log not found at /tmp/cef_helper_debug.log"
    fi

    echo ""
    echo "--- CEF Debug Log (if available) ---"
    echo ""

    # Find CEF debug log in Chromium WebView cache directory
    CEF_CACHE_DIR="$HOME/Library/Caches/com.chromium.webview"
    if [ -d "$CEF_CACHE_DIR" ]; then
        echo "Searching for CEF logs in: $CEF_CACHE_DIR"
        if [ -f "$CEF_CACHE_DIR/debug.log" ]; then
            echo "Found: $CEF_CACHE_DIR/debug.log (last 100 lines):"
            echo ""
            tail -100 "$CEF_CACHE_DIR/debug.log"
        else
            echo "⚠️  CEF debug.log not found in $CEF_CACHE_DIR"
            echo "    Available files in cache directory:"
            ls -la "$CEF_CACHE_DIR" 2>/dev/null | head -20
        fi
    else
        echo "⚠️  Cache directory not found: $CEF_CACHE_DIR"
        echo "    The app may not have run yet."
    fi

    echo ""
    echo "--- Running Processes ---"
    echo ""
    echo "Main app process:"
    ps aux | grep -E "WebView|$BUNDLE_ID" | grep -v grep || echo "  (not found)"

    echo ""
    echo "CEF helper processes:"
    ps aux | grep -E "CEFHelper|CEFHelperRenderer" | grep -v grep || echo "  (none found)"

    echo ""
    echo "=========================================="
    echo "End of Logs"
    echo "=========================================="
} > "$LOG_FILE"

echo "$LOG_FILE"
