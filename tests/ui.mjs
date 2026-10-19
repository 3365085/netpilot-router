// Browser checks with an isolated Chrome profile; no npm packages required.
// The default server uses fixtures. LIVE_URL enables read-only live-page checks.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = process.env.UI_OUTPUT || path.join(os.tmpdir(), 'netpilot-ui-preview');
await fs.mkdir(output, {recursive:true});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'netpilot-chrome-'));
const errors = [], requests = [];
let simulateBusy = false;
const fixture = {
  ok:true, hostname:'iPhone', ip:'192.168.9.200', mac:'02:00:00:00:00:01', mode:'both', routing:'rule',
  core_running:true, firewall_ready:true, backend:'redirect', adblock_rules:958, memory_mb:'53.9', version:'1.2.0',
  clash_profiles:[{id:'subscription',name:'机场订阅-1792418607',type:'http',value:'https://example.com/sub?token=fixture',active:true}],
  adg_sources:[{id:'filter',name:'秋风广告规则 AWAvenue',type:'http',format:'yaml',value:'https://example.com/filter.yaml',enabled:true}],
  node_selection:{available:true,selected:'AUTO',current:'VLESS-REALITY',scope:'router',nodes:[
    {name:'AUTO',type:'URLTest',automatic:true,delay:190,alive:true},
    {name:'VLESS-REALITY',type:'Vless',automatic:false,delay:190,alive:true},
    {name:'VMess-WS-8443',type:'Vmess',automatic:false,delay:214,alive:true}
  ]},message:'已刷新'
};

