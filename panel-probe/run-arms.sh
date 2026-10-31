#!/bin/bash
# Runs the panel probe's arms on a hosted runner and grades each one.
# Usage: panel-probe/run-arms.sh <build dir> <records dir>
# Arms, in order: CANCEL-KEY, KEY, CANCEL-AX, AX. Each launch gets its own
# chosen/sibling folder pair under ~/panelprobe/<arm>/.
# Verdicts: GRANTS, DOES-NOT-GRANT, PANEL-IGNORES-<route>, CANCEL-OK, VOID,
# NOT-RUN(<why>), UNEXPECTED(<what>). Never sends Apple Events to the probe app;
# the only Apple Events are the osascript fallbacks to System Events.
set -uo pipefail
BUILD="$(cd "${1:?build dir}" && pwd)"
RECORDS="${2:?records dir}"
mkdir -p "$RECORDS"
RECORDS="$(cd "$RECORDS" && pwd)"
APP="$BUILD/PanelProbe.app"
DRIVER="$BUILD/panel-driver"
CONTAINER="$HOME/Library/Containers/dev.probe.a11y.panel/Data"
SUMMARY="$RECORDS/verdicts.txt"
: > "$SUMMARY"
PREVIOUS="-"

# Screenshots only on a GitHub runner. On a person's Mac, screencapture raises a
# Screen Recording permission box for the calling program (seen 2026-10-31).
shot() { if [ -n "${GITHUB_ACTIONS:-}" ]; then screencapture -x "$1" || true; fi; }

note() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RECORDS/driver.log"; }

# wait_for <file> <tag> <seconds>: true when a line with " <tag>" appears
wait_for() {
  local file="$1" tag="$2" limit="$3" waited=0
  while [ "$waited" -lt $((limit * 4)) ]; do
    if [ -f "$file" ] && grep -q "^[0-9]* $tag" "$file"; then return 0; fi
    sleep 0.25
    waited=$((waited + 1))
  done
  return 1
}

route_press() { # route_press <route> <pid> <what: go|open|cancel>
  local route="$1" pid="$2" what="$3"
  case "$route:$what" in
    key:go|key:open) "$DRIVER" key return ;;
    key:cancel) "$DRIVER" key escape ;;
    key-osa:go|key-osa:open) osascript -e 'tell application "System Events" to key code 36' && echo "OSA key 36" ;;
    key-osa:cancel) osascript -e 'tell application "System Events" to key code 53' && echo "OSA key 53" ;;
    ax:go) "$DRIVER" press "$pid" Go ;;
    ax:open) "$DRIVER" press "$pid" Open ;;
    ax:cancel) "$DRIVER" press "$pid" Cancel ;;
    ax-osa:go) osascript -e 'tell application "System Events" to tell process "PanelProbe" to click button "Go" of window "PanelProbe"' && echo "OSA click Go" ;;
    ax-osa:open) osascript -e 'tell application "System Events" to tell process "PanelProbe" to click button "Open" of window 1' && echo "OSA click Open" ;;
    ax-osa:cancel) osascript -e 'tell application "System Events" to tell process "PanelProbe" to click button "Cancel" of window 1' && echo "OSA click Cancel" ;;
  esac
}

verdict() { # verdict <arm> <text>
  note "VERDICT $1 $2"
  echo "$1 $2" >> "$SUMMARY"
}

