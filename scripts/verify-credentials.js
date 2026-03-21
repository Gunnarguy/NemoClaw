#!/usr/bin/env node
// Quick credential verification script — safe to delete after use.
const fs = require("fs");
const path = require("path");

const file = path.join(process.env.HOME, ".nemoclaw", "credentials.json");

// 1. Check file exists
if (!fs.existsSync(file)) {
  console.log("FAIL: ~/.nemoclaw/credentials.json not found");
  process.exit(1);
}

// 2. Check permissions
const stat = fs.statSync(file);
const mode = "0" + (stat.mode & 0o777).toString(8);
const dirStat = fs.statSync(path.dirname(file));
const dirMode = "0" + (dirStat.mode & 0o777).toString(8);

console.log("=== File Checks ===");
console.log(
  "File permissions:",
  mode,
  mode === "0600" ? "(correct)" : "(WARNING: should be 0600)",
);
console.log(
  "Dir permissions: ",
  dirMode,
  dirMode === "0700" ? "(correct)" : "(WARNING: should be 0700)",
);

// 3. Check file-based credential loading (clear env vars first)
const savedNvidia = process.env.NVIDIA_API_KEY;
const savedOpenai = process.env.OPENAI_API_KEY;
delete process.env.NVIDIA_API_KEY;
delete process.env.OPENAI_API_KEY;

const { getCredential } = require("../bin/lib/credentials.js");

console.log("\n=== Credential Lookup (from file only) ===");
const nvidia = getCredential("NVIDIA_API_KEY");
const openai = getCredential("OPENAI_API_KEY");
console.log(
  "NVIDIA_API_KEY:",
  nvidia ? "OK (" + nvidia.slice(0, 12) + "...)" : "MISSING",
);
console.log(
  "OPENAI_API_KEY:",
  openai ? "OK (" + openai.slice(0, 12) + "...)" : "MISSING",
);

// Restore for API test
process.env.NVIDIA_API_KEY = nvidia || savedNvidia || "";

// 4. Live API test
if (nvidia) {
  console.log("\n=== Live API Test (NVIDIA) ===");
  const https = require("https");
  const body = JSON.stringify({
    model: "nvidia/nemotron-3-super-120b-a12b",
    messages: [{ role: "user", content: "Reply with only: OK" }],
    max_tokens: 5,
    temperature: 0,
  });
  const req = https.request(
    {
      hostname: "integrate.api.nvidia.com",
      path: "/v1/chat/completions",
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + nvidia,
        "Content-Length": Buffer.byteLength(body),
      },
    },
    (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => {
        if (res.statusCode === 200) {
          console.log("NVIDIA API: OK (HTTP 200)");
        } else {
          console.log("NVIDIA API: FAILED (HTTP " + res.statusCode + ")");
          console.log(data.slice(0, 200));
        }
        printSummary(nvidia, openai, res.statusCode === 200);
      });
    },
  );
  req.on("error", (e) => {
    console.log("NVIDIA API: ERROR -", e.message);
    printSummary(nvidia, openai, false);
  });
  req.write(body);
  req.end();
} else {
  printSummary(nvidia, openai, false);
}

function printSummary(nvidia, openai, apiOk) {
  console.log("\n=== Summary ===");
  console.log("Credentials file:  OK");
  console.log("File permissions:  " + (mode === "0600" ? "OK" : "WARN"));
  console.log("NVIDIA_API_KEY:    " + (nvidia ? "saved" : "MISSING"));
  console.log("OPENAI_API_KEY:    " + (openai ? "saved" : "MISSING"));
  console.log(
    "NVIDIA API live:   " + (apiOk ? "working" : nvidia ? "failed" : "skipped"),
  );
  console.log("");
  if (nvidia && openai && apiOk) {
    console.log("All good. Run 'nemoclaw onboard' when ready.");
  }
}
