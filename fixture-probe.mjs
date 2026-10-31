// Fixture probe (apple-dev, 2026-10-31): does VoiceOver on a hosted runner
// speak two known defect shapes, and stay silent on a known-clean control?
// Pass/fail is decided by DEFECTIVE and CLEAN only; the two candidate fixes are
// measured and reported. Only VoiceOver receives Apple Events: the fixture is
// launched with open and stopped with pkill, so no Automation box appears.
// Soundboard a11y-runner-fixture r1 (2026-10-31) shaped this: clean control
// gates, literal asset match, menu opened and closed, "Hibiki menu" required
// in both gating transcripts, "move into item" after a repeated phrase.
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const APP = process.argv[2];
const sh = (cmd, args) => {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", timeout: 20000 }).trim();
  } catch (error) {
    return `ERROR ${error.status ?? ""} ${String(error.stderr ?? error.message).trim()}`;
  }
};
const vo = (s) => sh("osascript", ["-e", `tell application "VoiceOver" to ${s}`]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// "last phrase" holds only the latest chunk: poll and keep distinct values.
async function collect(ms = 2000) {
  const seen = [];
  for (let t = 0; t < ms; t += 250) {
    const p = vo("return content of last phrase");
    if (p && !p.startsWith("ERROR") && p !== "missing value" && !seen.includes(p)) seen.push(p);
    await sleep(250);
  }
  return seen;
}

async function runVariant(variant) {
  const steps = [];
  sh("pkill", ["-x", "Fixture"]);
  sh("open", ["-n", APP, "--args", variant]);
  await sleep(4000);
  const front = sh("/bin/sh", ["-c", "lsappinfo info -only name `lsappinfo front`"]);
  sh("open", ["-a", "VoiceOver"]);
  await sleep(5000);
  steps.push({ step: "start", phrases: await collect() });
  vo("tell vo cursor to move to first item");
  steps.push({ step: "first", phrases: await collect() });
  let gearDone = false;
  let last = "";
  let repeats = 0;
  for (let i = 0; i < 20; i += 1) {
    vo("tell vo cursor to move right");
    const phrases = await collect();
    steps.push({ step: `right${i}`, phrases });
    const joined = phrases.join(" | ");
    if (joined === last) {
      repeats += 1;
      if (repeats >= 1) {
        vo("tell vo cursor to move into item");
        steps.push({ step: `into${i}`, phrases: await collect() });
        repeats = 0;
      }
    } else {
      repeats = 0;
    }
    last = joined;
    if (!gearDone && /pop.?up|Hibiki menu/i.test(joined)) {
      gearDone = true;
      vo("tell vo cursor to perform action");
      steps.push({ step: "menu-open", phrases: await collect(2500) });
      vo("tell vo cursor to perform action");
      steps.push({ step: "menu-close", phrases: await collect(2500) });
    }
  }
  vo("quit");
  await sleep(3000);
  sh("pkill", ["-x", "Fixture"]);
  await sleep(2000);
  const text = steps.flatMap((s) => s.phrases).join("\n");
  const general = [...new Set(text.match(/\b[a-z]+(?:-[a-z0-9]+)+\b/g) ?? [])];
  return {
    variant,
    front,
    steps,
    clock: /\b\d{1,2}:\d{2}\b/.test(text),
    asset: text.includes("icon-settings"),
    hasMenuLabel: text.includes("Hibiki menu"),
    hasPlayback: text.includes("Playback position"),
    generalHyphenTokens: general,
  };
}

const results = {};
for (const v of ["defective", "clean", "fix-hidden", "fix-decorative"]) {
  results[v] = await runVariant(v);
  writeFileSync(`transcript-${v}.json`, JSON.stringify(results[v], null, 2));
}
const d = results.defective;
const c = results.clean;
const instrumentOk = d.clock && d.asset && d.hasMenuLabel && !c.clock && !c.asset && c.hasMenuLabel && c.hasPlayback;
console.log("SUMMARY " + JSON.stringify(Object.fromEntries(Object.entries(results).map(([k, r]) =>
  [k, { clock: r.clock, asset: r.asset, menu: r.hasMenuLabel, playback: r.hasPlayback, front: r.front, general: r.generalHyphenTokens }])), null, 2));
console.log("VERDICT " + (instrumentOk ? "INSTRUMENT-PASS" : "INSTRUMENT-FAIL") +
  " fix-hidden.asset=" + results["fix-hidden"].asset + " fix-decorative.asset=" + results["fix-decorative"].asset);