let server, chrome, cdp;
class CDP {
  constructor(socket) {
    this.socket = socket; this.nextId = 0; this.pending = new Map();
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const p = this.pending.get(message.id); if (!p) return;
        this.pending.delete(message.id);
        if (message.error) p.reject(new Error(JSON.stringify(message.error))); else p.resolve(message.result);
      } else if (message.method === 'Runtime.exceptionThrown') {
        errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
      }
    });
  }
  send(method, params={}) {
    return new Promise((resolve,reject) => {
      const id = ++this.nextId; this.pending.set(id,{resolve,reject});
      this.socket.send(JSON.stringify({id,method,params}));
    });
  }
  async evaluate(expression) {
    const r = await this.send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  }
  async wait(expression, timeout=10000) {
    const start=Date.now();
    while (Date.now()-start<timeout) { if (await this.evaluate(expression)) return; await sleep(70); }
    throw new Error('Timed out: '+expression);
  }
  async click(selector) {
    const r=await this.evaluate('(()=>{const e=document.querySelector('+JSON.stringify(selector)+'); if(!e) throw Error("Missing control"); e.scrollIntoView({block:"nearest"}); const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()');
    await this.send('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...r});
    await this.send('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...r});
  }
  async screenshot(name) {
    await sleep(200);
    const r=await this.send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
    await fs.writeFile(path.join(output,name),Buffer.from(r.data,'base64'));
  }
}

try {
  let base = process.env.LIVE_URL;
  if (!base) {
    server=http.createServer(async(req,res)=>{
      const url=new URL(req.url,'http://localhost');
      if (url.pathname==='/cgi-bin/netpilot') {
        let body=''; for await (const chunk of req) body+=chunk;
        requests.push({query:url.searchParams.toString(),method:req.method});
        if (simulateBusy && req.method==='GET') {
          res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({ok:false,code:'busy',message:'正在应用其他修改，请稍后重试'}));return;
        }
        if (req.method==='POST') {
          const action=url.searchParams.get('action');
          if (action==='select_node') {
            const name=Buffer.from(body,'base64').toString('utf8');
            if (!fixture.node_selection.nodes.some(n=>n.name===name)) {
              res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({ok:false,message:'节点切换失败'}));return;
            }
            fixture.node_selection.selected=name;
            fixture.node_selection.current=name==='AUTO'?'VLESS-REALITY':name;
            fixture.message='节点已切换';
          } else if (action==='check_nodes') fixture.message='延迟已更新';
          else if (action==='add_adg_url') {
            res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({ok:false,message:'规则源下载失败'}));return;
          } else if (url.searchParams.has('mode')) fixture.mode=url.searchParams.get('mode');
          else if (url.searchParams.has('routing')) fixture.routing=url.searchParams.get('routing');
          await sleep(130);
        }
        res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(fixture));
      } else if (url.pathname==='/'||url.pathname==='/netpilot.html') {
        res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(await fs.readFile(path.join(root,'files/www/netpilot.html')));
      } else {res.writeHead(404);res.end();}
    });
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
    base='http://127.0.0.1:'+server.address().port;
  }
  chrome=spawn(process.env.CHROME_BIN||'/usr/bin/google-chrome',[
    '--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--disable-background-networking',
    '--disable-default-apps','--disable-sync','--no-first-run','--no-default-browser-check','--force-color-profile=srgb',
    '--remote-debugging-port=0','--remote-debugging-address=127.0.0.1','--user-data-dir='+profile,'about:blank'
  ],{stdio:'ignore'});
  let port;
  for (let i=0;i<120;i++) {
    try {port=(await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0];break;} catch {} await sleep(100);
  }
  assert(port,'Chrome did not start');
  const targets=await (await fetch('http://127.0.0.1:'+port+'/json/list')).json();
  const socket=new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  cdp=new CDP(socket);
  await cdp.send('Page.enable');await cdp.send('Runtime.enable');await cdp.send('Network.enable');
  if (process.env.LIVE_URL) {
    assert(process.env.NETPILOT_TEST_PASSWORD,'Live page checks require a password in the environment');
    await cdp.send('Network.setExtraHTTPHeaders',{headers:{Authorization:'Basic '+Buffer.from('root:'+process.env.NETPILOT_TEST_PASSWORD).toString('base64')}});
  }
  await cdp.send('Emulation.setTouchEmulationEnabled',{enabled:true,maxTouchPoints:5});
  await cdp.send('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:2,mobile:true});
  await cdp.send('Emulation.setEmulatedMedia',{features:[{name:'prefers-color-scheme',value:'dark'}]});
  await cdp.send('Page.navigate',{url:base+'/netpilot.html'});
  await cdp.wait('typeof state !== "undefined" && state !== null && document.getElementById("nodeSummary").textContent !== "正在读取"');
  assert.equal(await cdp.evaluate('document.documentElement.scrollWidth <= innerWidth'),true,'Horizontal overflow');
  assert.equal(await cdp.evaluate('Array.from(document.querySelectorAll("[data-mode]")).every(e=>e.getBoundingClientRect().height>=44)'),true,'Small mode touch targets');
  assert.equal(await cdp.evaluate('Array.from(document.querySelectorAll("#app p,#app h1,#app h2,#app .row-title")).some(e=>/满血|极速|毫秒|100%|强制|零损耗/.test(e.textContent))'),false);
  if (!process.env.LIVE_URL) {
    assert.equal(await cdp.evaluate('document.getElementById("subscriptionSummary").textContent'),'订阅 1');
    assert.equal(await cdp.evaluate('Array.from(document.querySelectorAll("#app *")).filter(e=>e.children.length===0).some(e=>e.textContent.includes("example.com/sub"))'),false);
    simulateBusy=true;
    await cdp.evaluate('refresh(false)');
    assert.equal(await cdp.evaluate('document.getElementById("serviceStatus").textContent'),'运行中','A concurrent operation is not a connection failure');
    simulateBusy=false;
  }
  await cdp.screenshot('ios-dark.png');
  await cdp.click('#nodeButton');await cdp.wait('document.getElementById("nodeDialog").open');
  assert.equal(await cdp.evaluate('document.getElementById("nodeDialog").contains(document.activeElement)'),true,'Modal focus');
  await cdp.wait('document.getElementById("nodeDialog").getBoundingClientRect().bottom<=innerHeight+1');
  const bounds=await cdp.evaluate('(()=>{const e=document.getElementById("nodeDialog"),r=e.getBoundingClientRect();return {top:r.top,bottom:r.bottom,width:r.width,viewport:innerHeight,visual:visualViewport.height,position:getComputedStyle(e).position};})()');
  await cdp.screenshot('ios-node-picker.png');
  assert(bounds.top>=0&&bounds.bottom<=845&&bounds.width<=391,'Sheet exceeds phone viewport: '+JSON.stringify(bounds));
  await cdp.click('[data-close="nodeDialog"]');
  await cdp.wait('!document.getElementById("nodeDialog").open');
  assert.equal(await cdp.evaluate('document.activeElement.id'),'nodeButton','Focus restoration');

  if (!process.env.LIVE_URL) {
    await cdp.click('#nodeButton');
    await cdp.click('[data-node="VMess-WS-8443"]');
    await cdp.wait('!mutating && state.node_selection.selected === "VMess-WS-8443"');
    assert.equal(fixture.node_selection.selected,'VMess-WS-8443');
    assert(requests.some(r=>r.method==='POST'&&r.query==='action=select_node'));
    await cdp.click('#checkNodes');await cdp.wait('!mutating');
    assert.equal(fixture.node_selection.selected,'VMess-WS-8443','Delay check changed selector');
    fixture.node_selection.nodes.push(...Array.from({length:8},(_,i)=>({name:'香港 / "备用" / 中文很长的节点名称 '+i,type:'Vless',automatic:false,delay:null,alive:null})));
    await cdp.evaluate('refresh(false)');await cdp.wait('state.node_selection.nodes.length===11');
    await cdp.evaluate('renderNodes()');
    assert.equal(await cdp.evaluate('document.getElementById("nodeSearchWrap").hidden'),false);
    await cdp.evaluate('document.getElementById("nodeSearch").value="备用";document.getElementById("nodeSearch").dispatchEvent(new Event("input"));');
    assert.equal(await cdp.evaluate('document.querySelectorAll(".node-option").length'),8);
    assert.equal(await cdp.evaluate('document.getElementById("nodeDialog").scrollWidth<=document.getElementById("nodeDialog").clientWidth'),true);
    await cdp.click('.node-option');
    await cdp.wait('!mutating && state.node_selection.selected.includes("备用")');
    assert(fixture.node_selection.selected.includes('中文很长的节点名称'),'Unicode node selection');
    await cdp.click('[data-close="nodeDialog"]');
    await cdp.click('#adgButton');
    await cdp.wait('document.getElementById("sourceDialog").open');
    await cdp.click('#addSourceButton');
    await cdp.wait('sourceFormOpen');
    await cdp.evaluate('document.getElementById("sourceUrl").value="https://invalid.example/filter.yaml";document.getElementById("sourceUrl").dispatchEvent(new Event("input"));');
    await cdp.click('#sourceDone');await cdp.wait('!mutating');
    assert.equal(await cdp.evaluate('sourceFormOpen'),true,'Failed import closed form');
    assert.equal(await cdp.evaluate('document.getElementById("sourceUrl").value'),'https://invalid.example/filter.yaml','Failed import cleared input');
    assert.equal(await cdp.evaluate('document.getElementById("toast").textContent'),'规则源下载失败');
    await cdp.click('#sourceBack');await cdp.click('#sourceDone');
    await cdp.click('[data-mode="adg"]');await cdp.wait('!mutating && state.mode==="adg"');
    assert.equal(await cdp.evaluate('document.getElementById("routingHint").hidden'),false);
    await cdp.click('[data-routing="global"]');await cdp.wait('!mutating && state.routing==="global"');
  }
  for (const [width,height] of [[320,568],[375,812],[430,932],[844,390],[1280,900]]) {
    await cdp.send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<900});
    await sleep(80);
    assert.equal(await cdp.evaluate('document.documentElement.scrollWidth<=innerWidth'),true,'Overflow at width '+width);
    await cdp.click('#nodeButton');
    await cdp.wait('document.getElementById("nodeDialog").getBoundingClientRect().bottom<=innerHeight+1');
    const fits=await cdp.evaluate('(()=>{let r=document.getElementById("nodeDialog").getBoundingClientRect();return r.left>=-1&&r.top>=-1&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1;})()');
    assert.equal(fits,true,'Dialog does not fit '+width+'x'+height);
    await cdp.click('[data-close="nodeDialog"]');
  }
  await cdp.send('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:2,mobile:true});
  await cdp.send('Emulation.setEmulatedMedia',{features:[{name:'prefers-color-scheme',value:'light'}]});
  await cdp.evaluate('window.scrollTo(0,0)');await cdp.screenshot('ios-light.png');
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS: phone/desktop layouts, dark/light themes, modal focus and overflow'+(process.env.LIVE_URL?' (live router)':', node selection/search, POST actions and failed-import recovery'));
  console.log('Screenshots: '+output);
} finally {
  if (cdp) {try {await cdp.send('Browser.close');} catch {}}
  if (chrome) {chrome.kill('SIGTERM');await sleep(300);}
  if (server) await new Promise(resolve=>server.close(resolve));
  await fs.rm(profile,{recursive:true,force:true,maxRetries:4,retryDelay:200});
}
