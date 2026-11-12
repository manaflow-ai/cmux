"""Verify interactive CLI submission through the tagged Mac's phone RPC.

Models are replaced by a local HTTP recorder. No provider credentials or model
output are involved; success proves the CLI accepted the exact user prompt and
issued its model request. It does not prove provider authentication or inference.
"""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import subprocess
import shutil
import threading
import time
import uuid
from test_mobile_terminal_paste_submit import call

parser = argparse.ArgumentParser()
parser.add_argument("provider", choices=["pi", "gemini", "opencode", "cursor", "grok"])
parser.add_argument("--multiline", action="store_true")
parser.add_argument("--tools-root", type=Path, required=True)
parser.add_argument("--artifacts", type=Path, required=True)
args = parser.parse_args()
base = args.tools_root.resolve()
args.artifacts.mkdir(parents=True, exist_ok=True)
root = args.artifacts.resolve() / (args.provider + "-" + str(uuid.uuid4())[:8])
root.mkdir()
project = root / "project"
project.mkdir()
home = root / "home"
home.mkdir()
requests = []
requests_lock = threading.Lock()

class Recorder(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if not size:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            raw_body = b"".join(chunks)
        else:
            raw_body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = raw_body.decode(errors="replace")
        try:
            payload = json.loads(body)
        except ValueError:
            payload = body
        with requests_lock:
            requests.append({"path": self.path, "body": payload})
            temporary = root / "requests.tmp"
            temporary.write_text(json.dumps(requests, indent=2))
            temporary.replace(root / "requests.json")
        if args.provider == "cursor" and self.path.startswith("/aiserver.") and "cmux-reply-" not in body:
            # Cursor's published protobuf schema: GetUsableModels.models (1)
            # contains ModelDetails.model_id (1) and display strings (3,4,5).
            model = b"\x0a\x04auto\x1a\x04auto\x22\x04Auto\x2a\x04Auto"
            response = b""
            if self.path.endswith(("/GetUsableModels", "/GetDefaultModelForCli")):
                response = b"\x0a" + bytes([len(model)]) + model
            elif self.path.endswith("/AvailableModels"):
                response = b"\x0a\x04auto"
            self.send_response(200)
            self.send_header("Content-Type", "application/proto")
            self.end_headers()
            self.wfile.write(response)
            return
        if self.path == "/auth/exchange_user_api_key":
            payload = base64.urlsafe_b64encode(json.dumps({"sub": "fixture-user", "exp": int(time.time()) + 3600}).encode()).decode().rstrip("=")
            response = {"accessToken": "e30." + payload + ".fixture", "refreshToken": "fixture-refresh"}
            self.send_response(200)
        elif "countTokens" in self.path:
            response = {"totalTokens": 1}
            self.send_response(200)
        else:
            response = {"error": {"message": "Submission captured by cmux verification", "code": 400, "status": "INVALID_ARGUMENT"}}
            self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())

server = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
threading.Thread(target=server.serve_forever, daemon=True).start()
endpoint = f"http://127.0.0.1:{server.server_port}"
nodebin = Path(shutil.which("node") or "/usr/bin/node").parent
bin = base / "provider-editors/node_modules/.bin"
agent_recorder = None
env = {
    "HOME": str(home), "PATH": f"{nodebin}:/usr/bin:/bin:/usr/sbin:/sbin",
    "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
    "XDG_CONFIG_HOME": str(home / ".config"),
    "XDG_DATA_HOME": str(home / ".local/share"),
    "XDG_CACHE_HOME": str(home / ".cache"),
}
if args.provider == "gemini":
    env.update(GEMINI_API_KEY="fixture-key", GOOGLE_GEMINI_BASE_URL=endpoint,
               GEMINI_CLI_HOME=str(home), NO_COLOR="1")
    config = home / ".gemini"
    config.mkdir()
    (config / "settings.json").write_text(json.dumps({
        "security": {"auth": {"selectedType": "gemini-api-key"}},
        "general": {"disableAutoUpdate": True},
    }))
    command = [str(bin / "gemini"), "--skip-trust", "--screen-reader", "-m", "gemini-2.5-flash"]
    ready = "Type your message"
elif args.provider == "pi":
    agentdir = home / ".pi/agent"
    agentdir.mkdir(parents=True)
    env["PI_CODING_AGENT_DIR"] = str(agentdir)
    (agentdir / "models.json").write_text(json.dumps({"providers": {"fixture": {
        "baseUrl": endpoint + "/v1", "api": "openai-completions", "apiKey": "fixture-key",
        "models": [{"id": "fixture-model", "name": "Fixture", "reasoning": False,
                    "input": ["text"], "contextWindow": 128000, "maxTokens": 4096,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}],
    }}}))
    command = [str(bin / "pi"), "--provider", "fixture", "--model", "fixture-model", "--no-session"]
    ready = "fixture-model"
elif args.provider == "opencode":
    env["OPENCODE_CONFIG_CONTENT"] = json.dumps({
        "model": "fixture/fixture-model", "autoupdate": False,
        "provider": {"fixture": {"npm": "@ai-sdk/openai-compatible", "name": "Fixture",
            "options": {"baseURL": endpoint + "/v1", "apiKey": "fixture-key"},
            "models": {"fixture-model": {"name": "Fixture", "limit": {"context": 128000, "output": 4096}}}}},
    })
    env["OPENCODE_DISABLE_DEFAULT_PLUGINS"] = "true"
    command = [str(bin / "opencode"), "--model", "fixture/fixture-model", str(project)]
    ready = "Ask anything"
