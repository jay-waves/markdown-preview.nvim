async function start(core) {
    try {
        const response = await fetch('./index.md');
        if (!response.ok) throw new Error(`HTTP ${response.status}`);

        const markdown = await response.text();
        await core.render(markdown);
        window.markdownPreviewToc?.makeHeadingsCollapsible(core.contentElement);
        prepareFootnotes(core.contentElement);
        window.markdownPreviewToc?.refresh(core.contentElement);
        const title = core.contentElement.querySelector('h1')?.textContent?.trim();
        if (title) document.title = `${title} · Jay Waves`;
    } catch (error) {
        core.showContent();
        core.contentElement.innerHTML =
            `<h1>文章加载失败</h1><p>${escapeHtml(error.message)}</p>`;
    }
}

function prepareFootnotes(contentEl) {
    const aside = document.getElementById('footnotes');
    const footnotes = contentEl.querySelector('.footnotes');
    if (!aside || !footnotes) return;
    contentEl.querySelectorAll('.footnotes-sep').forEach(separator => separator.remove());
    footnotes.remove();
    aside.replaceChildren(footnotes);

    const list = footnotes.querySelector('ol');
    if (!list) return;
    const copies = [];
    Array.from(list.children).forEach(item => {
        if (!item.id) return;
        const refs = Array.from(contentEl.querySelectorAll('a[href]'))
            .filter(link => link.getAttribute('href') === `#${item.id}`);
        (refs.length ? refs : [null]).forEach(ref => {
            const copy = item.cloneNode(true);
            copy.removeAttribute('id');
            copy.dataset.footnoteReferenceId = ref?.id || '';
            copies.push(copy);
        });
    });
    list.replaceChildren(...copies);

    const asideRect = aside.getBoundingClientRect();
    aside.style.minHeight = `${Math.max(contentEl.scrollHeight, window.innerHeight)}px`;
    let previousBottom = 0;
    list.querySelectorAll('li[data-footnote-reference-id]').forEach(item => {
        const ref = document.getElementById(item.dataset.footnoteReferenceId);
        if (!ref) return;
        const desiredTop = ref.getBoundingClientRect().top - asideRect.top;
        const top = Math.max(0, desiredTop, previousBottom + 12);
        item.style.top = `${top}px`;
        previousBottom = top + item.getBoundingClientRect().height;
    });
}

function escapeHtml(value) {
    const element = document.createElement('span');
    element.textContent = value;
    return element.innerHTML;
}

if (window.markdownPreviewCore) {
    start(window.markdownPreviewCore);
} else {
    window.addEventListener(
        'markdown-preview-ready',
        event => start(event.detail),
        { once: true },
    );
}
