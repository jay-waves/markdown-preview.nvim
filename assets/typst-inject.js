// Runs before Tinymist's bundled scripts. No renderer fork or extra connection.
(() => {
  const { upstream, origin } = window.__typstBridge;
  const channel = "nvim-typst-preview";
  const emit = (type, data = {}) => parent.postMessage({ channel, type, ...data }, origin);
  const NativeWebSocket = window.WebSocket;
  window.WebSocket = class extends NativeWebSocket {
    constructor(url, protocols) {
      const target = new URL(url, upstream);
      // Bundled versions may derive the socket address from location instead
      // of <base>. Only remap this wrapper's own address.
      if (target.host === location.host) target.host = new URL(upstream).host;
      if (target.protocol === "http:") target.protocol = "ws:";
      if (target.protocol === "https:") target.protocol = "wss:";
      super(target.href, ...(protocols === undefined ? [] : [protocols]));
      this.addEventListener("open", () => emit("connection", { connected: true }));
      this.addEventListener("close", () => emit("connection", { connected: false }));
    }
  };
  window.addEventListener("DOMContentLoaded", () => emit("ready"), { once: true });
})();
