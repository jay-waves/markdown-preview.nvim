// Runs before Tinymist's bundled scripts, in the preview page itself.
(() => {
  const { upstream, origin, token } = window.__typstBridge;
  const endpoint = (path) => `${origin}${path}${path.includes("?") ? "&" : "?"}t=${encodeURIComponent(token)}`;
  const events = new EventSource(endpoint("/__live/events"));
  const sockets = new Set();
  let ended = false, announced = false, status;

  function renderStatus() {
    if (!status) return;
    const text = ended ? "Preview ended. You can close this tab."
      : events.readyState !== EventSource.OPEN ? "Neovim disconnected. Waiting to reconnect…"
      : sockets.size === 0 ? "Waiting for Tinymist preview…" : "";
    status.textContent = text;
    status.hidden = !text;
  }

  // Only readiness crosses back to Lua; all cursor scheduling stays in Neovim.
  function connected() {
    renderStatus();
    if (!ended && !announced && sockets.size && events.readyState === EventSource.OPEN) {
      announced = true;
      fetch(endpoint("/__live/event?event=typst-connected")).catch(console.error);
    }
  }

  const NativeWebSocket = window.WebSocket;
  window.WebSocket = class extends NativeWebSocket {
    constructor(url, protocols) {
      const target = new URL(url, upstream);
      if (target.host === location.host) target.host = new URL(upstream).host;
      if (target.protocol === "http:") target.protocol = "ws:";
      if (target.protocol === "https:") target.protocol = "wss:";
      super(target.href, ...(protocols === undefined ? [] : [protocols]));
      this.addEventListener("open", () => {
        if (ended) { this.close(); return; }
        sockets.add(this);
        connected();
      });
      this.addEventListener("close", () => {
        sockets.delete(this);
        if (!sockets.size) announced = false;
        renderStatus();
      });
    }
  };

  window.addEventListener("DOMContentLoaded", () => {
    // Isolate the status styling from Tinymist's own stylesheet.
    const host = document.createElement("div");
    host.style.cssText = "position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:2147483647";
    const shadow = host.attachShadow({ mode: "closed" });
    status = document.createElement("div");
    status.setAttribute("role", "status");
    status.style.cssText = "font:15px system-ui;padding:10px 16px;border-radius:6px;background:Canvas;color:CanvasText;box-shadow:0 2px 12px #0003;color-scheme:light dark";
    shadow.append(status);
    document.body.append(host);
    renderStatus();
  }, { once: true });

  events.onopen = connected;
  events.onerror = () => { announced = false; renderStatus(); };
  events.addEventListener("typst-title", (event) => {
    try { document.title = JSON.parse(event.data); } catch (_) {}
  });
  events.addEventListener("typst-close", () => {
    if (ended) return;
    ended = true;
    events.close();
    for (const socket of sockets) socket.close();
    window.close();
    renderStatus();
  });
  window.addEventListener("pagehide", () => events.close());
  window.addEventListener("pageshow", (event) => { if (event.persisted && !ended) location.reload(); });
})();
