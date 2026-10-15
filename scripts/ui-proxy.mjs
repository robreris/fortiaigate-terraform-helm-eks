#!/usr/bin/env node
// Reach FortiAIGate through local kubectl port-forwards on one HTTPS origin.
// This bypasses ALB/DNS for troubleshooting; it does not test ingress itself.
// Usage: node scripts/ui-proxy.mjs [listenPort] (default 8443)
// Then open https://localhost:8443/ui. Ctrl-C stops the forwards and proxy.

import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import https from "node:https";
import os from "node:os";
import path from "node:path";

const NAMESPACE = process.env.FAIG_NAMESPACE || "fortiaigate";
const LISTEN_PORT = Number(process.argv[2] || 8443);

// [path prefix, service, service port, local forward port] — first match wins.
const ROUTES = [
  ["/ui", "webui", 3000, 13000],
  ["/api/", "api", 8000, 18000],
  ["/ai", "llm-gateway", 8080, 18080],
  ["/", "webui", 3000, 13000],
];

// Self-signed cert for the local listener, generated once and reused.
const certDir = path.join(os.homedir(), ".cache", "faig-ui-proxy");
const keyFile = path.join(certDir, "key.pem");
const certFile = path.join(certDir, "cert.pem");
if (!existsSync(keyFile) || !existsSync(certFile)) {
  mkdirSync(certDir, { recursive: true });
  execFileSync("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "365",
    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    "-keyout", keyFile, "-out", certFile,
  ], { stdio: "ignore" });
}

const uniqueForwards = [...new Map(ROUTES.map(route => [route[1], route])).values()];
const forwards = uniqueForwards.map(([, svc, port, localPort]) => {
  const pf = spawn("kubectl", ["-n", NAMESPACE, "port-forward", `svc/${svc}`, `${localPort}:${port}`], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  pf.on("exit", (code) => {
    if (!shuttingDown) {
      console.error(`port-forward to svc/${svc} exited (${code}); stopping.`);
      shutdown(1);
    }
  });
  return pf;
});

let shuttingDown = false;
function shutdown(code = 0) {
  shuttingDown = true;
  for (const pf of forwards) pf.kill();
  process.exit(code);
}
process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));

// The backends serve HTTPS with the chart's (self-signed) serving cert.
const upstreamAgent = new https.Agent({ rejectUnauthorized: false, keepAlive: true });

const server = https.createServer(
  { key: readFileSync(keyFile), cert: readFileSync(certFile) },
  (req, res) => {
    const pathname = new URL(req.url, "https://localhost").pathname;
    const [, svc, , localPort] = ROUTES.find(([prefix]) =>
      prefix === "/" || pathname === prefix.replace(/\/$/, "") ||
      pathname.startsWith(prefix.endsWith("/") ? prefix : `${prefix}/`),
    );
    const upstream = https.request(
      {
        host: "127.0.0.1",
        port: localPort,
        method: req.method,
        path: req.url,
        headers: req.headers,
        agent: upstreamAgent,
      },
      (up) => {
        res.writeHead(up.statusCode, up.headers);
        up.pipe(res);
      },
    );
    upstream.on("error", (err) => {
      console.error(`${req.method} ${req.url} -> ${svc}: ${err.message}`);
      if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
      res.end(`upstream ${svc} error: ${err.message}\n`);
    });
    req.pipe(upstream);
  },
);

// Give the port-forwards a moment to bind before accepting traffic.
setTimeout(() => {
  server.listen(LISTEN_PORT, "127.0.0.1", () => {
    console.log(`FortiAIGate UI: https://localhost:${LISTEN_PORT}/ui  (Ctrl-C to stop)`);
  });
}, 2000);
