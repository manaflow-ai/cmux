title: Switch a chat between proxies without a restart
action: none

A route says how an agent reaches its model: its own sign-in, an API key, the local CodeRouter, a subrouter, CLIProxyAPI or any Anthropic- or OpenAI-compatible endpoint. Add one with `cmux route add`, make it the default with `cmux route use ID --default`, and move one chat with `cmux route use ID --chat CHAT`. The chat keeps its conversation: the agent restarts on the new route between turns and resumes where it was. Keys stay in the Keychain or the environment; a route file holds only a reference. `cmux route test ID` says whether the route answers, needs a sign-in, is rate limited or cannot be reached.
