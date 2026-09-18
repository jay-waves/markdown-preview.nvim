(function () {
    'use strict';

    let activeId = null;
    let headingObserver = null;

    const getContentElement = () => document.getElementById('content');

    function refresh(contentEl, center = false) {
        if (!contentEl) contentEl = getContentElement();
        if (!contentEl) return;
        const toc = document.getElementById('toc-dialog');
        const nav = toc?.querySelector('nav');
        if (!toc || !nav) return;

        const headings = Array.from(contentEl.querySelectorAll(
            'section.heading-section > .heading-summary > :is(h1, h2, h3, h4, h5, h6)',
        )).filter(heading => heading.id);
        nav.replaceChildren();
        if (!headings.length) {
            toc.close();
            activeId = null;
            return;
        }

        const list = document.createElement('ol');
        headings.forEach(heading => {
            const item = document.createElement('li');
            const link = document.createElement('a');
            link.href = `#${CSS.escape(heading.id)}`;
            link.textContent = heading.textContent.trim();
            const level = Number(heading.tagName.slice(1));
            item.style.setProperty('--toc-level', level);
            item.append(link);
            list.append(item);
        });
        nav.append(list);
        if (contentEl === getContentElement()) {
            updateActive(contentEl, center);
            observeHeadings(contentEl);
        }
    }

    function updateActive(contentEl, center = false) {
        contentEl = getContentElement() || contentEl;
        const toc = document.getElementById('toc-dialog');
        if (!toc) return;
        const headings = Array.from(contentEl.querySelectorAll(
            'section.heading-section > .heading-summary > :is(h1, h2, h3, h4, h5, h6)',
        )).filter(heading => heading.id);
        if (!headings.length) return;

        const marker = window.innerHeight * 0.5;
        let current = headings[0];
        let closestDistance = Infinity;
        headings.forEach(heading => {
            const distance = Math.abs(heading.getBoundingClientRect().top - marker);
            if (distance < closestDistance) {
                closestDistance = distance;
                current = heading;
            }
        });

        const changed = current.id !== activeId;
        activeId = current.id;
        toc.querySelectorAll('a.is-active').forEach(link => {
            link.classList.remove('is-active');
            link.removeAttribute('aria-current');
        });
        const link = toc.querySelector(`a[href="#${CSS.escape(current.id)}"]`);
        if (!link) return;
        link.classList.add('is-active');
        link.setAttribute('aria-current', 'location');
        if ((changed || center) && toc.open) link.scrollIntoView({ block: 'center', behavior: 'auto' });
    }

    function observeHeadings(contentEl) {
        if (!window.IntersectionObserver) return;
        headingObserver?.disconnect();
        headingObserver = new IntersectionObserver(() => updateActive(contentEl), {
            root: null,
            rootMargin: '-42% 0px -42% 0px',
            threshold: [0, 1],
        });
        contentEl.querySelectorAll(
            'section.heading-section > .heading-summary > :is(h1, h2, h3, h4, h5, h6)',
        ).forEach(heading => headingObserver.observe(heading));
    }

    function captureHeadingStates(rootEl) {
        const states = new Map();
        rootEl.querySelectorAll('section.heading-section[data-heading-key]').forEach(section => {
            states.set(section.dataset.headingKey, section.classList.contains('is-collapsed'));
        });
        return states;
    }

    function updateHeadingAvailability(rootEl) {
        rootEl.querySelectorAll('section.heading-section').forEach(section => {
            const summary = section.querySelector(':scope > .heading-summary');
            if (!summary) return;
            const disabled = Boolean(section.parentElement?.closest('section.heading-section.is-collapsed'));
            summary.tabIndex = disabled ? -1 : 0;
            summary.setAttribute('aria-expanded', String(!section.classList.contains('is-collapsed')));
            if (disabled) summary.setAttribute('aria-disabled', 'true');
            else summary.removeAttribute('aria-disabled');
        });
    }

    function makeHeadingsCollapsible(rootEl, states = new Map()) {
        const headings = Array.from(rootEl.children).filter(element => /^H[1-6]$/.test(element.tagName));
        const occurrences = new Map();
        const keys = new Map();
        headings.forEach((heading, index) => {
            const identity = heading.id || heading.textContent.trim() || heading.dataset.sourceLine || String(index);
            const base = `${heading.tagName}:${identity}`;
            const occurrence = occurrences.get(base) || 0;
            occurrences.set(base, occurrence + 1);
            keys.set(heading, `${base}:${occurrence}`);
        });

        for (let index = headings.length - 1; index >= 0; index -= 1) {
            const heading = headings[index];
            const level = Number(heading.tagName.slice(1));
            const section = document.createElement('section');
            const summary = document.createElement('div');
            const content = document.createElement('div');
            const indicator = document.createElement('span');
            section.className = 'heading-section';
            section.dataset.headingLevel = String(level);
            section.dataset.headingKey = keys.get(heading);
            section.classList.toggle('is-collapsed', states.get(section.dataset.headingKey) === true);
            summary.className = 'heading-summary';
            summary.setAttribute('role', 'button');
            content.className = 'heading-content';
            indicator.className = 'heading-collapsed-indicator';
            indicator.setAttribute('aria-hidden', 'true');
            indicator.textContent = '…';
            rootEl.insertBefore(section, heading);
            summary.append(heading, indicator);
            section.append(summary, content);

            while (section.nextSibling) {
                const sibling = section.nextSibling;
                const siblingLevel = sibling instanceof HTMLElement && sibling.matches('section.heading-section')
                    ? Number(sibling.dataset.headingLevel) : Infinity;
                if (siblingLevel <= level) break;
                if (siblingLevel < Infinity) section.append(sibling);
                else content.append(sibling);
            }
            const hasContent = Array.from(content.childNodes).some(node =>
                node.nodeType === Node.ELEMENT_NODE || (node.textContent || '').trim(),
            );
            section.classList.toggle('has-heading-content', hasContent);
        }
        updateHeadingAvailability(rootEl);
    }

    function toggleHeadingSection(section) {
        const collapsed = !section.classList.contains('is-collapsed');
        const subtree = [section, ...section.querySelectorAll('section.heading-section')];
        subtree.forEach(item => item.classList.toggle('is-collapsed', collapsed));
        updateHeadingAvailability(section.closest('#content'));
    }

    document.addEventListener('click', event => {
        const summary = event.target.closest?.('.heading-summary');
        if (!summary || !summary.closest('#content')
            || summary.getAttribute('aria-disabled') === 'true') return;
        const section = summary.closest('section.heading-section');
        if (section) toggleHeadingSection(section);
    });
    document.addEventListener('keydown', event => {
        if (event.key !== 'Enter' && event.key !== ' ') return;
        const summary = event.target.closest?.('.heading-summary');
        if (!summary || !summary.closest('#content')
            || summary.getAttribute('aria-disabled') === 'true') return;
        const section = summary.closest('section.heading-section');
        if (!section) return;
        event.preventDefault();
        toggleHeadingSection(section);
    });

    window.markdownPreviewToc = {
        refresh,
        updateActive,
        captureHeadingStates,
        makeHeadingsCollapsible,
    };

    const tocDialog = document.getElementById('toc-dialog');
    const openToc = () => {
        if (!tocDialog) return;
        tocDialog.showModal();
        document.body.classList.add('toc-open');
        tocDialog.focus({ preventScroll: true });
        updateActive(getContentElement(), true);
        if (activeId) {
            const link = tocDialog.querySelector(`a[href="#${CSS.escape(activeId)}"]`);
            link?.scrollIntoView({ block: 'center', behavior: 'auto' });
        }
    };
    tocDialog?.addEventListener('click', event => {
        const rect = tocDialog.getBoundingClientRect();
        const outside = event.clientX < rect.left || event.clientX > rect.right
            || event.clientY < rect.top || event.clientY > rect.bottom;
        if (outside) tocDialog.close();
        if (event.target.closest('a')) tocDialog.close();
    });
    tocDialog?.addEventListener('close', () => document.body.classList.remove('toc-open'));
    window.addEventListener('keydown', event => {
        if (event.key.toLowerCase() !== 't' || event.ctrlKey || event.metaKey || event.altKey) return;
        const target = event.target;
        if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement
            || target.isContentEditable) return;
        event.preventDefault();
        if (!tocDialog?.open) openToc();
    });

    if (getContentElement()) {
        let activeUpdateFrame = 0;
        const scheduleActiveUpdate = () => {
            if (activeUpdateFrame) return;
            activeUpdateFrame = requestAnimationFrame(() => {
                activeUpdateFrame = 0;
                const content = getContentElement();
                if (!content) return;
                updateActive(content);
                observeHeadings(content);
            });
        };
        window.addEventListener('scroll', scheduleActiveUpdate, { passive: true, capture: true });
        document.addEventListener('scroll', scheduleActiveUpdate, { passive: true, capture: true });
        window.addEventListener('resize', scheduleActiveUpdate, { passive: true });
        window.addEventListener('hashchange', scheduleActiveUpdate, { passive: true });
    }
})();
