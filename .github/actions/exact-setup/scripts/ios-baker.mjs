#!/usr/bin/env bun
// Apply identical source on every platform; an optional verified Mac host
// baker is selected at runtime. Normal Cargo and Exact receipts still run.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';

const [command, ...args] = process.argv.slice(2);
const root = realpathSync(process.env.EXACT || (() => { throw Error('EXACT is required'); })());
const ref = process.env.SETUP_EXACT_REF;
if (!/^[0-9a-f]{40}$/.test(ref || '')) throw Error('SETUP_EXACT_REF must be a full commit');
const git = (...a) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8' }).trim();
if (git('rev-parse', 'HEAD') !== ref) throw Error('Exact checkout does not match its pin');
const sha = p => createHash('sha256').update(readFileSync(p)).digest('hex');
const absolute = p => { if (!p || !isAbsolute(p) || /[\r\n]/.test(p)) throw Error('expected an absolute path without newlines'); return resolve(p); };
const requireMac = () => { if (process.platform !== 'darwin' || process.arch !== 'arm64') throw Error('requires Apple Silicon macOS'); };
const verifyBinary = p => {
  if (!statSync(p).isFile()) throw Error('baker is not a file');
  execFileSync('xcrun', ['lipo', '-verify_arch', 'arm64', p], { stdio: 'ignore' });
};
const needle = 'export function appleBakeTool(env, cargoArgs) {\n';
// This insertion is deliberately byte-identical on Linux and macOS. The
// runtime variables are never written into the SDK source or build receipt.
const insertion = `  // EXACT_PREBUILT_IOS_BAKER_V1: verified public tool or upstream Cargo.\n  { const tool = env.EXACT_IOS_BAKER_PATH, expected = env.EXACT_IOS_BAKER_SHA256;\n    try { if (tool?.startsWith('/') && /^[0-9a-f]{64}$/.test(expected ?? '') && existsSync(tool) && createHash('sha256').update(readFileSync(tool)).digest('hex') === expected) return tool; } catch {}\n  }\n`;
function patch() {
  const file = resolve(root, 'scripts/linked-plan.mjs');
  const original = execFileSync('git', ['-C', root, 'show', 'HEAD:scripts/linked-plan.mjs'], { encoding: 'utf8' });
  if (original.split(needle).length !== 2) throw Error('unsupported Exact baker source');
  const desired = original.replace(needle, needle + insertion);
  const current = readFileSync(file, 'utf8');
  if (current !== original && current !== desired) throw Error('Exact baker source has unexpected changes');
  if (current !== desired) writeFileSync(file, desired);
}
if (command === 'record' && args.length === 2) {
  requireMac();
  const [tool, manifest] = args.map(absolute);
  if (git('status', '--porcelain', '--untracked-files=no')) throw Error('producer Exact checkout must be clean');
  verifyBinary(tool);
  const data = { version: 1, exactRef: ref, exactPath: root, baker: tool, sha256: sha(tool) };
  writeFileSync(manifest, JSON.stringify(data) + '\n', { flag: 'wx' });
  console.log('Recorded public iOS baker');
} else if (command === 'patch' && args.length === 0) {
  patch();
  console.log('Applied platform-independent iOS baker hook');
} else if (command === 'enable' && args.length === 1) {
  requireMac();
  const manifest = JSON.parse(readFileSync(absolute(args[0]), 'utf8'));
  if (manifest.version !== 1 || manifest.exactRef !== ref || manifest.exactPath !== root || !/^[0-9a-f]{64}$/.test(manifest.sha256 || '')) throw Error('baker manifest does not match checkout');
  const tool = absolute(manifest.baker);
  verifyBinary(tool);
  if (sha(tool) !== manifest.sha256) throw Error('baker digest mismatch');
  patch();
  if (process.env.GITHUB_ENV) appendFileSync(process.env.GITHUB_ENV, `EXACT_IOS_BAKER_PATH=${tool}\nEXACT_IOS_BAKER_SHA256=${manifest.sha256}\n`);
  console.log(JSON.stringify({ path: tool, sha256: manifest.sha256 }));
} else throw Error('usage: ios-baker.mjs record <tool> <new-manifest> | patch | enable <manifest>');
