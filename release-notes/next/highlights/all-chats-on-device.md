title: Every chat on your Mac, in one place

cmux now finds the chats of Claude Code, Codex, OpenCode, Pi, Gemini CLI, Cursor agent and Amp on this Mac, also in extra homes such as subrouter accounts. Search them with `cmux chats list` or in the command palette (Agent Chats), and open one with `cmux chats open`: it resumes in its own harness, or opens read-only when no harness can resume it. Nothing leaves the Mac.

The sidebar no longer shows Recents. A Chats section with search and grouping by harness, folder or account is available: turn on `sidebar.showChats` in Settings or cmux.json. `agents.chats.roots` adds folders, `agents.chats.discovery` turns off automatic folder discovery, and `agents.chats.enabled` turns the feature off. Documents, Desktop, Downloads, the home folder and other protected folders are never read.
