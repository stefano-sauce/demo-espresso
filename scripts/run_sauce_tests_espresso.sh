#!/bin/bash

# ------------------------------------------------------------------
# Runs every Espresso example in .sauce/runner-ex*.yml on Sauce Labs (eu-central-1)
# via saucectl, tagged so the jobs are easy to find in the Sauce Labs UI.
# Safe to call from cron/launchd: it loads credentials and PATH itself.
# ------------------------------------------------------------------

# Project root (this script lives in <repo>/scripts; resolve symlinks so it can be called via ~/scripts)
PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# Credentials are never hardcoded: cron does not load your shell profile, so read the
# `export NAME=value` lines from ~/.zshrc. A value already set in the environment wins.
zshrc_var() {
    sed -n "s/^export $1=//p" "$HOME/.zshrc" 2>/dev/null | tail -1 | tr -d "\"'"
}
for var in SAUCE_USERNAME SAUCE_ACCESS_KEY; do
    [ -z "${!var}" ] && export "$var=$(zshrc_var "$var")"
done
export SAUCE_REGION=eu-central-1

export PATH="/opt/homebrew/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_FILE="${LOG_FILE:-$HOME/sauce_automation_espresso.log}"
# Max wall-clock per example; hard-coded devices (ex4) can otherwise queue indefinitely.
EXAMPLE_TIMEOUT="${EXAMPLE_TIMEOUT:-30m}"
BUILD_DATE="$(date +%Y-%m-%d)"
BASE_TAGS="framework:espresso,cli:saucectl,lang:java,usecase:native-app-android,repo:demo-espresso"
# Real-device suites enable networkCapture + vitals (plus the resigning they need) via appSettings
# in each runner-ex*.yml. Emulators support neither, but saucectl tags a whole run at once, so
# emulator jobs are re-tagged without these after each run (see untag_emulator_jobs).
FEATURE_TAGS="feature:network-capture,feature:device-vitals"
REPORT_DIR="$PROJECT_DIR/reports"   # gitignored

# Replaces the tags of every emulator job in saucectl's JSON report $1 with $2 (no feature tags).
# Emulator jobs are the ones whose build lives under /builds/vdc/ (real devices: /builds/rdc/).
untag_emulator_jobs() {
    local report="$1" tags="$2" ids id
    ids="$("$NODE" -e '
        const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const s of r) if ((s.buildURL || "").includes("/builds/vdc/"))
            for (const a of s.attempts || []) console.log(a.id);' "$report" 2>> "$LOG_FILE")"
    local json="[\"${tags//,/\",\"}\"]"
    for id in $ids; do
        if curl -sf -o /dev/null -u "$SAUCE_USERNAME:$SAUCE_ACCESS_KEY" -X PUT \
                -H "Content-Type: application/json" -d "{\"tags\":$json}" \
                "https://api.$SAUCE_REGION.saucelabs.com/rest/v1/$SAUCE_USERNAME/jobs/$id"; then
            echo "Emulator job $id: tags set to $tags" >> "$LOG_FILE"
        else
            echo "WARNING: could not re-tag emulator job $id" >> "$LOG_FILE"
        fi
    done
}

# Keep the Mac awake for the whole run.
caffeinate -i -w $$ &

echo "--------------------------------------------------" >> "$LOG_FILE"
echo "Starting Sauce Labs Espresso Tests: $(date)" >> "$LOG_FILE"

for var in SAUCE_USERNAME SAUCE_ACCESS_KEY; do
    if [ -z "${!var}" ]; then
        echo "ERROR: $var is not set (export it in ~/.zshrc)." >> "$LOG_FILE"
        exit 1
    fi
done
if ! command -v saucectl > /dev/null; then
    echo "ERROR: saucectl not found on PATH." >> "$LOG_FILE"
    exit 1
fi

cd "$PROJECT_DIR" || { echo "ERROR: Directory $PROJECT_DIR does not exist." >> "$LOG_FILE"; exit 1; }
echo "Changed directory to $PROJECT_DIR" >> "$LOG_FILE"

# Under cron/launchd, macOS privacy controls stop bash from listing ~/Documents, so a
# `.sauce/runner-ex*.yml` glob stays literal. List the configs with node (which has access),
# falling back to the glob when node is unavailable.
NODE="$(command -v node || echo /opt/homebrew/bin/node)"
CONFIGS="$("$NODE" -e '
    const fs = require("fs");
    fs.readdirSync(".sauce").filter(f => /^runner-ex\d+\.yml$/.test(f))
      .sort((a, b) => parseInt(a.slice(9)) - parseInt(b.slice(9)))
      .forEach(f => console.log(".sauce/" + f));' 2>/dev/null)"
[ -z "$CONFIGS" ] && CONFIGS="$(printf '%s\n' .sauce/runner-ex*.yml)"
echo "Configs: $(echo $CONFIGS)" >> "$LOG_FILE"

FAILED=0
for config in $CONFIGS; do
    ex="$(basename "$config" .yml)"   # runner-ex1
    ex="${ex#runner-}"                # ex1
    tags="$BASE_TAGS,example:$ex"
    build="demo-espresso $ex $BUILD_DATE"
    report="$REPORT_DIR/saucectl-report-$ex.json"
    mkdir -p "$REPORT_DIR"; rm -f "$report"
    echo "Running (tags=$tags,$FEATURE_TAGS, build=$build): saucectl run --config $config" >> "$LOG_FILE"
    if saucectl run --config "$config" \
            --region "$SAUCE_REGION" \
            --tags "$tags,$FEATURE_TAGS" \
            --build "$build" \
            --reporters.json.enabled \
            --reporters.json.filename "$report" \
            --timeout "$EXAMPLE_TIMEOUT" >> "$LOG_FILE" 2>&1; then
        echo "SUCCESS: $ex" >> "$LOG_FILE"
    else
        echo "FAILURE: $ex" >> "$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi
    [ -f "$report" ] && untag_emulator_jobs "$report" "$tags"
done

echo "All Espresso tests completed ($FAILED example(s) failed): $(date)" >> "$LOG_FILE"
echo "--------------------------------------------------" >> "$LOG_FILE"
exit $FAILED
