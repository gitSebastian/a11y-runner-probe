// VoiceOver-on-a-hosted-runner probe (apple-dev, 2026-10-31).
// Question: on GitHub's macOS runners, can an automated job start VoiceOver,
// move it through a native app, and read back what it says as text?
// Two arms, so a failure points at the tool or at the platform:
//   G: Guidepup's VoiceOver driver (AppleScript underneath, polled phrases).
//   R: raw osascript to VoiceOver, the shape apple-dev's own driver would use.
// Target: TextEdit (a native AppKit app), brought to the front first.
import { voiceOver } from "@guidepup/guidepup";
import { execFileSync } from "node:child_process";

const sh = (cmd, args) => {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", timeout: 20000 }).trim();
  } catch (error) {
    return `ERROR ${error.status ?? ""} ${String(error.stderr ?? error.message).trim()}`;
  }
};
const osa = (script) => sh("osascript", ["-e", script]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const front = () =>
  osa('tell application "System Events" to get name of first process whose frontmost is true');

const result = { os: sh("sw_vers", ["-productVersion"]), arms: {} };

osa('tell application "TextEdit" to activate');
osa('tell application "TextEdit" to make new document with properties {text:"Probe text for VoiceOver."}');
await sleep(2000);
result.frontBefore = front();

// Arm G
try {
  await voiceOver.start();
  const phrases = [];
  for (let i = 0; i < 8; i += 1) {
    await voiceOver.next();
    phrases.push(await voiceOver.lastSpokenPhrase());
  }
  result.arms.G = {
    ok: phrases.some((p) => p && p.length > 0),
    phrases,
    log: await voiceOver.spokenPhraseLog(),
    front: front(),
  };
} catch (error) {
  result.arms.G = { ok: false, error: String(error && error.stack ? error.stack : error) };
}

// Arm R, with VoiceOver still running from arm G
const raw = [];
for (let i = 0; i < 6; i += 1) {
  osa('tell application "VoiceOver" to tell vo cursor to move right');
  await sleep(1200);
  raw.push(osa('tell application "VoiceOver" to return content of last phrase'));
}
result.arms.R = { ok: raw.some((p) => p && !p.startsWith("ERROR")), phrases: raw, front: front() };

try {
  await voiceOver.stop();
} catch (error) {
  result.stopError = String(error);
}

console.log("PROBE-RESULT " + JSON.stringify(result, null, 2));
const verdict = result.arms.G.ok || result.arms.R.ok ? "VOICEOVER-READABLE" : "VOICEOVER-NOT-READABLE";
console.log("VERDICT " + verdict + " G=" + result.arms.G.ok + " R=" + result.arms.R.ok);