elif args.provider == "cursor":
    # Cursor uses HTTP/2 for the agent stream even when its config API uses
    # HTTP/1. Capture the actual Run request without altering the editor.
    recorder_source = r'''
const http2 = require("node:http2");
const fs = require("node:fs");
const zlib = require("node:zlib");
const server = http2.createServer();
server.on("stream", (stream, headers) => {
  const chunks = [];
  stream.on("error", () => {});
  stream.on("data", chunk => {
    chunks.push(chunk);
    const bytes = Buffer.concat(chunks);
    let body = bytes.toString("utf8");
    for (let offset = 0; offset + 5 <= bytes.length;) {
      const flags = bytes[offset];
      const length = bytes.readUInt32BE(offset + 1);
      if (offset + 5 + length > bytes.length) break;
      let message = bytes.subarray(offset + 5, offset + 5 + length);
      if (flags & 1) {
        try { message = zlib.gunzipSync(message); } catch {}
      }
      body += message.toString("utf8");
      offset += 5 + length;
    }
    fs.appendFileSync(process.argv[1], JSON.stringify({path: headers[":path"], body}) + "\n");
  });
  stream.on("end", () => {
    if (!stream.destroyed) {
      stream.respond({":status": 400, "content-type": "application/json"});
      stream.end(JSON.stringify({code: "invalid_argument", message: "Submission captured"}));
    }
  });
});
server.listen(0, "127.0.0.1", () => process.stdout.write(String(server.address().port) + "\n"));
'''
    agent_recorder = subprocess.Popen(
        [str(nodebin / "node"), "-e", recorder_source, str(root / "agent-requests.jsonl")],
        stdout=subprocess.PIPE, text=True,
    )
    agent_endpoint = "http://127.0.0.1:" + agent_recorder.stdout.readline().strip()
    env.update(CI="1", AGENT_CLI_CREDENTIAL_STORE="memory", CURSOR_API_KEY="fixture-key",
               CURSOR_API_ENDPOINT=endpoint, CURSOR_CONFIG_DIR=str(home / ".cursor"))
    command = [str(base / "cursor/cursor-agent"), "--workspace", str(project),
               "--agent-endpoint", agent_endpoint, "--model", "auto", "--trust"]
    ready = "Cursor Agent"
else:
    env.update(GROK_HOME=str(home), XAI_API_KEY="fixture-key", GROK_DISABLE_AUTOUPDATER="1",
               GROK_XAI_API_BASE_URL=endpoint + "/v1")
    (home / "config.toml").write_text(f'''[model.fixture]
model = "fixture-model"
base_url = "{endpoint}/v1"
name = "Fixture"
env_key = "XAI_API_KEY"
[models]
default = "fixture"
''')
    command = [str(base / "grok"), "--cwd", str(project), "--model", "fixture"]
    ready = "Grok"

socket = os.environ["CMUX_SOCKET_PATH"]
identity = call(socket, "system.identify")
assert identity["socket_path"] == socket and socket.startswith("/tmp/cmux-debug-")
launch = shlex.join(["env", "-i", *[f"{k}={v}" for k, v in env.items()], *command])
launch = shlex.join(["/bin/sh", "-c", launch + "; sleep 120"])
workspace = call(socket, "workspace.create", {"initial_command": launch, "working_directory": str(project)})["workspace_id"]
try:
    surfaces = call(socket, "surface.list", {"workspace_id": workspace})["surfaces"]
    surface = surfaces[0]["id"]
    for _ in range(120):
        screen = call(socket, "surface.read_text", {"workspace_id": workspace, "surface_id": surface})
        (root / "startup.json").write_text(json.dumps({"text": screen.get("text", "")}, indent=2))
        if ready.lower() in str(screen).lower():
            break
        time.sleep(0.5)
    else:
        raise AssertionError(f"{args.provider} did not reach its prompt; see {root}/startup.json")
    text = "cmux-reply-" + str(uuid.uuid4())
    if args.multiline:
        text += "\nSecond line 🧪"
    result = call(socket, "mobile.terminal.paste", {
        "workspace_id": workspace, "surface_id": surface, "text": text,
        "submit_key": "return",
    })
    assert result.get("submitted") is True, result
    for _ in range(100):
        model_requests = requests
        if args.provider == "cursor":
            path = root / "agent-requests.jsonl"
            model_requests = []
            if path.exists():
                for line in path.read_text().splitlines():
                    try:
                        model_requests.append(json.loads(line))
                    except ValueError:
                        pass  # The recorder may still be appending the last line.
        if any(text in json.dumps(r["body"], ensure_ascii=False).replace("\\n", "\n")
               and any(method in r["path"] for method in
                       ("/chat/completions", "/responses", ":streamGenerateContent", "/Run"))
               for r in model_requests):
            print(f"PASS {args.provider} {'multiline' if args.multiline else 'single-line'}: exact prompt reached model HTTP request")
            break
        screen = call(socket, "surface.read_text", {"workspace_id": workspace, "surface_id": surface})
        (root / "after-submit.json").write_text(json.dumps({"text": screen.get("text", "")}, indent=2))
        time.sleep(0.2)
    else:
        raise AssertionError(f"{args.provider} did not submit; see {root}")
finally:
    call(socket, "workspace.close", {"workspace_id": workspace})
    if agent_recorder is not None:
        agent_recorder.terminate()
        agent_recorder.wait(timeout=5)
    server.shutdown()
