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
    let lastContent = null;
    let assetPrefix = '';
    let scrollSyncPaused = false;
    let scrollSyncPauseTimer = null;
    let lastScrollData = null;
    let lastInitialScrollId = null;
    let started = false;

    function tocCall(name, ...args) {
        try {
            return window.markdownPreviewToc?.[name]?.(...args);
        } catch (error) {
            console.warn(`[markdown-preview] toc ${name} failed:`, error);
            return undefined;
        }
    }

    function pauseScrollSync() {
        scrollSyncPaused = true;
        clearTimeout(scrollSyncPauseTimer);
        scrollSyncPauseTimer = setTimeout(() => { scrollSyncPaused = false; }, 3000);
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

    function prepareSidebars(rootEl) {
        tocCall('refresh', rootEl);
    }

    async function fetchDocument() {
        try {
            const resp = await fetch(withToken('/document'), { cache: 'no-store' });
            if (!resp.ok) {
                console.warn('[markdown-preview] document fetch failed:', resp.status);
                if (resp.status === 401) {
                    try { sessionStorage.removeItem('mdp-token'); } catch (_) {}
                }
                return null;
            }
            return await resp.json();
        } catch (error) {
            console.warn('[markdown-preview] document fetch error:', error);
            return null;
        }
    }

    async function sync(core) {
        const value = await fetchDocument();
        if (!value || typeof value.content !== 'string') return;
        const text = value.content.replace(/\r\n?/g, '\n');
        const nextPrefix = typeof value.assetPrefix === 'string' ? value.assetPrefix.replace(/\\/g, '/') : '';
        const assetPrefixChanged = nextPrefix !== assetPrefix;
        assetPrefix = nextPrefix;
        if (typeof value.title === 'string') document.title = value.title;
        if (text === lastContent && !assetPrefixChanged) {
            applyInitialScroll(core.contentElement, value.initialScroll);
            return;
        }
        lastContent = text;

        try {
            const headingStates = tocCall('captureHeadingStates', core.contentElement) || new Map();
            const html = core.renderToHtml(text);
            core.showContent();

            if (window.morphdom) {
                const wrapper = document.createElement('main');
                wrapper.id = 'content';
                wrapper.innerHTML = html;
                rewriteRelativeImages(wrapper);
                tocCall('makeHeadingsCollapsible', wrapper, headingStates);
                prepareSidebars(wrapper);

                window.morphdom(core.contentElement, wrapper, {
                    childrenOnly: false,
                    getNodeKey(node) {
                        if (node.nodeType === 1) {
                            if (node.matches?.('section.heading-section')) {
                                return `heading:${node.dataset.headingKey}`;
                            }
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
                tocCall('makeHeadingsCollapsible', core.contentElement, headingStates);
                prepareSidebars(core.contentElement);
            }

            applyBottomPadding(core.contentElement);
            await core.renderMermaid();
            requestAnimationFrame(() => tocCall('refresh'));
            requestAnimationFrame(() => tocCall('updateActive', undefined, true));
            applyInitialScroll(core.contentElement, value.initialScroll);
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

    function applyInitialScroll(contentEl, data) {
        if (!data || !data.id || data.id === lastInitialScrollId || data.line == null) return;
        lastInitialScrollId = data.id;
        scrollToSourceLine(contentEl, data.line, data.total || 1);
    }

    function connectSSE(core) {
        const evtSource = new EventSource(withToken('/__live/events'));
        evtSource.addEventListener('markdown-preview-close', () => {
            evtSource.close();
            window.close();
            // Externally opened tabs may not be script-closable. Keep the
            // document readable and explain why this page remains open.
            if (!document.getElementById('markdown-preview-ended')) {
                const status = document.createElement('div');
                status.id = 'markdown-preview-ended';
                status.setAttribute('role', 'status');
                status.textContent = 'Preview ended. You can close this tab.';
                status.style.cssText = 'position:fixed;bottom:16px;left:50%;transform:translateX(-50%);'
                    + 'padding:10px 16px;border-radius:6px;background:Canvas;color:CanvasText;'
                    + 'box-shadow:0 2px 12px #0003;z-index:2147483647;font:14px system-ui,sans-serif';
                document.body.appendChild(status);
            }
        });
        evtSource.addEventListener('reload', () => sync(core));
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
        window.addEventListener('resize', () => {
            applyBottomPadding(core.contentElement);
        });

        core.contentElement.addEventListener('click', event => {
            if (!CLICK_TO_NVIM) return;
            if (event.target.closest('a, button, input, select, textarea, summary, .heading-summary')) return;
            const block = event.target.closest('[data-source-line]');
            if (!block) return;
            const line = Number(block.dataset.sourceLine);
            if (!Number.isInteger(line) || line < 0) return;
            const data = encodeURIComponent(JSON.stringify({ line }));
            fetch(withToken(`/__live/event?event=markdown-click&data=${data}`), {
                cache: 'no-store', keepalive: true,
            }).catch(() => {});
        });

        new ResizeObserver(() => {
            if (lastScrollData && !scrollSyncPaused) {
                scrollToSourceLine(core.contentElement, lastScrollData.line, lastScrollData.total || 1);
            }
        }).observe(core.contentElement);

        connectSSE(core);
        await sync(core);
    }

    if (window.markdownPreviewCore) start(window.markdownPreviewCore);
    else window.addEventListener('markdown-preview-ready', event => start(event.detail), { once: true });
})();
