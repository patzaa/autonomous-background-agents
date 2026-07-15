// Approve a pending OpenClaw device pairing via the Control-UI path (works when
// the gateway has gateway.controlUi.dangerouslyDisableDeviceAuth=true, which our
// mounted openclaw.json sets even under --allow-unconfigured). Used to pair the
// validate stack's Next.js gateway-client so /qa can actually exercise chat.
//
// Env: OC_GW_URL (ws://host:port), OC_ORIGIN, OC_TOKEN, OC_REQUEST_ID.
// Run with NODE_PATH pointing at a checkout's node_modules (for `ws`).
const WebSocket = require("ws");
const URL = process.env.OC_GW_URL;
const ORIGIN = process.env.OC_ORIGIN || (URL || "").replace(/^ws/, "http");
const TOKEN = process.env.OC_TOKEN;
const REQ = process.env.OC_REQUEST_ID;
if (!URL || !TOKEN || !REQ) { console.error("approve: missing OC_GW_URL/OC_TOKEN/OC_REQUEST_ID"); process.exit(2); }
const ws = new WebSocket(URL, { headers: { Origin: ORIGIN } });
let nextId = 1, challenged = false;
const timer = setTimeout(() => { try { ws.close(); } catch {} console.error("approve: timeout (15s)"); process.exit(1); }, 15000);
ws.on("message", (data) => {
  let m; try { m = JSON.parse(data.toString()); } catch { return; }
  if (!challenged && m.type === "event" && m.event === "connect.challenge") {
    challenged = true;
    ws.send(JSON.stringify({ type: "req", id: String(nextId++), method: "connect", params: {
      minProtocol: 4, maxProtocol: 4,
      client: { id: "openclaw-control-ui", version: "1.0.0", platform: "linux", mode: "webchat" },
      role: "operator", scopes: ["operator.read", "operator.write", "operator.admin", "operator.approvals"],
      caps: [], commands: [], permissions: {}, auth: { token: TOKEN }, locale: "en-US", userAgent: "hv-validate-approve/1.0",
    }}));
    return;
  }
  if (m.type === "res" && m.id === "1") {
    if (m.ok === false) { clearTimeout(timer); ws.close(); console.error("approve: connect rejected", JSON.stringify(m.error)); process.exit(1); }
    ws.send(JSON.stringify({ type: "req", id: String(nextId++), method: "device.pair.approve", params: { requestId: REQ } }));
    return;
  }
  if (m.type === "res" && m.id === "2") {
    clearTimeout(timer); ws.close();
    if (m.ok === false) { console.error("approve: rejected", JSON.stringify(m.error)); process.exit(1); }
    console.log("approve: OK", REQ); process.exit(0);
  }
});
ws.on("error", (e) => { clearTimeout(timer); console.error("approve: ws error", e.message); process.exit(1); });
