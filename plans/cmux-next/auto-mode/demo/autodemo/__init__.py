"""Auto mode demo: a chat keeps running in the Cloud when the laptop goes away.

An independent, small build of the ideas in plans/cmux-next/auto-mode/DESIGN.md:
one holder per chat, an epoch that fences writes, a lease the laptop renews, a copy
(events, the agent's session file, the folder) the Cloud can start from, an inbox any
device can post to, and a machine that takes the chat when the lease runs out and gives
it back when the laptop returns. Standard library only.
"""

VERSION = "0.1"
