import Foundation

/// Thin phone / peer UI served by the Mac node. No Pi, no models — API only.
enum MobileWebClient {
    static let html: String = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"/>
<meta name="apple-mobile-web-app-capable" content="yes"/>
<title>Coffee &amp; Pi</title>
<style>
  :root {
    --bg: #1A1412; --panel: #241C19; --composer: #2E241F;
    --text: #F5E8D6; --muted: rgba(230,209,179,.55); --accent: #D9AD73; --border: rgba(230,209,179,.12);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; font: 16px/1.45 -apple-system, system-ui, sans-serif;
    background: var(--bg); color: var(--text); min-height: 100dvh;
    display: flex; flex-direction: column;
  }
  header {
    padding: 14px 16px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 10px; background: var(--panel);
  }
  header h1 { font-size: 15px; font-weight: 600; margin: 0; flex: 1; }
  header button, .btn {
    background: var(--composer); color: var(--text); border: 1px solid var(--border);
    border-radius: 10px; padding: 8px 12px; font-size: 13px; font-weight: 600;
  }
  header button.primary, .btn.primary { background: var(--accent); color: #1A1412; border: none; }
  main { flex: 1; overflow: auto; padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .card {
    background: var(--panel); border: 1px solid var(--border); border-radius: 14px; padding: 14px;
  }
  .muted { color: var(--muted); font-size: 13px; }
  input, textarea {
    width: 100%; background: var(--composer); color: var(--text);
    border: 1px solid var(--border); border-radius: 12px; padding: 12px; font: inherit;
  }
  textarea { min-height: 72px; resize: vertical; }
  .msg { padding: 10px 12px; border-radius: 12px; background: var(--composer); white-space: pre-wrap; }
  .msg.user { background: #3C2B21; }
  .msg.err { color: #f88; }
  .row { display: flex; gap: 8px; align-items: center; }
  .row > * { flex: 1; }
  .chat-item { cursor: pointer; padding: 10px 0; border-bottom: 1px solid var(--border); }
  .chat-item:last-child { border-bottom: none; }
  footer {
    padding: 12px 16px calc(12px + env(safe-area-inset-bottom));
    border-top: 1px solid var(--border); background: var(--panel);
  }
  .hidden { display: none !important; }
</style>
</head>
<body>
<header>
  <h1 id="title">Coffee &amp; Pi</h1>
  <button id="backBtn" class="hidden" type="button">Chats</button>
</header>
<main id="pairPane" class="card">
  <p style="margin-top:0"><strong>Pair with your Mac</strong></p>
  <p class="muted">Enter the 6-digit code from Settings → Devices. Models stay on the Mac.</p>
  <input id="code" inputmode="numeric" autocomplete="one-time-code" placeholder="Pair code" maxlength="8"/>
  <input id="deviceName" style="margin-top:8px" placeholder="This device’s name" value="Phone"/>
  <div class="row" style="margin-top:12px">
    <button class="btn primary" type="button" id="pairBtn">Pair</button>
  </div>
  <p id="pairErr" class="muted" style="color:#f88"></p>
</main>
<main id="listPane" class="hidden">
  <div class="row" style="margin-bottom:8px">
    <button class="btn primary" type="button" id="newChatBtn">New chat</button>
  </div>
  <div class="card" id="chatList"></div>
</main>
<main id="chatPane" class="hidden">
  <div id="messages"></div>
</main>
<footer id="composer" class="hidden">
  <div class="row">
    <textarea id="draft" placeholder="Message…" rows="2"></textarea>
    <button class="btn primary" type="button" id="sendBtn" style="flex:0 0 auto">Send</button>
  </div>
</footer>
<script>
(() => {
  const storeKey = "coffeeandpi.token";
  let token = localStorage.getItem(storeKey) || "";
  let chatID = null;
  let ws = null;

  const $ = (id) => document.getElementById(id);
  const show = (id) => { ["pairPane","listPane","chatPane"].forEach(p => $(p).classList.toggle("hidden", p !== id)); };

  function api(path, opts = {}) {
    const headers = Object.assign({"Content-Type":"application/json"}, opts.headers || {});
    if (token) headers.Authorization = "Bearer " + token;
    return fetch(path, Object.assign({}, opts, { headers })).then(async r => {
      const data = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(data.error || r.statusText);
      return data;
    });
  }

  function setAuthed(ok) {
    $("backBtn").classList.toggle("hidden", !ok || !chatID);
    $("composer").classList.toggle("hidden", !ok || !chatID);
    if (!ok) { show("pairPane"); $("title").textContent = "Coffee & Pi"; return; }
    if (chatID) { show("chatPane"); } else { show("listPane"); $("title").textContent = "Chats"; }
  }

  async function pair() {
    $("pairErr").textContent = "";
    try {
      const data = await api("/v1/pair", {
        method: "POST",
        body: JSON.stringify({ code: $("code").value.trim(), deviceName: $("deviceName").value.trim() || "Phone" })
      });
      token = data.access_token || data.token;
      if (!token) throw new Error("no_token");
      localStorage.setItem(storeKey, token);
      chatID = null;
      setAuthed(true);
      await loadChats();
    } catch (e) {
      $("pairErr").textContent = e.message || String(e);
    }
  }

  async function loadChats() {
    const data = await api("/v1/chats");
    const list = $("chatList");
    list.innerHTML = "";
    (data.chats || []).forEach(c => {
      const div = document.createElement("div");
      div.className = "chat-item";
      div.innerHTML = `<div><strong>${escapeHtml(c.title || "Chat")}</strong></div>
        <div class="muted">${escapeHtml(c.preview || "")}</div>`;
      div.onclick = () => openChat(c.id);
      list.appendChild(div);
    });
    if (!(data.chats || []).length) {
      list.innerHTML = `<p class="muted" style="margin:0">No chats yet.</p>`;
    }
  }

  async function newChat() {
    const data = await api("/v1/chats", { method: "POST", body: "{}" });
    await openChat(data.id || data.chat?.id);
  }

  async function openChat(id) {
    chatID = id;
    setAuthed(true);
    $("backBtn").classList.remove("hidden");
    $("composer").classList.remove("hidden");
    await refreshChat();
    connectWS();
  }

  async function refreshChat() {
    if (!chatID) return;
    const data = await api("/v1/chats/" + chatID);
    $("title").textContent = data.title || "Chat";
    renderMessages(data.messages || []);
  }

  function renderMessages(messages) {
    const box = $("messages");
    box.innerHTML = "";
    messages.forEach(m => {
      const div = document.createElement("div");
      div.className = "msg" + (m.role === "user" ? " user" : "") + (m.isError ? " err" : "");
      div.textContent = m.text || (m.isStreaming ? "…" : "");
      box.appendChild(div);
    });
    box.lastChild?.scrollIntoView({ behavior: "smooth", block: "end" });
  }

  function connectWS() {
    if (ws) { try { ws.close(); } catch (_) {} }
    const proto = location.protocol === "https:" ? "wss" : "ws";
    ws = new WebSocket(`${proto}://${location.host}/v1/ws?token=${encodeURIComponent(token)}`);
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: "subscribe", chatID }));
    };
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.type === "chat" && msg.chat) {
          $("title").textContent = msg.chat.title || "Chat";
          renderMessages(msg.chat.messages || []);
        }
      } catch (_) {}
    };
  }

  async function send() {
    const text = $("draft").value.trim();
    if (!text || !chatID) return;
    $("draft").value = "";
    await api("/v1/chats/" + chatID + "/messages", {
      method: "POST",
      body: JSON.stringify({ text })
    });
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
  }

  $("pairBtn").onclick = pair;
  $("newChatBtn").onclick = () => newChat().catch(e => alert(e.message));
  $("sendBtn").onclick = () => send().catch(e => alert(e.message));
  $("backBtn").onclick = () => {
    chatID = null;
    if (ws) { try { ws.close(); } catch (_) {} }
    setAuthed(true);
    loadChats().catch(e => alert(e.message));
  };
  $("draft").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send().catch(err => alert(err.message)); }
  });

  if (token) {
    setAuthed(true);
    loadChats().catch(() => {
      token = "";
      localStorage.removeItem(storeKey);
      setAuthed(false);
    });
  } else {
    setAuthed(false);
  }
})();
</script>
</body>
</html>
"""#
}
