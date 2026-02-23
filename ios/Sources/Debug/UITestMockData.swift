import Foundation
import ConvexMobile

enum UITestMockData {
    private static let jankConversationId = "ts79xr7rr98pbr98rb6vssta75800802"
    private static let jankTranscript: [String] = [
        "optimistic return 1769512215538",
        """
        I see you've provided what appears to be a number or identifier: `1769512215538`. Could you please clarify what you'd like me to do with this?

        Are you looking to:
        - Search for this value in a codebase?
        - Convert or interpret this number in some way?
        - Something else?

        Please provide more context about what task you'd like help with.
        """
    ]
    private static let tinyConversationId = "ts78emy26kmwvaj753cqxeb7ah807rd0"
    private static let tinyTranscript: [String] = [
        "6+6",
        "12"
    ]
    private static let e2bConversationId = "ts76s01mxqf2wayhv2hcxx76cd80447d"
    private static let e2bTranscript: [String] = [
        "Verify e2b snapshot links post-fix",
        """
        I'll help you verify the e2b snapshot links. Let me first explore the codebase to understand what this refers to and find the relevant files.
        
        The search didn't find any e2b snapshot links in the current working directory. Let me check if there might be a specific project or repository you're working with that I should look at. Let me also check if there are any git repositories or project directories that might contain this.
        
        I don't see any project files or git repositories in the current directory. It appears this is a fresh environment without a specific project loaded.
        
        To verify e2b snapshot links post-fix, I need more context:
        
        1. **Is there a specific project or repository** you'd like me to clone or examine?
        2. **What was the fix** that was applied to the e2b snapshot links?
        3. **Where should I look** for these links (a specific URL, repository, or file path)?
        
        Could you provide:
        - A repository URL to clone
        - A file path to check
        - Or more details about what e2b snapshot links need verification
        """
    ]
    private static let e2bToolCalls: [ConversationMessagesListByConversationReturnMessagesItemToolCallsItem] = [
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 15,
            result: nil,
            id: "tooluse_QaZs8aD4Naug5Cmgwi9LVu",
            name: "Find e2b snapshot links",
            status: .pending,
            arguments: "{\"description\":\"Find e2b snapshot links\",\"prompt\":\"Search the codebase for any references to \\\"e2b snapshot\\\" or \\\"e2b\\\" links/URLs. Look for:\\n1. Any files mentioning e2b snapshots\\n2. Configuration files with snapshot URLs\\n3. Documentation about e2b snapshots\\n4. Any recent fixes related to e2b snapshot links\\n\\nReport what you find including file paths and the specific links/content.\",\"subagent_type\":\"Explore\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 17,
            result: nil,
            id: "tooluse_DvFj3RRLy7iaeLtQ6WdPuz",
            name: "grep \"e2b\"",
            status: .completed,
            arguments: "{\"output_mode\":\"files_with_matches\",\"pattern\":\"e2b\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 18,
            result: nil,
            id: "tooluse_KnY6orkRa8FXnpodXPPkYp",
            name: "grep \"snapshot\"",
            status: .completed,
            arguments: "{\"output_mode\":\"files_with_matches\",\"pattern\":\"snapshot\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 23,
            result: nil,
            id: "tooluse_X7fRJztUKK2X9MZ3z6aQZy",
            name: "grep --include=\"**/*.{md,json,ts,tsx,js,jsx,py,yml,yaml,config}\" \"e2b\" /root",
            status: .completed,
            arguments: "{\"glob\":\"**/*.{md,json,ts,tsx,js,jsx,py,yml,yaml,config}\",\"output_mode\":\"content\",\"path\":\"/root\",\"pattern\":\"e2b\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 24,
            result: nil,
            id: "tooluse_V3WHCQG2SbqZNW6jR1knog",
            name: "grep --include=\"**/*.{md,json,ts,tsx,js,jsx,py,yml,yaml}\" \"snapshot.*url|snapshot.*link\" /root",
            status: .completed,
            arguments: "{\"glob\":\"**/*.{md,json,ts,tsx,js,jsx,py,yml,yaml}\",\"output_mode\":\"content\",\"path\":\"/root\",\"pattern\":\"snapshot.*url|snapshot.*link\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 29,
            result: nil,
            id: "tooluse_BMFkB1F9qehMSet7tvsWKG",
            name: "Find `/root` `**/*.{md,json,ts,tsx,js,jsx,py,yml,yaml}`",
            status: .completed,
            arguments: "{\"path\":\"/root\",\"pattern\":\"**/*.{md,json,ts,tsx,js,jsx,py,yml,yaml}\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 32,
            result: nil,
            id: "tooluse_7Hu1pC4q3ZVWZ9nWjYX1kb",
            name: "`find /root -maxdepth 3 -type f \\( -name \"*.md\" -o -name \"*.json\" -o -name \"*.ts\" -o -name \"*.js\" -o -name \"*.py\" -o -name \"*.yml\" -o -name \"*.yaml\" \\) ! -path \"*/.cache/*\" ! -path \"*/.bun/*\" ! -path \"*/.npm/*\" ! -path \"*/.rustup/*\" ! -path \"*/node_modules/*\" ! -path \"*/.config/*\" ! -path \"*/.codex/*\" ! -path \"*/.claude/*\" ! -path \"*/.agents/*\" 2>/dev/null | head -50`",
            status: .completed,
            arguments: "{\"command\":\"find /root -maxdepth 3 -type f \\\\( -name \\\"*.md\\\" -o -name \\\"*.json\\\" -o -name \\\"*.ts\\\" -o -name \\\"*.js\\\" -o -name \\\"*.py\\\" -o -name \\\"*.yml\\\" -o -name \\\"*.yaml\\\" \\\\) ! -path \\\"*/.cache/*\\\" ! -path \\\"*/.bun/*\\\" ! -path \\\"*/.npm/*\\\" ! -path \\\"*/.rustup/*\\\" ! -path \\\"*/node_modules/*\\\" ! -path \\\"*/.config/*\\\" ! -path \\\"*/.codex/*\\\" ! -path \\\"*/.claude/*\\\" ! -path \\\"*/.agents/*\\\" 2>/dev/null | head -50\",\"description\":\"Find source files in root without cache/toolchain directories\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 35,
            result: nil,
            id: "tooluse_Fq1Kc1MhdavNsoJmvWsT51",
            name: "`ls -la /root`",
            status: .completed,
            arguments: "{\"command\":\"ls -la /root\",\"description\":\"List contents of root directory\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 38,
            result: nil,
            id: "tooluse_VsxLaQBmjdtndTD2rx2Uun",
            name: "Read File",
            status: .completed,
            arguments: "{\"file_path\":\"/root/.claude.json\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 39,
            result: nil,
            id: "tooluse_QjTmkcYbYFPxaLxa2RK6bB",
            name: "grep \"e2b|snapshot\" /root/.claude.json",
            status: .completed,
            arguments: "{\"output_mode\":\"content\",\"path\":\"/root/.claude.json\",\"pattern\":\"e2b|snapshot\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 44,
            result: nil,
            id: "tooluse_CqVabU7sC3y8H5mQ11X94H",
            name: "`ls -la /root/workspace 2>/dev/null || echo \"No workspace directory\"`",
            status: .completed,
            arguments: "{\"command\":\"ls -la /root/workspace 2>/dev/null || echo \\\"No workspace directory\\\"\",\"description\":\"Check if workspace directory exists\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 45,
            result: nil,
            id: "tooluse_Py861frzaiXMFeCs135NqT",
            name: "`find /root -type f -name \"*.md\" -o -name \"*.json\" -o -name \"*.config\" 2>/dev/null | grep -v -E \"/(\\.cache|\\.bun|\\.npm|\\.rustup|\\.config|\\.codex|\\.claude|\\.agents|node_modules)/\" | head -20`",
            status: .completed,
            arguments: "{\"command\":\"find /root -type f -name \\\"*.md\\\" -o -name \\\"*.json\\\" -o -name \\\"*.config\\\" 2>/dev/null | grep -v -E \\\"/(\\\\.cache|\\\\.bun|\\\\.npm|\\\\.rustup|\\\\.config|\\\\.codex|\\\\.claude|\\\\.agents|node_modules)/\\\" | head -20\",\"description\":\"Find non-cache files in root\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 50,
            result: nil,
            id: "tooluse_HCW4yC5zecLwD7pgQWNxrr",
            name: "`grep -r \"e2b\" /root --include=\"*.md\" --include=\"*.json\" --include=\"*.ts\" --include=\"*.js\" --include=\"*.py\" --include=\"*.yaml\" --include=\"*.yml\" --include=\"*.config\" 2>/dev/null | grep -v -E \"/(\\.cache|\\.bun|\\.npm|\\.rustup|node_modules)/\" | head -50`",
            status: .completed,
            arguments: "{\"command\":\"grep -r \\\"e2b\\\" /root --include=\\\"*.md\\\" --include=\\\"*.json\\\" --include=\\\"*.ts\\\" --include=\\\"*.js\\\" --include=\\\"*.py\\\" --include=\\\"*.yaml\\\" --include=\\\"*.yml\\\" --include=\\\"*.config\\\" 2>/dev/null | grep -v -E \\\"/(\\\\.cache|\\\\.bun|\\\\.npm|\\\\.rustup|node_modules)/\\\" | head -50\",\"description\":\"Search for e2b references excluding build caches\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 53,
            result: nil,
            id: "tooluse_Dgsi2MSVWJyhxKiah91RLS",
            name: "`grep -r \"snapshot\" /root --include=\"*.md\" --include=\"*.json\" --include=\"*.ts\" --include=\"*.js\" --include=\"*.py\" --include=\"*.yaml\" --include=\"*.yml\" 2>/dev/null | grep -v -E \"/(\\.cache|\\.bun|\\.npm|\\.rustup|node_modules)/\" | head -50`",
            status: .completed,
            arguments: "{\"command\":\"grep -r \\\"snapshot\\\" /root --include=\\\"*.md\\\" --include=\\\"*.json\\\" --include=\\\"*.ts\\\" --include=\\\"*.js\\\" --include=\\\"*.py\\\" --include=\\\"*.yaml\\\" --include=\\\"*.yml\\\" 2>/dev/null | grep -v -E \\\"/(\\\\.cache|\\\\.bun|\\\\.npm|\\\\.rustup|node_modules)/\\\" | head -50\",\"description\":\"Search for snapshot references excluding build caches\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 56,
            result: nil,
            id: "tooluse_RnerdgUTsikd2P6HFDQpo1",
            name: "`grep -r \"e2b.io\\|e2b\\.io\\|e2b snapshot\\|e2b_snapshot\" /root 2>/dev/null | grep -v -E \"/(\\.cache|\\.bun|\\.npm|\\.rustup|node_modules)/\"`",
            status: .completed,
            arguments: "{\"command\":\"grep -r \\\"e2b.io\\\\|e2b\\\\.io\\\\|e2b snapshot\\\\|e2b_snapshot\\\" /root 2>/dev/null | grep -v -E \\\"/(\\\\.cache|\\\\.bun|\\\\.npm|\\\\.rustup|node_modules)/\\\"\",\"description\":\"Search for e2b URLs or e2b snapshot references\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 59,
            result: nil,
            id: "tooluse_Tkw5gRmLLdGfV3ZP83i1FV",
            name: "Read File",
            status: .completed,
            arguments: "{\"file_path\":\"/root/.claude/skills/agent-browser/SKILL.md\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 60,
            result: nil,
            id: "tooluse_Dijaj7koRv99cYChbQpy6r",
            name: "Read File",
            status: .completed,
            arguments: "{\"file_path\":\"/root/.config/opencode/skills/agent-browser/SKILL.md\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 65,
            result: nil,
            id: "tooluse_9kMBLbqGZAaEdgcmZom6ha",
            name: "`find /root -type f -name \"*.md\" -o -name \"*.json\" -o -name \"*.ts\" -o -name \"*.js\" 2>/dev/null | xargs grep -l \"e2b\" 2>/dev/null | grep -v -E \"/(\\.cache|\\.bun|\\.npm|\\.rustup|node_modules)/\"`",
            status: .completed,
            arguments: "{\"command\":\"find /root -type f -name \\\"*.md\\\" -o -name \\\"*.json\\\" -o -name \\\"*.ts\\\" -o -name \\\"*.js\\\" 2>/dev/null | xargs grep -l \\\"e2b\\\" 2>/dev/null | grep -v -E \\\"/(\\\\.cache|\\\\.bun|\\\\.npm|\\\\.rustup|node_modules)/\\\"\",\"description\":\"Find all files containing e2b reference, excluding common cache directories\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 68,
            result: nil,
            id: "tooluse_4poHDEQ51CzKnGfAHgjSF6",
            name: "`find /root -type f \\( -name \".gitignore\" -o -name \"*.config.*\" -o -name \"*.env*\" -o -name \"README*\" -o -name \"CHANGELOG*\" \\) 2>/dev/null | head -20`",
            status: .completed,
            arguments: "{\"command\":\"find /root -type f \\\\( -name \\\".gitignore\\\" -o -name \\\"*.config.*\\\" -o -name \\\"*.env*\\\" -o -name \\\"README*\\\" -o -name \\\"CHANGELOG*\\\" \\\\) 2>/dev/null | head -20\",\"description\":\"Find configuration and documentation files\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 69,
            result: nil,
            id: "tooluse_Rp7QFui9iWGiDsUk9imSwt",
            name: "`grep -r \"e2b\\|snapshot.*url\" /root/\\.agents /root/\\.claude /root/\\.codex /root/\\.config 2>/dev/null | head -100`",
            status: .completed,
            arguments: "{\"command\":\"grep -r \\\"e2b\\\\|snapshot.*url\\\" /root/\\\\.agents /root/\\\\.claude /root/\\\\.codex /root/\\\\.config 2>/dev/null | head -100\",\"description\":\"Search in configuration and agent directories\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 74,
            result: nil,
            id: "tooluse_9ntewTA5yAjNLKtKHyYL3A",
            name: "`grep -r \"e2b\" /root 2>/dev/null | head -100`",
            status: .completed,
            arguments: "{\"command\":\"grep -r \\\"e2b\\\" /root 2>/dev/null | head -100\",\"description\":\"Comprehensive search for any e2b references in entire root\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 77,
            result: nil,
            id: "tooluse_CczNnzVNvmbNavAMKnJ3VX",
            name: "`find /root -type f -path \"*/node_modules\" -prune -o -path \"*/.cache\" -prune -o -path \"*/.bun\" -prune -o -path \"*/.npm\" -prune -o -path \"*/.rustup\" -prune -o -type f \\( -name \"*.md\" -o -name \"*.json\" -o -name \"*.ts\" -o -name \"*.js\" \\) -exec grep -l \"e2b\" {} \\; 2>/dev/null`",
            status: .completed,
            arguments: "{\"command\":\"find /root -type f -path \\\"*/node_modules\\\" -prune -o -path \\\"*/.cache\\\" -prune -o -path \\\"*/.bun\\\" -prune -o -path \\\"*/.npm\\\" -prune -o -path \\\"*/.rustup\\\" -prune -o -type f \\\\( -name \\\"*.md\\\" -o -name \\\"*.json\\\" -o -name \\\"*.ts\\\" -o -name \\\"*.js\\\" \\\\) -exec grep -l \\\"e2b\\\" {} \\\\; 2>/dev/null\",\"description\":\"Find files with e2b, excluding standard cache directories\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 80,
            result: nil,
            id: "tooluse_7nLzUMoTpopXbFkC1V7DGQ",
            name: "`ls -la /root/.agents/skills/agent-browser/ 2>/dev/null`",
            status: .completed,
            arguments: "{\"command\":\"ls -la /root/.agents/skills/agent-browser/ 2>/dev/null\",\"description\":\"List agent-browser skill directory\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 81,
            result: nil,
            id: "tooluse_91goxdEEP32BsPJdykXD6w",
            name: "`find /root/.agents -type f | head -20`",
            status: .completed,
            arguments: "{\"command\":\"find /root/.agents -type f | head -20\",\"description\":\"Find files in .agents directory\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 86,
            result: nil,
            id: "tooluse_VDubCftu66y2bHZcLdLRw8",
            name: "`for dir in /root/.config /root/.claude /root/.codex /root/.agents; do\n  echo \"=== Searching in $dir ===\"\n  find \"$dir\" -type f \\( -name \"*.md\" -o -name \"*.json\" -o -name \"*.ts\" -o -name \"*.js\" -o -name \"*.txt\" \\) 2>/dev/null | while read file; do\n    if grep -q \"e2b\\|e2b_\\|e2b snapshot\" \"$file\" 2>/dev/null; then\n      echo \"Found in: $file\"\n      grep -n \"e2b\" \"$file\" 2>/dev/null | head -5\n    fi\n  done\ndone`",
            status: .completed,
            arguments: "{\"command\":\"for dir in /root/.config /root/.claude /root/.codex /root/.agents; do\\n  echo \\\"=== Searching in $dir ===\\\"\\n  find \\\"$dir\\\" -type f \\\\( -name \\\"*.md\\\" -o -name \\\"*.json\\\" -o -name \\\"*.ts\\\" -o -name \\\"*.js\\\" -o -name \\\"*.txt\\\" \\\\) 2>/dev/null | while read file; do\\n    if grep -q \\\"e2b\\\\|e2b_\\\\|e2b snapshot\\\" \\\"$file\\\" 2>/dev/null; then\\n      echo \\\"Found in: $file\\\"\\n      grep -n \\\"e2b\\\" \\\"$file\\\" 2>/dev/null | head -5\\n    fi\\n  done\\ndone\",\"description\":\"Search in configuration directories for e2b references\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 89,
            result: nil,
            id: "tooluse_YZ4fJoCTgW2suSG7cHZGvf",
            name: "Read File",
            status: .completed,
            arguments: "{\"file_path\":\"/root/.vscode-server-oss/data/User/settings.json\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 90,
            result: nil,
            id: "tooluse_3LCXMNUcjAETQEez5Tq5BK",
            name: "`ls -la /root/.local 2>/dev/null | head -20`",
            status: .completed,
            arguments: "{\"command\":\"ls -la /root/.local 2>/dev/null | head -20\",\"description\":\"Check .local directory\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 127,
            result: nil,
            id: "tooluse_MSLpmUbD7vZmi2na1bk3JH",
            name: "`ls -la /root/`",
            status: .pending,
            arguments: "{\"command\":\"ls -la /root/\",\"description\":\"List files in root directory\"}"
        ),
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: 129,
            result: nil,
            id: "tooluse_F1aTtB1imBh72PWwupYiqi",
            name: "`find /root -maxdepth 3 -type d -name \".git\" 2>/dev/null | head -20`",
            status: .pending,
            arguments: "{\"command\":\"find /root -maxdepth 3 -type d -name \\\".git\\\" 2>/dev/null | head -20\",\"description\":\"Find git repositories in root\"}"
        ),
    ]
    private static let toolCallSheetConversationId = "ts_toolcall_sheet_long"
    private static let toolCallSheetToolCallId = "toolcall_sheet_1"
    private static let toolCallSheetToolCalls: [ConversationMessagesListByConversationReturnMessagesItemToolCallsItem] = [
        ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            acpSeq: nil,
            result: nil,
            id: toolCallSheetToolCallId,
            name: "List workspace",
            status: .completed,
            arguments: "{\"command\":\"ls\"}"
        ),
    ]

    private static let morphConversationId = "ts7bx1k6fg8swft6edw4ykjg3s805hpj"
    private static let morphTranscript: [String] = [
        "Verify morph snapshot links post-https-fix",
        """
        I'll help you verify morph snapshot links after an HTTPS fix. Let me first explore the codebase to understand what we're working with.
        The exploration didn't find any project source code in the current working directory. Let me check what files and directories are available in the current location.
        There's no project code in the current directory. Let me check if there are any projects or code elsewhere in the system.
        The files found are all from system dependencies, not project source code. There doesn't appear to be a project repository in this environment. Let me check if there's a specific path or recent git history that might give us context about the morph snapshot work.
        No git repositories found. Let me check if there's anything in the user's clipboard or recent file activity that might indicate where the project is located.
        Found a project in `/app/cmux-code`. Let me explore it.
        Based on the exploration, I found that this is a VS Code-based project (cmux-code). The search didn't find any "morph" references, but found snapshot-related code in the heap profiler extension. Let me search more specifically for "morph" in case it's in a different location or format.
        Found "morph" references in multiple files. Let me examine the main workbench file and look for the morph-related code, particularly anything related to snapshots or HTTPS.
        The output is very long. Let me search more specifically for "morph" in the context of snapshots.
        I see - the "morph" references are related to SVG `feMorphology` (an SVG filter element), not a specific "morph snapshot" feature. Let me search more specifically for the actual snapshot link functionality.
        Let me read the extension.js file more carefully to understand the snapshot URI generation.
        Now I have a good understanding. Let me check the protocol handling specifically in this extension. I can see the code checks for `http:` and `https:` protocols. Let me verify the snapshot links are using HTTPS correctly.Based on my analysis of the code, here's what I found regarding the "morph snapshot links post-https-fix":
        
        **Finding:** The "morph" references in this codebase are actually SVG `feMorphology` filter elements (part of DOMPurify sanitization), not a specific "morph snapshot" feature.
        
        **Snapshot Link Generation (extension.js):**
        
        The snapshot URI generation code at `/app/cmux-code/extensions/ms-vscode.vscode-js-profile-table/out/extension.js` shows:
        
        1. **Protocol validation** (line ~1, in the `f` function):
        ```javascript
        if("http:"!==c.protocol&&"https:"!==c.protocol)return!1;
        ```
        This correctly accepts both HTTP and HTTPS protocols.
        
        2. **Snapshot URI generation** uses `asWebviewUri()`:
        ```javascript
        SNAPSHOT_URI:s.asWebviewUri(o).toString()
        ```
        The `asWebviewUri()` method automatically converts file URIs to webview-accessible URIs that use HTTPS in secure contexts.
        
        Let me verify the actual webview URI scheme being used.
        Now I have a complete picture. Let me update the todos and provide a summary.## Verification Results: Morph Snapshot Links Post-HTTPS Fix
        
        ### Summary
        
        I've analyzed the cmux-code (VS Code-based) codebase. Here are the findings:
        
        ### Key Findings
        
        1. **"Morph" Clarification**: The "morph" references found are SVG `feMorphology` elements (part of DOMPurify's allowed SVG filters list), not a dedicated "morph snapshot" feature.
        
        2. **Snapshot Link HTTPS Support - VERIFIED**:
        
           **Extension Code** (`/app/cmux-code/extensions/ms-vscode.vscode-js-profile-table/out/extension.js`):
           - Protocol validation correctly handles both HTTP and HTTPS:
             ```javascript
             if("http:"!==c.protocol&&"https:"!==c.protocol)return!1;
             ```
           - Snapshot URIs are generated using `asWebviewUri()` which automatically converts to HTTPS-compatible webview URIs
        
        3. **Service Worker HTTPS Handling** (`/app/cmux-code/out/vs/workbench/contrib/webview/browser/pre/service-worker.js`):
           - Correctly checks for `https:` protocol:
             ```javascript
             if(typeof resourceBaseAuthority=="string"&&t.protocol==="https:"&&t.hostname.endsWith("."+resourceBaseAuthority))
             ```
           - Resource requests are properly routed through the secure webview infrastructure
        
        4. **CSP (Content Security Policy) Updates** (`/app/cmux-code/out/vs/workbench/contrib/webview/browser/pre/index.html`):
           - Line 919: CSP rewriting properly handles both `vscode-webview-resource` and `vscode-resource` schemes
           - Dynamic CSP source replacement ensures compatibility with HTTPS contexts
        
        ### Verification Status: **PASS**
        
        The snapshot links infrastructure correctly supports HTTPS:
        - `asWebviewUri()` generates secure webview-compatible URIs
        - Service worker properly handles `https:` protocol for resource requests
        - CSP headers are dynamically updated to match the security context
        - Both `http:` and `https:` protocols are accepted in call frame URL validation
        """
    ]

    static func conversations() -> [ConvexConversation] {
        let now = Date().timeIntervalSince1970 * 1000
        let earlier = now - 90_000
        let teamId = "uitest_team"

        let succession = makeConversation(
            id: jankConversationId,
            title: "Optimistic return code",
            providerId: "claude",
            previewText: jankTranscript.first ?? "UI test conversation",
            teamId: teamId,
            createdAt: earlier - 45_000,
            updatedAt: now
        )

        let morphSnapshot = makeConversation(
            id: morphConversationId,
            title: "Verify morph snapshot links after HTTPS fix",
            providerId: "claude",
            previewText: morphTranscript.first ?? "UI test conversation",
            teamId: teamId,
            createdAt: earlier - 30_000,
            updatedAt: now
        )

        let tinyConversation = makeConversation(
            id: tinyConversationId,
            title: "Calculate 6 plus 6",
            providerId: "claude",
            previewText: tinyTranscript.first ?? "UI test conversation",
            teamId: teamId,
            createdAt: earlier - 15_000,
            updatedAt: now
        )

        let e2bSnapshot = makeConversation(
            id: e2bConversationId,
            title: "Verify e2b snapshot links post-fix",
            providerId: "claude",
            previewText: e2bTranscript.first ?? "UI test conversation",
            teamId: teamId,
            createdAt: earlier - 12_000,
            updatedAt: now
        )

        let toolCallSheet = makeConversation(
            id: toolCallSheetConversationId,
            title: "Tool call sheet dismiss",
            providerId: "claude",
            previewText: "Tool call sheet mock conversation.",
            teamId: teamId,
            createdAt: earlier - 9_000,
            updatedAt: now
        )

        let claude = makeConversation(
            id: "uitest_conversation_claude",
            title: "Claude",
            providerId: "claude",
            previewText: "Mocked conversation for UI tests.",
            teamId: teamId,
            createdAt: earlier,
            updatedAt: now
        )

        let alex = makeConversation(
            id: "uitest_conversation_alex",
            title: "Alex Rivera",
            providerId: "codex",
            previewText: "Short thread layout fixture.",
            teamId: teamId,
            createdAt: earlier - 90_000,
            updatedAt: earlier
        )

        return [succession, morphSnapshot, tinyConversation, e2bSnapshot, toolCallSheet, claude, alex]
    }

    static func messages(for conversationId: String) -> [ConvexMessage] {
        let now = Date().timeIntervalSince1970 * 1000
        let earlier = now - 60_000
        let first = earlier - 30_000
        let idPrefix = conversationId.replacingOccurrences(of: "uitest_conversation_", with: "uitest_msg_")
        if conversationId == jankConversationId {
            let transcript = jankTranscript
            let start = now - Double(transcript.count) * 1200
            let lastUserIndex = transcript.indices.last { $0 % 2 == 0 }
            let lastAssistantIndex = transcript.indices.last { $0 % 2 == 1 }
            return transcript.enumerated().map { index, text in
                let isAssistant = index % 2 == 1
                let role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum =
                    isAssistant ? .assistant : .user
                let id: String
                if let lastUserIndex, index == lastUserIndex {
                    id = "\(conversationId)_user"
                } else if let lastAssistantIndex, index == lastAssistantIndex {
                    id = "\(conversationId)_assistant"
                } else {
                    id = "\(conversationId)_transcript_\(index + 1)"
                }
                return makeMessage(
                    id: id,
                    conversationId: conversationId,
                    role: role,
                    text: text,
                    createdAt: start + Double(index) * 1200
                )
            }
        }
        if conversationId == morphConversationId {
            let transcript = morphTranscript
            let start = now - Double(transcript.count) * 1200
            let lastUserIndex = transcript.indices.last { $0 % 2 == 0 }
            let lastAssistantIndex = transcript.indices.last { $0 % 2 == 1 }
            return transcript.enumerated().map { index, text in
                let isAssistant = index % 2 == 1
                let role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum =
                    isAssistant ? .assistant : .user
                let id: String
                if let lastUserIndex, index == lastUserIndex {
                    id = "\(conversationId)_user"
                } else if let lastAssistantIndex, index == lastAssistantIndex {
                    id = "\(conversationId)_assistant"
                } else {
                    id = "\(conversationId)_transcript_\(index + 1)"
                }
                return makeMessage(
                    id: id,
                    conversationId: conversationId,
                    role: role,
                    text: text,
                    createdAt: start + Double(index) * 1200
                )
            }
        }
        if conversationId == tinyConversationId {
            let transcript = tinyTranscript
            let start = now - Double(transcript.count) * 1200
            let lastUserIndex = transcript.indices.last { $0 % 2 == 0 }
            let lastAssistantIndex = transcript.indices.last { $0 % 2 == 1 }
            return transcript.enumerated().map { index, text in
                let isAssistant = index % 2 == 1
                let role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum =
                    isAssistant ? .assistant : .user
                let id: String
                if let lastUserIndex, index == lastUserIndex {
                    id = "\(conversationId)_user"
                } else if let lastAssistantIndex, index == lastAssistantIndex {
                    id = "\(conversationId)_assistant"
                } else {
                    id = "\(conversationId)_transcript_\(index + 1)"
                }
                return makeMessage(
                    id: id,
                    conversationId: conversationId,
                    role: role,
                    text: text,
                    createdAt: start + Double(index) * 1200
                )
            }
        }
        if conversationId == e2bConversationId {
            let transcript = e2bTranscript
            let start = now - Double(transcript.count) * 1200
            let lastUserIndex = transcript.indices.last { $0 % 2 == 0 }
            let lastAssistantIndex = transcript.indices.last { $0 % 2 == 1 }
            return transcript.enumerated().map { index, text in
                let isAssistant = index % 2 == 1
                let role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum =
                    isAssistant ? .assistant : .user
                let id: String
                if let lastUserIndex, index == lastUserIndex {
                    id = "\(conversationId)_user"
                } else if let lastAssistantIndex, index == lastAssistantIndex {
                    id = "\(conversationId)_assistant"
                } else {
                    id = "\(conversationId)_transcript_\(index + 1)"
                }
                let toolCalls = isAssistant ? e2bToolCalls : nil
                return makeMessage(
                    id: id,
                    conversationId: conversationId,
                    role: role,
                    text: text,
                    createdAt: start + Double(index) * 1200,
                    toolCalls: toolCalls
                )
            }
        }
        if conversationId == toolCallSheetConversationId {
            let baseTime = now - 45_000
            let interval: Double = 900
            let fillerCount = 18
            var messages: [ConvexMessage] = []
            messages.reserveCapacity(fillerCount + 1)
            for index in 0..<fillerCount {
                let isAssistant = index % 2 == 1
                let role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum =
                    isAssistant ? .assistant : .user
                let prefix = isAssistant ? "Assistant message" : "User message"
                let text = "\(prefix) \(index + 1)\nLine one\nLine two"
                messages.append(
                    makeMessage(
                        id: "\(conversationId)_msg_\(index + 1)",
                        conversationId: conversationId,
                        role: role,
                        text: text,
                        createdAt: baseTime + Double(index) * interval
                    )
                )
            }
            let toolCallText = "Tool call summary\nCheck complete\nNo errors found"
            messages.append(
                makeMessage(
                    id: "\(conversationId)_assistant",
                    conversationId: conversationId,
                    role: .assistant,
                    text: toolCallText,
                    createdAt: baseTime + Double(fillerCount) * interval,
                    toolCalls: toolCallSheetToolCalls
                )
            )
            return messages
        }
        if let messageCount = messageCountOverride(), messageCount >= 1 {
            let startWithAssistant = startWithAssistant(messageCount: messageCount)
            let baseTime = now - Double(messageCount) * 900
            return (0..<messageCount).map { index in
                let isAssistant = startWithAssistant ? index % 2 == 0 : index % 2 == 1
                let role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum = isAssistant ? .assistant : .user
                let baseText = isAssistant ? "Assistant message \(index + 1)" : "User message \(index + 1)"
                let text = makeMessageText(base: baseText, index: index)
                let createdAt = baseTime + Double(index) * 900
                return makeMessage(
                    id: "\(idPrefix)_\(index + 1)",
                    conversationId: conversationId,
                    role: role,
                    text: text,
                    createdAt: createdAt
                )
            }
        }

        let messages: [(String, ConversationMessagesListByConversationReturnMessagesItemRoleEnum, String, Double)] = [
            ("\(idPrefix)_1", .assistant, "Here’s a quick plan for the task.", first),
            ("\(idPrefix)_2", .user, "Sounds good—can you expand?", earlier),
            ("\(idPrefix)_3", .assistant, "Absolutely. I’ll outline the steps and edge cases.", now)
        ]

        return messages.map { entry in
            makeMessage(
                id: entry.0,
                conversationId: conversationId,
                role: entry.1,
                text: entry.2,
                createdAt: entry.3
            )
        }
    }

    private static func messageCountOverride() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_MESSAGE_COUNT"],
              let count = Int(raw) else {
            return nil
        }
        return max(1, min(200, count))
    }

    private static func longMessageLineCount() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_LONG_MESSAGE_LINES"],
              let count = Int(raw) else {
            return nil
        }
        return max(1, min(80, count))
    }

    private static func makeMessageText(base: String, index: Int) -> String {
        guard let lineCount = longMessageLineCount() else {
            return base
        }
        let safeCount = max(1, lineCount)
        guard safeCount > 1 else {
            return base
        }
        var lines: [String] = []
        lines.reserveCapacity(safeCount)
        lines.append(base)
        for lineIndex in 1..<safeCount {
            lines.append("Filler line \(index + 1)-\(lineIndex + 1)")
        }
        return lines.joined(separator: "\n")
    }

    private static func startWithAssistant(messageCount: Int) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_ENDS_WITH_USER"] else {
            return messageCount % 2 == 1
        }
        let lower = raw.lowercased()
        let endsWithUser = lower == "1" || lower == "true"
        if endsWithUser {
            return messageCount % 2 == 0
        }
        return messageCount % 2 == 1
    }

    private static func makeConversation(
        id: String,
        title: String,
        providerId: String,
        previewText: String,
        teamId: String,
        createdAt: Double,
        updatedAt: Double
    ) -> ConvexConversation {
        let conversation = ConversationsListPagedWithLatestReturnPageItemConversation(
            _id: ConvexId(rawValue: id),
            _creationTime: createdAt,
            userId: "uitest_user",
            isArchived: false,
            pinned: false,
            sandboxInstanceId: nil,
            title: title,
            clientConversationId: nil,
            modelId: nil,
            permissionMode: nil,
            stopReason: nil,
            namespaceId: nil,
            isolationMode: nil,
            modes: nil,
            agentInfo: nil,
            acpSandboxId: nil,
            initializedOnSandbox: true,
            lastMessageAt: updatedAt,
            lastAssistantVisibleAt: nil,
            teamId: teamId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: .active,
            sessionId: "session_\(id)",
            providerId: providerId,
            cwd: "/workspace"
        )

        let preview = ConversationsListPagedWithLatestReturnPageItemPreview(
            text: previewText,
            kind: .text
        )

        return ConversationsListPagedWithLatestReturnPageItem(
            conversation: conversation,
            preview: preview,
            unread: false,
            lastReadAt: nil,
            latestMessageAt: updatedAt,
            title: title
        )
    }

    private static func makeMessage(
        id: String,
        conversationId: String,
        role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum,
        text: String,
        createdAt: Double,
        toolCalls: [ConversationMessagesListByConversationReturnMessagesItemToolCallsItem]? = nil
    ) -> ConvexMessage {
        let content = ConversationMessagesListByConversationReturnMessagesItemContentItem(
            name: nil,
            text: text,
            description: nil,
            mimeType: nil,
            title: nil,
            resource: nil,
            data: nil,
            uri: nil,
            size: nil,
            annotations: nil,
            type: .text
        )

        return ConversationMessagesListByConversationReturnMessagesItem(
            _id: ConvexId(rawValue: id),
            _creationTime: createdAt,
            clientMessageId: nil,
            deliveryStatus: .sent,
            deliveryError: nil,
            deliverySwapAttempted: nil,
            acpSeq: nil,
            toolCalls: toolCalls,
            reasoning: nil,
            isFinal: nil,
            createdAt: createdAt,
            role: role,
            content: [content],
            conversationId: ConvexId(rawValue: conversationId)
        )
    }
}
