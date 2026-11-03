// The Voice Room page: a WebRTC mesh (one peer connection per other person, perfect
// negotiation), the live transcript, the room's memory and its tasks. Media goes browser to
// browser over the tailnet; the server only relays signals.

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const name = params.get("name") || "";
const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws?name=${encodeURIComponent(name)}`);

let me = null;
let local = null;
let screen = null;
const peers = new Map(); // id -> { pc, polite, makingOffer, ignoreOffer, tile }
let roster = [];
let paused = false;

function send(message) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
}

function showError(message) {
  const el = $("error");
  el.textContent = message;
  el.hidden = !message;
  if (message) setTimeout(() => (el.hidden = true), 8000);
}

async function startMedia() {
  const audio = { echoCancellation: true, noiseSuppression: true, autoGainControl: true };
  try {
    local = await navigator.mediaDevices.getUserMedia({ audio, video: { width: 640, height: 400, frameRate: 15 } });
  } catch {
    try {
      local = await navigator.mediaDevices.getUserMedia({ audio });
    } catch (error) {
      local = new MediaStream();
      showError(`No mic or camera: ${error.message}. You can still read and send tasks.`);
    }
  }
  tile("me", "You", local, true);
}

function tile(id, label, stream, mutedPlayback, owner = id) {
  let el = document.querySelector(`[data-peer="${id}"]`);
  if (!el) {
    el = document.createElement("div");
    el.className = "tile";
    el.dataset.peer = id;
    el.dataset.owner = owner;
    el.innerHTML = `<video autoplay playsinline></video><span class="name"></span>`;
    $("tiles").append(el);
  }
  el.querySelector(".name").textContent = label;
  const video = el.querySelector("video");
  video.muted = !!mutedPlayback;
  if (stream && video.srcObject !== stream) video.srcObject = stream;
  return el;
}

function aiTile() {
  const el = document.createElement("div");
  el.className = "tile ai";
  el.dataset.peer = "ai";
  el.innerHTML = `<div>Chief is listening</div><span class="name">Chief (AI)</span>`;
  $("tiles").append(el);
}

function connection(id) {
  if (peers.has(id)) return peers.get(id);
  // No ICE servers: every peer is on the tailnet, so its 100.x host candidate is reachable.
  const pc = new RTCPeerConnection({ iceServers: [] });
  const state = { pc, polite: me.id < id, makingOffer: false, ignoreOffer: false };
  peers.set(id, state);
  for (const track of local.getTracks()) pc.addTrack(track, local);
  if (screen) for (const track of screen.getTracks()) pc.addTrack(track, screen);
  pc.onicecandidate = ({ candidate }) => candidate && send({ t: "signal", to: id, data: { candidate } });
  pc.onnegotiationneeded = async () => {
    try {
      state.makingOffer = true;
      await pc.setLocalDescription();
      send({ t: "signal", to: id, data: { description: pc.localDescription } });
    } catch (error) {
      showError(`Call setup: ${error.message}`);
    } finally {
      state.makingOffer = false;
    }
  };
  pc.ontrack = ({ streams }) => {
    const peer = roster.find((p) => p.id === id);
    // The first stream a peer sends is its camera and mic; a later one is its screen.
    for (const stream of streams) {
      state.streams ??= [];
      if (!state.streams.includes(stream.id)) state.streams.push(stream.id);
      const first = state.streams[0] === stream.id;
      tile(first ? id : `${id}-${stream.id}`, first ? (peer?.name ?? id) : `${peer?.name ?? id}'s screen`, stream, false, id);
    }
  };
  pc.onconnectionstatechange = () => {
    if (pc.connectionState === "failed") pc.restartIce();
  };
  return state;
}

async function onSignal(from, data) {
  const state = connection(from);
  const { pc } = state;
  if (data.description) {
    const collision = data.description.type === "offer" && (state.makingOffer || pc.signalingState !== "stable");
    state.ignoreOffer = !state.polite && collision;
    if (state.ignoreOffer) return;
    await pc.setRemoteDescription(data.description);
    if (data.description.type === "offer") {
      await pc.setLocalDescription();
      send({ t: "signal", to: from, data: { description: pc.localDescription } });
    }
  } else if (data.candidate) {
    try {
      await pc.addIceCandidate(data.candidate);
    } catch (error) {
      if (!state.ignoreOffer) throw error;
    }
  }
}

function syncPeers(list) {
  roster = list;
  for (const peer of list) if (peer.id !== me.id) connection(peer.id);
  for (const [id, state] of peers) {
    if (!list.some((peer) => peer.id === id)) {
      state.pc.close();
      peers.delete(id);
      document.querySelectorAll(`[data-owner="${id}"]`).forEach((el) => el.remove());
    }
  }
}

function renderEntry(entry) {
  if (entry.kind === "join") return;
  const li = document.createElement("li");
  li.dataset.entry = entry.id;
  if (entry.kind === "screen") li.className = "screen";
  const who = document.createElement("span");
  who.className = "who";
  who.textContent = entry.kind === "screen" ? `${entry.speaker}'s screen:` : `${entry.speaker}:`;
  li.append(who, document.createTextNode(entry.kind === "screen" ? entry.text.slice(0, 160) : entry.text));
  const list = $("transcript");
  const atEnd = list.scrollTop + list.clientHeight >= list.scrollHeight - 8;
  list.append(li);
  // Follow the newest line only when the reader is already at the end.
  if (atEnd) list.scrollTop = list.scrollHeight;
}

