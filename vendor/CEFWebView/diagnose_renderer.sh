#!/bin/zsh
# Diagnose renderer process spawn failure

echo "🔍 === CEF RENDERER SPAWN DIAGNOSTIC ==="
echo ""

echo "📋 1. CEF Debug Log (last 100 lines, filter for 'renderer' and errors):"
echo "---"
if [ -f ~/Library/Caches/com.chromium.webview/debug.log ]; then
    tail -100 ~/Library/Caches/com.chromium.webview/debug.log | grep -i "renderer\|error\|failed\|crash"
else
    echo "❌ File not found: ~/Library/Caches/com.chromium.webview/debug.log"
    echo "   Has the app been run yet?"
fi
echo ""

echo "📋 2. Helper Invocation Log (all entries):"
echo "---"
if [ -f /tmp/cef_helper_debug.log ]; then
    cat /tmp/cef_helper_debug.log
else
    echo "⚠️  File not found: /tmp/cef_helper_debug.log"
    echo "   Helper process may not be spawning at all"
fi
echo ""

echo "📋 3. System Logs - WebView crashes (last 50 entries):"
echo "---"
log show --predicate 'process == "WebView Helper"' --last 50m 2>/dev/null | tail -50 || echo "⚠️  Could not fetch system logs"
echo ""

echo "📋 4. Check if renderer --type= appears in logs:"
echo "---"
if [ -f ~/Library/Caches/com.chromium.webview/debug.log ]; then
    grep -i "type=renderer\|--renderer" ~/Library/Caches/com.chromium.webview/debug.log | head -5
else
    echo "⚠️  Debug log not available"
fi
echo ""

echo "✅ Diagnostic complete. Key things to check:"
echo "  - Does /tmp/cef_helper_debug.log show any '--type=renderer' invocations?"
echo "  - Are there 'error' or 'failed' entries in debug.log?"
echo "  - Do system logs show WebView Helper crashes?"
