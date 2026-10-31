// VoiceOver-on-a-hosted-runner probe (apple-dev, 2026-10-31), round 2.
// Round 1 (run 41234915775): raw AppleScript started VoiceOver and read its
// speech on macos-15 and macos-26, but the text read was an Automation box
// raised by our own "tell TextEdit"; Guidepup's start() failed on both.
// Round 2: open TextEdit by `open -a` with a file (no Apple Event to TextEdit,
// so no Automation box), find the front app with lsappinfo (no Apple Event),
// and drive only VoiceOver. Question: does VoiceOver read the app's own text?
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const sh = (cmd, args) => {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", timeout: 20000 }).trim();
  } catch (error) {
    return `ERROR ${error.status ?? ""} ${String(error.stderr ?? error.message).trim()}`;
  }
};
const osa = (script) => sh("osascript", ["-e", script]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const front = () => sh("/bin/sh", ["-c", "lsappinfo info -only name `lsappinfo front`"]);
const MARK = "Probe text for VoiceOver";

writeFileSync("probe.txt", MARK + ".\n");
const result = { os: sh("sw_vers", ["-productVersion"]) };
sh("open", ["-a", "TextEdit", "probe.txt"]);
await sleep(4000);
result.frontBefore = front();

sh("open", ["-a", "VoiceOver"]);
await sleep(5000);

const phrases = [];
const read = async () => {
  await sleep(1200);
  phrases.push(osa('tell application "VoiceOver" to return content of last phrase'));
};
await read();
for (let i = 0; i < 10; i += 1) {
  osa('tell application "VoiceOver" to tell vo cursor to move right');
  await read();
}
osa('tell application "VoiceOver" to tell vo cursor to move to first item');
await read();
result.phrases = phrases;
result.frontAfter = front();
result.sawAppText = phrases.some((p) => p.includes(MARK) || p.includes("probe.txt"));
result.sawPermissionBox = phrases.some((p) => p.includes("wants access to control"));
osa('tell application "VoiceOver" to quit');

console.log("PROBE-RESULT " + JSON.stringify(result, null, 2));
console.log(
  "VERDICT " + (result.sawAppText ? "APP-TEXT-READ" : "APP-TEXT-NOT-READ") +
  " box=" + result.sawPermissionBox,
);
