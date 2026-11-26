# The in-flight turn of a terminal Claude Code session, as its transcript grows: a user prompt, then an
# assistant line every 150 ms (printed here too), until STOP exists; then a closing answer and the Stop hook.
import json, os, subprocess, sys, time, uuid
path, cwd, sid, stop = sys.argv[1:5]


def hook(event, extra=None):
    payload = {"session_id": sid, **(extra or {})}
    subprocess.run(["cmux", "agent", "hook", "emit", "--source", "claude", "--event", event,
                    "--payload-json", json.dumps(payload)], check=False)


parent = [None]


def put(kind, message):
    u = str(uuid.uuid4())
    line = {"type": kind, "uuid": u, "parentUuid": parent[0], "sessionId": sid, "cwd": cwd,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()), "message": message}
    parent[0] = u
    with open(path, "a") as f:
        f.write(json.dumps(line) + "\n")


prompt = "Turn 2000: a live turn while the view swaps"
hook("UserPromptSubmit", {"prompt": prompt})
put("user", {"role": "user", "content": prompt})
k = 0
while not os.path.exists(stop) and k < 4000:
    k += 1
    text = "Live %d: streaming while the view swaps" % k
    put("assistant", {"id": "msg_live_%d" % k, "type": "message", "role": "assistant", "model": "claude-opus-5-5",
                      "content": [{"type": "text", "text": text}], "stop_reason": None})
    print(text, flush=True)
    time.sleep(0.15)
put("assistant", {"id": "msg_live_done", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
                  "content": [{"type": "text", "text": "Live done after %d" % k}], "stop_reason": "end_turn"})
hook("Stop")
print("LIVE-DONE %d" % k, flush=True)
