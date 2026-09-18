// Runs before Tinymist's bundled scripts, in the preview page itself.
(() => {
  const { upstream, origin, token } = window.__typstBridge;
  const endpoint = (path) => `${origin}${path}${path.includes("?") ? "&" : "?"}t=${encodeURIComponent(token)}`;
  const events = new EventSource(endpoint("/__live/events"));
  const sockets = new Set();
  let ended = false, announced = false, status;
  const positions = new Map();
  const hooked = new WeakSet();
  let bufferId, restoring;
  let latestOutline;
  let cursorLine = -1;
  const scroller = () => document.getElementById("typst-container-main");

  function setupOutline() {
    if (document.getElementById("typst-outline")) return;
    const dialog = document.createElement("dialog");
    dialog.id = "typst-outline"; dialog.setAttribute("aria-label", "Document outline");
    dialog.innerHTML = "<nav></nav>";
    dialog.onclick = event => { if (event.target === dialog) dialog.close(); };
    const menu = document.createElement("div");
    menu.id = "typst-context-menu";
    menu.hidden = true;
    menu.innerHTML = "<button data-action=copy>Copy</button><button data-action=refresh>Refresh</button><button data-action=outline>Outline</button>";
    document.body.append(dialog, menu);
    const closeMenu = () => { menu.hidden = true; };
    document.addEventListener("contextmenu", event => {
      event.preventDefault();
      menu.hidden = false;
      menu.style.left = `${Math.min(event.clientX, innerWidth - menu.offsetWidth - 8)}px`;
      menu.style.top = `${Math.min(event.clientY, innerHeight - menu.offsetHeight - 8)}px`;
    });
    document.addEventListener("pointerdown", event => {
      if (!menu.hidden && !event.target.closest("#typst-context-menu")) closeMenu();
    });
    menu.addEventListener("click", async event => {
      const action = event.target.closest("button")?.dataset.action;
      if (!action) return;
      closeMenu();
      if (action === "refresh") return location.reload();
      if (action === "outline") {
        dialog.showModal();
        return;
      }
      const selected = getSelection()?.toString() || "";
      if (!selected) return;
      const text = selected
        .replace(/\r\n?/g, "\n")
        .split(/\n\s*\n/)
        .map(block => block.replace(/\s*\n\s*/g, " ").replace(/[ \t]{2,}/g, " ").trim())
        .filter(Boolean)
        .join("\n\n");
      await navigator.clipboard?.writeText(text);
    });
    window.addEventListener("typst-outline", event => {
      const nav = dialog.querySelector("nav"); nav.replaceChildren();
      const flatten = (items, level = 0) => (items || []).flatMap(item => [
        { ...item, level }, ...flatten(item.children, level + 1),
      ]);
      const items = flatten(event.detail?.symbols || []).filter(item => item.isHeading === true);
      if (!items.length) {
        const empty = document.createElement("div");
        empty.textContent = "No headings";
        empty.style.cssText = "padding:10px 8px;color:#57606a";
        nav.append(empty);
      }
      items.forEach(item => {
        const range = item.range || item.selectionRange;
        const line = range?.start?.line;
        if (typeof line !== "number" || !item.name) return;
        const button = document.createElement("button");
        button.textContent = item.name; button.style.setProperty("--outline-level", item.level);
        button.dataset.line = String(line);
        button.onclick = () => { fetch(endpoint("/__live/event?event=typst-outline-jump&data=" + encodeURIComponent(JSON.stringify({ line })))).catch(console.error); dialog.close(); };
        nav.append(button);
      });
      updateOutlineActive();
    });
    if (latestOutline) window.dispatchEvent(new CustomEvent("typst-outline", { detail: latestOutline }));
  }

  function remember() {
    const el = scroller();
    if (bufferId && restoring === undefined && el) positions.set(bufferId, el.scrollTop);
  }

  function restore() {
    if (restoring !== undefined) scroller()?.scrollTo({ top: restoring, behavior: "instant" });
  }

  // Tinymist exposes document instances on its container. Reapply the saved
  // offset after layout; suppress source jumps until the user moves again.
  function hookDocuments() {
    const container = document.getElementById("typst-container");
    if (!container) return;
    for (const doc of container.documents || []) {
      if (hooked.has(doc) || typeof doc.impl?.r?.postRender !== "function") continue;
      hooked.add(doc);
      const renderer = doc.impl.r, postRender = renderer.postRender;
      renderer.postRender = function (...args) {
        const result = postRender.apply(this, args);
        hookDocuments();
        restore();
        return result;
      };
    }
    if (!hooked.has(container) && typeof container.handleTypstLocation === "function") {
      hooked.add(container);
      const jump = container.handleTypstLocation;
      container.handleTypstLocation = function (...args) {
        fetch(endpoint("/__live/event?event=typst-preview-jump")).catch(console.error);
        if (restoring === undefined) return jump.apply(this, args);
      };
    }
  }

  function follow() { restoring = undefined; }
  window.addEventListener("scroll", remember, { capture: true, passive: true });
  for (const event of ["wheel", "touchstart", "pointerdown", "keydown"]) {
    window.addEventListener(event, follow, { capture: true, passive: true });
  }

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
        hookDocuments();
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
    setupOutline();
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
  events.addEventListener("typst-buffer", (event) => {
    try {
      const value = JSON.parse(event.data);
      if (typeof value.id !== "string") return;
      document.title = value.title;
      if (bufferId === value.id) return;
      remember();
      bufferId = value.id;
      restoring = positions.get(bufferId);
      hookDocuments();
      restore();
    } catch (error) { console.error(error); }
  });
  events.addEventListener("typst-follow", follow);
  events.addEventListener("typst-outline", event => {
    try {
      latestOutline = JSON.parse(event.data);
      window.dispatchEvent(new CustomEvent("typst-outline", { detail: latestOutline }));
    }
    catch (error) { console.error(error); }
  });
  function updateOutlineActive() {
    const buttons = document.querySelectorAll("#typst-outline button[data-line]");
    let active;
    buttons.forEach(button => {
      if (Number(button.dataset.line) <= cursorLine) active = button;
      button.classList.remove("is-active");
    });
    active?.classList.add("is-active");
    if (active && document.getElementById("typst-outline")?.open) active.scrollIntoView({ block: "nearest" });
  }
  events.addEventListener("typst-cursor", event => {
    try { cursorLine = JSON.parse(event.data).line; updateOutlineActive(); }
    catch (error) { console.error(error); }
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