function renderTasks(tasks) {
  const list = $("tasks");
  list.replaceChildren(
    ...tasks
      .filter((task) => task.state !== "dismissed")
      .map((task) => {
        const li = document.createElement("li");
        const state = document.createElement("span");
        state.className = "state";
        state.textContent = { proposed: "Proposed", sent: "Sent to Chief", failed: "Failed" }[task.state] ?? task.state;
        const title = document.createElement("strong");
        title.textContent = task.title;
        const ask = document.createElement("div");
        ask.textContent = task.ask;
        const quote = document.createElement("div");
        quote.className = "quote";
        quote.textContent = `${task.speaker}: "${task.quote}"`;
        li.append(state, title, ask, quote);
        if (task.error) {
          const error = document.createElement("div");
          error.textContent = task.error;
          li.append(error);
        }
        if (task.state === "proposed" || task.state === "failed") {
          const go = document.createElement("button");
          go.textContent = "Send to Chief";
          go.onclick = () => send({ t: "task.send", id: task.id });
          const drop = document.createElement("button");
          drop.textContent = "Dismiss";
          drop.onclick = () => send({ t: "task.dismiss", id: task.id });
          li.append(go, drop);
        }
        return li;
      }),
  );
}

function renderUsage(usage) {
  if (!usage) return;
  $("cost").textContent = `Model: $${usage.costUSD.toFixed(4)} (${usage.calls} calls, ≈$${usage.costPerHourUSD.toFixed(2)}/h)`;
}

function setPaused(on) {
  paused = on;
  document.body.classList.toggle("paused", on);
  $("recLabel").textContent = on ? "Paused" : "Recording";
  $("pause").textContent = on ? "Resume recording" : "Pause recording";
  $("pause").setAttribute("aria-pressed", String(on));
  if (on) recognition?.stop();
  else if ($("browserStt").checked) startRecognition();
}

// Optional browser transcription (off by default: Chrome's sends audio to Google). The cmux
// app transcribes on device and posts lines itself.
let recognition = null;
function startRecognition() {
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Recognition) return showError("This browser has no speech recognition.");
  recognition = new Recognition();
  recognition.continuous = true;
  recognition.interimResults = false;
  recognition.onresult = (event) => {
    for (let i = event.resultIndex; i < event.results.length; i += 1) {
      if (event.results[i].isFinal) send({ t: "speech", text: event.results[i][0].transcript, level: 0.5 });
    }
  };
  recognition.onend = () => {
    if ($("browserStt").checked && !paused) recognition.start();
  };
  recognition.start();
}

ws.onmessage = async ({ data }) => {
  const message = JSON.parse(data);
  switch (message.t) {
    case "welcome":
      me = message.you;
      // The room shows at once; the camera and mic prompt must not hold it back.
      aiTile();
      message.entries.forEach(renderEntry);
      renderTasks(message.tasks);
      $("memory").textContent = message.view;
      renderUsage(message.usage);
      setPaused(message.paused);
      await startMedia();
      syncPeers(message.peers);
      break;
    case "peers":
      if (me && local) syncPeers(message.peers);
      break;
    case "signal":
      await onSignal(message.from, message.data).catch((error) => showError(`Call: ${error.message}`));
      break;
    case "entry":
      renderEntry(message.entry);
      break;
    case "reattribute": {
      const who = document.querySelector(`[data-entry="${message.id}"] .who`);
      if (who) who.textContent = `${message.speaker}:`;
      break;
    }
    case "tasks":
      renderTasks(message.tasks);
      break;
    case "view":
      $("memory").textContent = message.view;
      renderUsage(message.usage);
      break;
    case "paused":
      setPaused(message.paused);
      break;
    case "error":
      showError(message.message);
      break;
  }
};
ws.onclose = () => showError("Disconnected from the room. Reload to join again.");

$("mic").onclick = () => {
  const track = local?.getAudioTracks()[0];
  if (!track) return;
  track.enabled = !track.enabled;
  $("mic").textContent = track.enabled ? "Mute" : "Unmute";
  $("mic").setAttribute("aria-pressed", String(!track.enabled));
  send({ t: "state", muted: !track.enabled });
};
$("cam").onclick = () => {
  const track = local?.getVideoTracks()[0];
  if (!track) return;
  track.enabled = !track.enabled;
  $("cam").textContent = track.enabled ? "Camera off" : "Camera on";
  send({ t: "state", camera: track.enabled });
};
$("share").onclick = async () => {
  if (screen) {
    screen.getTracks().forEach((track) => track.stop());
    for (const { pc } of peers.values()) {
      for (const sender of pc.getSenders()) if (sender.track && sender.track.kind === "video" && !local.getTracks().includes(sender.track)) pc.removeTrack(sender);
    }
    screen = null;
    $("share").textContent = "Share screen";
    document.querySelector('[data-peer="me-screen"]')?.remove();
    send({ t: "state", sharing: false });
    return;
  }
  try {
    screen = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: 5 }, audio: false });
  } catch {
    return;
  }
  tile("me-screen", "Your screen", screen, true);
  for (const { pc } of peers.values()) for (const track of screen.getTracks()) pc.addTrack(track, screen);
  screen.getVideoTracks()[0].onended = () => screen && $("share").click();
  $("share").textContent = "Stop sharing";
  send({ t: "state", sharing: true });
};
$("pause").onclick = () => send({ t: "pause", on: !paused });
$("browserStt").onchange = (event) => (event.target.checked ? startRecognition() : recognition?.stop());
document.addEventListener("keydown", (event) => {
  if (event.ctrlKey && event.altKey && event.code === "KeyP") {
    event.preventDefault();
    $("pause").click();
  }
});