run_arm() { # run_arm <ARM> <route key|ax> <action open|cancel>
  local arm="$1" route="$2" action="$3"
  local base="$HOME/panelprobe/$arm"
  rm -rf "$base"
  mkdir -p "$base/chosen" "$base/sibling"
  echo "inside $arm" > "$base/chosen/inside.txt"
  echo "outside $arm" > "$base/sibling/outside.txt"
  local chosen sibling results pid
  chosen="$(cd "$base/chosen" && pwd -P)"
  sibling="$(cd "$base/sibling" && pwd -P)"
  results="$CONTAINER/results-$arm.txt"
  rm -f "$results"
  note "ARM $arm route=$route action=$action chosen=$chosen previous=$PREVIOUS"

  open -n "$APP" --args "$arm" "$chosen" "$sibling" "$PREVIOUS"
  sleep 2
  pid="$(pgrep -n -f "MacOS/PanelProbe $arm ")"
  note "pid=$pid"
  if [ -z "$pid" ]; then verdict "$arm" "NOT-RUN(no-process)"; return; fi

  if ! wait_for "$results" READY 6; then
    if grep -q "^[0-9]* END" "$results" 2>/dev/null; then :; else
      note "not ready after 8 s: raising by AX"
      "$DRIVER" raise "$pid" 2>&1 | tee -a "$RECORDS/driver.log"
      wait_for "$results" READY 25
    fi
  fi
  if ! grep -q "^[0-9]* READY" "$results" 2>/dev/null; then
    grade "$arm" "$action" "$results" "NOT-RUN(not-ready)"; finish_arm "$arm" "$pid" "$chosen"; return
  fi

  # Route control: press Go by the arm's route; fall back to the osascript route.
  route_press "$route" "$pid" go 2>&1 | tee -a "$RECORDS/driver.log"
  if ! wait_for "$results" ROUTE-OK 6; then
    note "route $route did not reach Go; trying $route-osa"
    route="$route-osa"
    route_press "$route" "$pid" go 2>&1 | tee -a "$RECORDS/driver.log"
    if ! wait_for "$results" ROUTE-OK 6; then
      grade "$arm" "$action" "$results" "NOT-RUN(route-control)"; finish_arm "$arm" "$pid" "$chosen"; return
    fi
  fi
  note "ROUTE-OK by $route"
  if ! wait_for "$results" PANEL-SHOWN 5; then
    grade "$arm" "$action" "$results" "NOT-RUN(no-panel)"; finish_arm "$arm" "$pid" "$chosen"; return
  fi
  sleep 3
  "$DRIVER" windows > "$RECORDS/windows-$arm.txt" 2>&1
  "$DRIVER" dump "$pid" > "$RECORDS/dump-$arm.txt" 2>&1
  shot "$RECORDS/panel-$arm.png"

  local press_out
  press_out="$(route_press "$route" "$pid" "$action" 2>&1)"
  echo "$press_out" | tee -a "$RECORDS/driver.log"
  if echo "$press_out" | grep -q TARGET-NOT-FOUND; then
    grade "$arm" "$action" "$results" "NOT-RUN(target-not-found)"; finish_arm "$arm" "$pid" "$chosen"; return
  fi

  if wait_for "$results" END 30; then
    grade "$arm" "$action" "$results" ""
  else
    # The panel did not answer. Its own log says it is still open (PANEL-SHOWN,
    # no RESPONSE, no PANEL-TIMEOUT). Tail: the cancel twin by the same route,
    # so "the panel ignores this press" is told apart from "input does not reach it".
    shot "$RECORDS/ignored-$arm.png"
    "$DRIVER" windows > "$RECORDS/windows-ignored-$arm.txt" 2>&1
    if [ "$action" = open ]; then
      note "no completion in 30 s; sending the cancel twin by $route"
      route_press "$route" "$pid" cancel 2>&1 | tee -a "$RECORDS/driver.log"
      if wait_for "$results" END 15 && grep -q "RESPONSE cancel" "$results"; then
        grade "$arm" "$action" "$results" "PANEL-IGNORES-$route(cancel-twin-works)"
      else
        grade "$arm" "$action" "$results" "NOT-RUN(input-does-not-reach-panel:$route)"
      fi
    else
      grade "$arm" "$action" "$results" "NOT-RUN(cancel-not-answered:$route)"
    fi
  fi
  finish_arm "$arm" "$pid" "$chosen"
}

grade() { # grade <arm> <action> <results> <forced verdict or empty>
  local arm="$1" action="$2" results="$3" forced="$4"
  if [ -f "$results" ]; then cp "$results" "$RECORDS/"; fi
  if grep -q "^[0-9]* VOID" "$results" 2>/dev/null; then
    verdict "$arm" "VOID($(grep -o 'VOID reason=[^ ]*' "$results" | head -1))"; return
  fi
  if [ -n "$forced" ]; then verdict "$arm" "$forced"; return; fi
  local result
  result="$(grep '^[0-9]* RESULT' "$results" | head -1)"
  case "$action:$result" in
    cancel:*response=cancel*) verdict "$arm" "CANCEL-OK" ;;
    cancel:*) verdict "$arm" "UNEXPECTED($result)" ;;
    open:*response=cancel*) verdict "$arm" "UNEXPECTED(cancel-on-open)" ;;
    open:*"rIn=ok rList=ok g2=ok rSib=refused wSib=refused"*) verdict "$arm" "GRANTS" ;;
    open:*rIn=refused*|open:*g2=refused*) verdict "$arm" "DOES-NOT-GRANT($result)" ;;
    *) verdict "$arm" "UNEXPECTED($result)" ;;
  esac
}

finish_arm() { # finish_arm <arm> <pid> <chosen>
  kill "$2" 2>/dev/null
  sleep 1
  kill -9 "$2" 2>/dev/null
  PREVIOUS="$3"
}

"$DRIVER" trusted 2>&1 | tee -a "$RECORDS/driver.log"
run_arm CANCEL-KEY key cancel
run_arm KEY key open
run_arm CANCEL-AX ax cancel
run_arm AX ax open
echo "---- verdicts"
cat "$SUMMARY"
