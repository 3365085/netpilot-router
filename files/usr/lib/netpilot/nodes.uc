// Expose selector metadata without forwarding subscription credentials.
import { readfile } from 'fs';

function fail(message) {
    warn(message + '\n');
    exit(1);
}

function snapshot(path) {
    let doc;
    try { doc = json(readfile(path)); }
    catch (e) { fail('无法读取节点状态'); }
    if (type(doc) != 'object' || type(doc.proxies) != 'object')
        fail('节点状态格式不正确');
    let group = doc.proxies.PROXY;
    if (type(group) != 'object' || group.type != 'Selector' || type(group.all) != 'array')
        fail('代理节点组尚未就绪');
    return doc;
}

function usable(entry, name) {
    if (type(entry) != 'object' || name == 'NO-SUBSCRIPTION') return false;
    if (name == 'AUTO') return entry.type == 'URLTest';
    for (let blocked in ['Direct', 'DIRECT', 'Reject', 'REJECT', 'Pass', 'Compatible', 'Selector', 'URLTest', 'Fallback', 'LoadBalance'])
        if (entry.type == blocked) return false;
    return true;
}

function member(doc, name) {
    for (let candidate in doc.proxies.PROXY.all)
        if (candidate == name && usable(doc.proxies[name], name)) return true;
    return false;
}

function current(doc, name) {
    for (let depth = 0; depth < 10; depth++) {
        let entry = doc.proxies[name];
        if (type(entry) != 'object') return '';
        if (type(entry.all) != 'array') return usable(entry, name) ? name : '';
        if (type(entry.now) != 'string' || entry.now == name) return '';
        name = entry.now;
    }
    return '';
}

function delay(entry) {
    let history = entry?.history;
    if (type(history) != 'array' || !length(history)) return null;
    let ms = history[length(history) - 1]?.delay;
    return ms > 0 ? ms : null;
}

function normalize(doc) {
    let group = doc.proxies.PROXY;
    let nodes = [];
    for (let name in group.all) {
        let entry = doc.proxies[name];
        if (!usable(entry, name) || name == 'AUTO') continue;
        push(nodes, {
            name, type: entry.type, automatic: false,
            delay: delay(entry),
            alive: entry.alive === true ? true : (entry.alive === false ? false : null)
        });
    }
    let selected = length(nodes) && member(doc, group.now) ? group.now : '';
    let resolved = selected ? current(doc, selected) : '';
    if (length(nodes) && member(doc, 'AUTO')) {
        let auto = doc.proxies.AUTO;
        nodes = [{
            name: 'AUTO', type: auto.type, automatic: true,
            delay: delay(doc.proxies[current(doc, 'AUTO')]),
            alive: auto.alive === true ? true : (auto.alive === false ? false : null)
        }, ...nodes];
    }
    return {
        available: length(nodes) > 0, selected, current: resolved,
        scope: 'router', nodes,
        message: length(nodes) ? '' : '添加订阅后即可选择节点'
    };
}

let command = ARGV[0];
let doc = snapshot(ARGV[1]);
if (command == 'list') {
    printf('%J\n', normalize(doc));
}
else if (command == 'request' || command == 'verify') {
    let name = readfile(ARGV[2]);
    if (type(name) != 'string' || !length(name) || length(name) > 1024 || !member(doc, name))
        fail('请选择当前订阅中的节点');
    if (command == 'request') printf('%J\n', { name });
    else {
        if (doc.proxies.PROXY.now != name) fail('节点未切换，请重试');
        printf('%J\n', normalize(doc));
    }
}
else fail('未知的节点操作');
