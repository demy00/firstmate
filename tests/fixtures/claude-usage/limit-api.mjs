#!/usr/bin/env node
// A local stand-in for the Anthropic API that answers every message request the
// way the API answers a claude.ai account whose plan window is spent: HTTP 429
// with the unified rate-limit headers. Real Claude Code turns that into its own
// "You've hit your 5-hour limit · resets <time> (<zone>)" stop, so a live test
// exercises the vendor's own rendering and StopFailure event without spending
// a token or touching a real limit. Verified on Claude Code 2.1.319.
//
// usage: limit-api.mjs <reset-epoch-seconds> <port-file>
// Writes the listening port to <port-file> once ready.
import http from "node:http";
import { writeFileSync } from "node:fs";

const [reset, portFile] = process.argv.slice(2);
if (!/^[0-9]+$/.test(reset || "") || !portFile) {
  process.stderr.write("usage: limit-api.mjs <reset-epoch-seconds> <port-file>\n");
  process.exit(2);
}

const server = http.createServer((req, res) => {
  req.resume();
  req.on("end", () => {
    if (req.method === "POST" && req.url.startsWith("/v1/messages") && !req.url.includes("count_tokens")) {
      res.writeHead(429, {
        "content-type": "application/json",
        "anthropic-ratelimit-unified-status": "rejected",
        "anthropic-ratelimit-unified-reset": reset,
        "anthropic-ratelimit-unified-representative-claim": "five_hour",
        "anthropic-ratelimit-unified-5h-status": "rejected",
        "anthropic-ratelimit-unified-5h-reset": reset,
        "anthropic-ratelimit-unified-5h-utilization": "1.0",
      });
      res.end(JSON.stringify({ type: "error", error: { type: "rate_limit_error", message: "rate limited" } }));
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end("{}");
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
