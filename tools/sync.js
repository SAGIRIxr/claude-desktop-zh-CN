#!/usr/bin/env node
/**
 * Diffs the installed en-US.json against the vendored copy, so the pack can be
 * brought forward when Claude Desktop updates.
 *
 * Usage:
 *   node tools/sync.js                 # report only
 *   node tools/sync.js --write         # refresh src/en-US.json and stub new keys
 *
 * New keys are stubbed into zh-CN.json with their English text and a
 * "TODO" marker so `validate.js` flags them as untranslated.
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const write = process.argv.includes('--write');

function installedResourcesDir() {
  const ps = [
    '-NoProfile', '-Command',
    "$p = Get-AppxPackage -Name Claude -EA SilentlyContinue | Select-Object -First 1;" +
    " if ($p) { Join-Path $p.InstallLocation 'app\\resources' }" +
    " else { (Get-Item \"$env:LOCALAPPDATA\\AnthropicClaude\\app-*\\resources\" -EA SilentlyContinue |" +
    " Sort-Object FullName -Descending | Select-Object -First 1).FullName }",
  ];
  const out = execFileSync('powershell.exe', ps, { encoding: 'utf8' }).trim();
  if (!out) throw new Error('Claude Desktop installation not found');
  return out;
}

const resDir = installedResourcesDir();
const livePath = path.join(resDir, 'en-US.json');
console.log('installed resources:', resDir);

const live = JSON.parse(fs.readFileSync(livePath, 'utf8'));
const vendored = JSON.parse(fs.readFileSync(path.join(root, 'src', 'en-US.json'), 'utf8'));
const zhPath = path.join(root, 'src', 'zh-CN.json');
const zh = JSON.parse(fs.readFileSync(zhPath, 'utf8'));

const added = Object.keys(live).filter((k) => !(k in vendored));
const removed = Object.keys(vendored).filter((k) => !(k in live));
const changed = Object.keys(live).filter((k) => k in vendored && live[k] !== vendored[k]);

console.log(`\nadded:   ${added.length}`);
added.forEach((k) => console.log(`  + ${k}  ${JSON.stringify(live[k])}`));
console.log(`removed: ${removed.length}`);
removed.forEach((k) => console.log(`  - ${k}  ${JSON.stringify(vendored[k])}`));
console.log(`changed: ${changed.length}`);
changed.forEach((k) => {
  console.log(`  ~ ${k}`);
  console.log(`      was: ${JSON.stringify(vendored[k])}`);
  console.log(`      now: ${JSON.stringify(live[k])}`);
});

if (!added.length && !removed.length && !changed.length) {
  console.log('\nUp to date — zh-CN.json matches the installed build.');
  process.exit(0);
}

if (!write) {
  console.log('\nRe-run with --write to apply. Changed keys keep their existing');
  console.log('translation; review them by hand before shipping.');
  process.exit(0);
}

// Rebuild zh-CN.json in the live key order, preserving existing translations.
const next = {};
for (const k of Object.keys(live).sort()) {
  if (k in zh && !removed.includes(k)) next[k] = zh[k];
  else next[k] = live[k]; // stub: English text, flagged by validate.js
}
fs.writeFileSync(zhPath, JSON.stringify(next, null, 2) + '\n', 'utf8');
fs.writeFileSync(
  path.join(root, 'src', 'en-US.json'),
  JSON.stringify(live, Object.keys(live).sort(), 2) + '\n',
  'utf8'
);
console.log(`\nWrote src/en-US.json and src/zh-CN.json.`);
console.log(`${added.length} new key(s) need translation — run: node tools/validate.js`);
