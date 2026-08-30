(function () {
    'use strict';

    const root = document.documentElement;
    const BOTTOM_PADDING = parseFloat(root.dataset.bottomPadding) || 0.5;

    // Live-reload auth token. It may be baked into loopback previews or
    // supplied in the initial URL for remote previews.
    const LIVE_TOKEN = (() => {
        const fromAttr = root.dataset.liveToken || '';
        if (fromAttr && fromAttr !== '__LIVE' + '_TOKEN__') {
            try { sessionStorage.setItem('mdp-token', fromAttr); } catch (_) {}
            return fromAttr;
        }
        const fromUrl = new URLSearchParams(location.search).get('t');
        if (fromUrl) {
            try { sessionStorage.setItem('mdp-token', fromUrl); } catch (_) {}
            return fromUrl;
        }
        try { return sessionStorage.getItem('mdp-token') || ''; } catch (_) { return ''; }
    })();

    const withToken = (url) => {
        if (!LIVE_TOKEN) return url;
        return url + (url.indexOf('?') >= 0 ? '&' : '?') + 't=' + encodeURIComponent(LIVE_TOKEN);
    };

    const CLICK_TO_NVIM = root.dataset.clickToNvim === 'true';
    const CLICK_PORT = root.dataset.clickPort || '';
    let lastContent = null;
    let assetPrefix = '';
    let scrollSyncPaused = false;
    let scrollSyncPauseTimer = null;
    let lastScrollData = null;
    let lastInitialScrollId = null;
    let started = false;

    function pauseScrollSync() {
        scrollSyncPaused = true;
        clearTimeout(scrollSyncPauseTimer);
        scrollSyncPauseTimer = setTimeout(() => { scrollSyncPaused = false; }, 3000);
    }

    async function fetchAssetPrefix() {
        const previous = assetPrefix;
        try {
            const resp = await fetch(withToken('/asset_prefix'), { cache: 'no-store' });
            assetPrefix = resp.ok ? (await resp.text()).trim().replace(/\\/g, '/') : '';
        } catch (_) {
            assetPrefix = '';
        }
        return assetPrefix !== previous;
    }

    function resolveRelativeAssetPath(src, prefix) {
        const sentinel = '/__markdown_preview_asset_root__/';
        const encodedPrefix = prefix
            .split('/')
            .filter(Boolean)
            .map(segment => encodeURIComponent(segment))
            .join('/');
        const base = new URL(sentinel + (encodedPrefix ? encodedPrefix + '/' : ''), location.origin);
        const resolved = new URL(src, base);
        if (resolved.origin !== location.origin || !resolved.pathname.startsWith(sentinel)) {
            throw new Error('relative asset path escapes :pwd');
        }
        return decodeURIComponent(resolved.pathname.slice(sentinel.length));
    }

    function rewriteRelativeImages(rootEl) {
        rootEl.querySelectorAll('img[src]').forEach(img => {
            const src = img.getAttribute('src');
            if (!src || /^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|\/\/|\/|#)/.test(src)) return;
            try {
                const assetPath = resolveRelativeAssetPath(src, assetPrefix);
                img.setAttribute('src', withToken('/__live/asset?p=' + encodeURIComponent(assetPath)));
            } catch (error) {
                console.warn('[markdown-preview] invalid relative image URL:', src, error);
                img.removeAttribute('src');
                img.setAttribute('data-invalid-src', src);
            }
        });
    }

    async function fetchContent() {
        try {
            const resp = await fetch(withToken('content.md?ts=' + Date.now()), { cache: 'no-store' });
            if (!resp.ok) {
                console.warn('[markdown-preview] content.md fetch failed:', resp.status);
                if (resp.status === 401) {
                    try { sessionStorage.removeItem('mdp-token'); } catch (_) {}
                }
                return null;
            }
            return (await resp.text()).replace(/\r\n?/g, '\n');
        } catch (error) {
            console.warn('[markdown-preview] content.md fetch error:', error);
            return null;
        }
    }

    async function sync(core, initial = false) {
        const text = await fetchContent();
        if (text == null) return;
        const assetPrefixChanged = await fetchAssetPrefix();
        if (!initial && text === lastContent && !assetPrefixChanged) return;
        lastContent = text;

        try {
            const html = core.renderToHtml(text);
            core.showContent();

            if (window.morphdom) {
                const wrapper = document.createElement('div');
                wrapper.id = 'content';
                wrapper.innerHTML = html;
                rewriteRelativeImages(wrapper);

                window.morphdom(core.contentElement, wrapper, {
                    childrenOnly: false,
                    getNodeKey(node) {
                        if (node.nodeType === 1) {
                            if (node.getAttribute && node.getAttribute('data-graph') === 'mermaid') {
                                return node.id;
                            }
                            return node.id || null;
                        }
                        return null;
                    },
                    onBeforeElUpdated(fromEl, toEl) {
                        if (fromEl.classList && fromEl.classList.contains('mermaid-rendered') &&
                            fromEl.dataset.mermaidSource === toEl.dataset.mermaidSource) {
                            return false;
                        }
                        if (fromEl.tagName === 'DETAILS' && fromEl.hasAttribute('open')) {
                            toEl.setAttribute('open', '');
                        }
                        return true;
                    },
                });
            } else {
                core.contentElement.innerHTML = html;
                rewriteRelativeImages(core.contentElement);
            }

            applyBottomPadding(core.contentElement);
            await core.renderMermaid();
            await applyInitialScroll(core.contentElement);
        } catch (error) {
            console.error('[markdown-preview] render error:', error);
            core.contentElement.innerHTML = '<pre style="white-space:pre-wrap;padding:1rem">' +
                text.replace(/&/g, '&amp;').replace(/</g, '&lt;') + '</pre>';
        }
    }

    function getElementOffset(el) {
        let current = el;
        let top = 0;
        while (top === 0 && current) {
            top = current.getBoundingClientRect().top;
            current = current.parentElement;
        }
        return top + window.scrollY;
    }

    function scrollToSourceLine(contentEl, line, total) {
        const elements = contentEl.querySelectorAll('[data-source-line]');
        if (!elements.length) return;
        if (line <= 0) { window.scrollTo({ top: 0 }); return; }
        if (line >= total - 1) {
            window.scrollTo({ top: document.documentElement.scrollHeight });
            return;
        }

        let prev = null;
        let next = null;
        for (const el of elements) {
            const elLine = Number(el.dataset.sourceLine);
            if (elLine <= line) prev = { el, line: elLine };
            else { next = { el, line: elLine }; break; }
        }
        if (!prev) { window.scrollTo({ top: 0 }); return; }

        const prevTop = getElementOffset(prev.el);
        let offsetTop;
        if (next) {
            const nextTop = getElementOffset(next.el);
            const ratio = (line - prev.line) / (next.line - prev.line);
            offsetTop = prevTop + (nextTop - prevTop) * ratio;
        } else {
            const height = prev.el.getBoundingClientRect().height;
            const linesLeft = Math.max(1, total - prev.line);
            offsetTop = prevTop + (line - prev.line) * (height / linesLeft);
        }
        window.scrollTo({ top: Math.max(0, offsetTop - window.innerHeight / 2) });
    }

    async function applyInitialScroll(contentEl) {
        try {
            const resp = await fetch(withToken('/initial_scroll'), { cache: 'no-store' });
            if (!resp.ok) return;
            const text = (await resp.text()).trim();
            if (!text) return;
            const data = JSON.parse(text);
            if (!data.id || data.id === lastInitialScrollId || data.line == null) return;
            lastInitialScrollId = data.id;
            scrollToSourceLine(contentEl, data.line, data.total || 1);
        } catch (_) {}
    }

    function connectSSE(core) {
        const evtSource = new EventSource(withToken('/__live/events'));
        evtSource.addEventListener('reload', () => sync(core, false));
        evtSource.addEventListener('scroll', event => {
            if (scrollSyncPaused) return;
            try {
                const data = JSON.parse(event.data);
                if (data.line == null) return;
                lastScrollData = data;
                scrollToSourceLine(core.contentElement, data.line, data.total || 1);
            } catch (_) {}
        });
        evtSource.addEventListener('open', () => {
            console.log('[markdown-preview] SSE connected');
        });
        return evtSource;
    }

    function applyBottomPadding(contentEl) {
        contentEl.style.paddingBottom = `${(1 - BOTTOM_PADDING) * window.innerHeight}px`;
    }

    async function start(core) {
        if (started) return;
        started = true;
        window.addEventListener('wheel', pauseScrollSync, { passive: true });
        window.addEventListener('touchmove', pauseScrollSync, { passive: true });
        window.addEventListener('resize', () => applyBottomPadding(core.contentElement));

        core.contentElement.addEventListener('click', event => {
            if (!CLICK_TO_NVIM || !CLICK_PORT) return;
            if (event.target.closest('a, button, input, select, textarea, summary')) return;
            const block = event.target.closest('[data-source-line]');
            if (!block) return;
            const line = Number(block.dataset.sourceLine);
            if (!Number.isInteger(line) || line < 0) return;
            const url = `${location.protocol}//${location.hostname}:${CLICK_PORT}` +
                `/__markdown_preview/click?line=${line}&t=${encodeURIComponent(LIVE_TOKEN)}`;
            fetch(url, { mode: 'no-cors', cache: 'no-store', keepalive: true }).catch(() => {});
        });

        new ResizeObserver(() => {
            if (lastScrollData && !scrollSyncPaused) {
                scrollToSourceLine(core.contentElement, lastScrollData.line, lastScrollData.total || 1);
            }
        }).observe(core.contentElement);

        await sync(core, true);
        connectSSE(core);
    }

    if (window.markdownPreviewCore) start(window.markdownPreviewCore);
    else window.addEventListener('markdown-preview-ready', event => start(event.detail), { once: true });
})();
