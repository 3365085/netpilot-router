import { readfile } from 'fs';
function fail() { warn('检查结果格式不正确\n'); exit(1); }
let doc;
try { doc = json(readfile(ARGV[0])); } catch (e) { fail(); }
let targets = ['ad.doubleclick.net', 'pagead2.googlesyndication.com', 'mi.gdt.qq.com', 'mobads.baidu.com', 'www.baidu.com', 'www.qq.com', 'www.apple.com'];
if (type(doc) != 'object' || type(doc.nonce) != 'string' || !match(doc.nonce, /^[a-zA-Z0-9_-]{1,64}$/) || type(doc.results) != 'array') fail();
if (doc.schema == 2) push(targets, 'unresolvable.invalid', 'router-closed-port');
if (length(doc.results) != length(targets)) fail();
let results = [];
for (let index, item in doc.results) {
    if (type(item) != 'object' || item.host != targets[index] || (item.outcome != 'connected' && item.outcome != 'failed')) fail();
    push(results, {
        host: item.host, outcome: item.outcome,
        elapsed_ms: type(item.elapsed_ms) == 'int' ? item.elapsed_ms : null,
        response_type: type(item.response_type) == 'string' ? substr(item.response_type, 0, 40) : '',
        error: type(item.error) == 'string' ? substr(item.error, 0, 200) : ''
    });
}
printf('%J\n', {
    ip: ARGV[1], mode: ARGV[2], routing: ARGV[3],
    schema: doc.schema == 2 ? 2 : 1, received_at: ARGV[4] ?? '',
    nonce: doc.nonce, user_agent: type(doc.user_agent) == 'string' ? substr(doc.user_agent, 0, 400) : '',
    started_at: type(doc.started_at) == 'string' ? substr(doc.started_at, 0, 40) : '',
    results
});
