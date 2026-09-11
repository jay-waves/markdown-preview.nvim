// Dependency-free check of the actual browser SSE handlers.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../assets/nvim-preview.js'), 'utf8');
const code = source.slice(source.indexOf('    function connectSSE(core)'), source.indexOf('    function applyBottomPadding'));
let closeCount = 0;
let reloadCount = 0;
const nodes = [];
const context = {
    withToken: url => url + '?t=test',
    sync: () => reloadCount++,
    window: { close: () => closeCount++ },
    console,
    document: {
        getElementById: id => nodes.find(node => node.id === id),
        createElement: () => ({ style: {}, setAttribute() {} }),
        body: { appendChild: node => nodes.push(node) },
    },
    EventSource: class {
        constructor(url) { this.url = url; this.handlers = {}; }
        addEventListener(name, fn) { this.handlers[name] = fn; }
        close() { this.closed = true; }
    },
};
vm.createContext(context);
vm.runInContext(code + '\nstream = connectSSE({});', context);
const stream = context.stream;
assert.equal(stream.url, '/__live/events?t=test');
assert.equal(stream.handlers.error, undefined); // keep EventSource's native reconnect
stream.handlers.reload();
assert.equal(reloadCount, 1);
assert.equal(closeCount, 0);
stream.handlers['markdown-preview-close']();
assert.equal(stream.closed, true);
assert.equal(closeCount, 1);
assert.match(nodes[0].textContent, /Preview ended/);
stream.handlers['markdown-preview-close']();
assert.equal(nodes.length, 1);
console.log('PASS: close event closes SSE and requests tab closure, with blocked-close fallback');
