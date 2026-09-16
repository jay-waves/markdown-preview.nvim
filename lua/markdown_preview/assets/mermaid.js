import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';

export function createMermaidPreview(options) {
    const { contentElement, openOverlay } = options;
    let renderId = 0;
    const loadedPacks = new Set();
    const lastGoodSvg = {};

    function setTheme(theme) {
        mermaid.initialize({
            startOnLoad: false,
            theme: theme === 'dark' ? 'dark' : 'default',
            securityLevel: 'strict',
        });
    }

    function detectPacks(source) {
        const pattern = /\b([a-z0-9-]+):[a-z0-9-]+\b/gi;
        const packs = new Set();
        let match;
        while ((match = pattern.exec(source))) packs.add(match[1].toLowerCase());
        return [...packs];
    }

    async function ensurePack(name) {
        if (loadedPacks.has(name)) return;
        try {
            const loader = () => fetch(`https://unpkg.com/@iconify-json/${name}@1/icons.json`).then(response => response.json());
            await mermaid.registerIconPacks([{ name, loader }]);
            loadedPacks.add(name);
        } catch (error) {
            console.warn(`[markdown-preview] Mermaid icon pack '${name}' failed to load`, error);
        }
    }

    function removeErrorArtifacts(block) {
        block.querySelectorAll('.error,.error-icon,.error-text,.errorText').forEach(node => node.remove());
    }

    async function renderBlock(block) {
        const source = decodeURIComponent(block.dataset.mermaidSource || '');
        if (!source.trim()) return;
        const wrap = block.querySelector('.mermaid-svg-wrap');
        if (!wrap) return;

        for (const pack of detectPacks(source)) await ensurePack(pack);
        try {
            const { svg } = await mermaid.render(`mmd-render-${++renderId}`, source);
            wrap.innerHTML = svg;
            block.classList.add('mermaid-rendered');
            block.classList.remove('mermaid-errored');
            lastGoodSvg[block.id] = svg;
            removeErrorArtifacts(block);
        } catch (error) {
            block.classList.add('mermaid-errored');
            if (lastGoodSvg[block.id]) wrap.innerHTML = lastGoodSvg[block.id];
            let errorElement = block.querySelector('.mermaid-error');
            if (!errorElement) {
                errorElement = document.createElement('div');
                errorElement.className = 'mermaid-error';
                block.appendChild(errorElement);
            }
            const message = String(error?.message || error || 'Invalid diagram').split('\n').find(Boolean) || 'Invalid diagram';
            errorElement.textContent = message.replace(/\s*mermaid version\s*\d+(?:\.\d+)*\s*$/i, '').trim();
            removeErrorArtifacts(block);
        }
    }

    async function render(force = false) {
        const suffix = force ? '' : ':not(.mermaid-rendered)';
        for (const block of contentElement.querySelectorAll(`.mermaid-block[data-mermaid-source]${suffix}`)) {
            await renderBlock(block);
        }
    }

    contentElement.addEventListener('click', event => {
        const button = event.target.closest('[data-expand]');
        if (!button) return;
        const wrap = document.getElementById(button.dataset.expand)?.querySelector('.mermaid-svg-wrap');
        if (wrap?.innerHTML) openOverlay({ html: wrap.innerHTML, filename: 'diagram.svg' });
    });

    return {
        render,
        setTheme,
        async setup(useElk) {
            if (useElk) {
                const layouts = await import('https://cdn.jsdelivr.net/npm/@mermaid-js/layout-elk@0.2.1/dist/mermaid-layout-elk.esm.min.mjs');
                mermaid.registerLayoutLoaders(layouts.default || layouts);
            }
        },
    };
}
