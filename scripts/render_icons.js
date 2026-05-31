#!/usr/bin/env node
const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");
const { spawnSync } = require("child_process");

const root = path.resolve(__dirname, "..");
const outDir = process.argv[2] || path.join(root, "build", "icons");
const html = fs.readFileSync(path.join(root, "design", "claudedot-icons.html"), "utf8");
let script = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace(/\brender\(\);\s*$/, "");

const context = {
  console,
  navigator: { clipboard: { writeText: () => Promise.resolve() } },
  getComputedStyle: () => ({
    getPropertyValue: (name) => name === "--accent" ? "#C96442" : "",
  }),
  document: {
    documentElement: {
      getAttribute: () => "light",
      setAttribute: () => {},
    },
    getElementById: () => ({
      innerHTML: "",
      classList: { toggle: () => {} },
      appendChild: () => {},
    }),
    createElement: () => ({
      className: "",
      style: {},
      innerHTML: "",
      appendChild: () => {},
    }),
  },
};

script += `
globalThis.__icons = {
  app: face(APPICON()),
  running: face(WORKING()),
  waiting: face(STATES.find(s => s.state === "awaiting").cfg()),
  error: face(STATES.find(s => s.state === "error").cfg()),
  idleLight: face(STATES.find(s => s.state === "idle light").cfg()),
  idleDark: face(STATES.find(s => s.state === "idle dark").cfg()),
};
`;
vm.createContext(context);
vm.runInContext(script, context);

function chromeBin() {
  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  throw new Error("Chrome/Chromium not found; cannot render PNG icons from SVG");
}

function renderPng(name, svg, size) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claudedot-icon-"));
  const htmlPath = path.join(tmp, `${name}.html`);
  const outPath = path.join(outDir, `${name}.png`);
  const page = `<!doctype html><meta charset="utf-8">
<style>
html,body{margin:0;width:${size}px;height:${size}px;background:transparent;overflow:hidden}
.box{width:${size}px;height:${size}px;border-radius:22.5%;overflow:hidden}
svg{display:block;width:100%;height:100%}
</style><div class="box">${svg}</div>`;
  fs.writeFileSync(htmlPath, page);
  const r = spawnSync(chromeBin(), [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--default-background-color=00000000",
    `--window-size=${size},${size}`,
    `--screenshot=${outPath}`,
    `file://${htmlPath}`,
  ], { stdio: "inherit" });
  if (r.status !== 0) throw new Error(`Chrome failed rendering ${name}`);
  fs.rmSync(tmp, { recursive: true, force: true });
}

fs.mkdirSync(outDir, { recursive: true });
const icons = context.__icons;
renderPng("ClaudeDot", icons.app, 1024);
renderPng("StatusRunning", icons.running, 256);
renderPng("StatusWaiting", icons.waiting, 256);
renderPng("StatusError", icons.error, 256);
renderPng("StatusIdleLight", icons.idleLight, 256);
renderPng("StatusIdleDark", icons.idleDark, 256);
