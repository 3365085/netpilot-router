// Select this client's connections without exposing other clients or credentials.
import { readfile } from 'fs';

function fail() { warn('无法读取旧连接\n'); exit(1); }
let ip = ARGV[1];
if (type(ip) != 'string' || !match(ip, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) fail();
for (let octet in split(ip, '.')) if (length(octet) > 3 || +octet > 255) fail();
let doc;
try { doc = json(readfile(ARGV[0])); } catch (e) { fail(); }
if (type(doc) != 'object' || !('connections' in doc) || (doc.connections != null && type(doc.connections) != 'array')) fail();
let seen = {};
for (let entry in doc.connections ?? []) {
    let source = entry?.metadata?.sourceIP;
    if (source != ip && source != '::ffff:' + ip) continue;
    let id = entry.id;
    if (type(id) != 'string' || !match(id, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/)) fail();
    if (seen[id]) continue;
    seen[id] = true;
    print(id + '\n');
}
