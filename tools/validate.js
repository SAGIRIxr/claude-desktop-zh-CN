#!/usr/bin/env node
/**
 * Validates zh-CN.json against en-US.json.
 *
 * Claude Desktop feeds these strings to intl-messageformat, so a malformed
 * message throws at render time and blanks the UI element. Checks:
 *   1. key sets are identical
 *   2. braces balance
 *   3. every ICU argument name in the source also appears in the translation
 *   4. plural/select sub-messages keep an `other` branch
 *   5. no lone `'` (ICU quoting) or unescaped stray characters
 *   6. no untranslated leftovers (pure-ASCII values that differ from source only trivially)
 */
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const en = JSON.parse(fs.readFileSync(path.join(root, 'src', 'en-US.json'), 'utf8'));
const zh = JSON.parse(fs.readFileSync(path.join(root, 'src', 'zh-CN.json'), 'utf8'));

const errors = [];
const warnings = [];

// --- 1. key parity -------------------------------------------------------
const enKeys = Object.keys(en);
const zhKeys = new Set(Object.keys(zh));
for (const k of enKeys) if (!zhKeys.has(k)) errors.push(`missing key: ${k}`);
for (const k of zhKeys) if (!(k in en)) errors.push(`extra key: ${k}`);

// --- helpers -------------------------------------------------------------
function braceBalance(s) {
  let depth = 0;
  for (const ch of s) {
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth < 0) return -1;
    }
  }
  return depth;
}

// Collect ICU argument names: `{name}`, `{name, plural, ...}`, `{name, number}` etc.
function argNames(s) {
  const names = new Set();
  for (const m of s.matchAll(/\{\s*([A-Za-z_$][\w$]*)\s*(?=[},])/g)) names.add(m[1]);
  return names;
}

function pluralArgs(s) {
  const out = new Set();
  for (const m of s.matchAll(/\{\s*([A-Za-z_$][\w$]*)\s*,\s*(plural|select|selectordinal)\s*,/g)) {
    out.add(m[1] + ':' + m[2]);
  }
  return out;
}

// A lone `'` is an ICU quote opener. Doubled `''` is a literal apostrophe.
function loneQuotes(s) {
  return (s.match(/'/g) || []).length % 2 === 1;
}

// --- 2..5 per-message checks --------------------------------------------
for (const k of enKeys) {
  if (!zhKeys.has(k)) continue;
  const a = en[k];
  const b = zh[k];

  const bal = braceBalance(b);
  if (bal !== 0) errors.push(`${k}: unbalanced braces (depth ${bal})`);

  const aArgs = argNames(a);
  const bArgs = argNames(b);
  for (const n of aArgs) {
    if (!bArgs.has(n)) errors.push(`${k}: lost placeholder {${n}}`);
  }
  for (const n of bArgs) {
    if (!aArgs.has(n)) errors.push(`${k}: invented placeholder {${n}}`);
  }

  const aPl = pluralArgs(a);
  const bPl = pluralArgs(b);
  for (const n of aPl) {
    if (!bPl.has(n)) errors.push(`${k}: lost ${n.split(':')[1]} block for {${n.split(':')[0]}}`);
  }
  if (bPl.size && !/\bother\s*\{/.test(b)) {
    errors.push(`${k}: plural/select without an "other" branch`);
  }

  if (loneQuotes(b)) errors.push(`${k}: odd number of ' (ICU quoting hazard)`);

  // tags the renderer binds to rich-text handlers must survive
  const aTags = (a.match(/<\/?[a-zA-Z]+>/g) || []).sort().join(',');
  const bTags = (b.match(/<\/?[a-zA-Z]+>/g) || []).sort().join(',');
  if (aTags !== bTags) errors.push(`${k}: tag mismatch [${aTags}] -> [${bTags}]`);

  // --- 6. translation coverage ------------------------------------------
  if (!/[一-鿿]/.test(b)) {
    // Acceptable when the source is a bare token/brand/unit with nothing to translate.
    // Bare brands, units and symbol-only strings have nothing to translate.
    const stripped = a.replace(/\{[^}]*\}/g, '').trim();
    const inert = /^[\s\p{P}\p{S}\d]*$/u.test(stripped) ||
      ['USB', 'Pro', 'Max', 'Caps Lock'].includes(a) ||
      /^(mA|KB|MB|GB|s|m|h|%)$/.test(stripped);
    if (!inert) warnings.push(`${k}: no Chinese characters — "${a}"`);
  }
}

// --- report --------------------------------------------------------------
console.log(`keys: en=${enKeys.length} zh=${zhKeys.size}`);
const translated = enKeys.filter((k) => zh[k] && /[一-鿿]/.test(zh[k])).length;
console.log(`translated (contains Chinese): ${translated}/${enKeys.length}`);

if (warnings.length) {
  console.log(`\n${warnings.length} warning(s):`);
  warnings.forEach((w) => console.log('  ! ' + w));
}
if (errors.length) {
  console.log(`\n${errors.length} ERROR(s):`);
  errors.forEach((e) => console.log('  x ' + e));
  process.exit(1);
}
console.log('\nOK — zh-CN.json is structurally valid.');
