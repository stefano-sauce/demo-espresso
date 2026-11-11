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

FAILED=0
for config in .sauce/runner-ex*.yml; do
    ex="$(basename "$config" .yml)"   # runner-ex1
    ex="${ex#runner-}"                # ex1
    tags="$BASE_TAGS,example:$ex"
    build="demo-espresso $ex $BUILD_DATE"
    echo "Running (tags=$tags, build=$build): saucectl run --config $config" >> "$LOG_FILE"
    if saucectl run --config "$config" \
            --region "$SAUCE_REGION" \
            --tags "$tags" \
            --build "$build" \
            --timeout "$EXAMPLE_TIMEOUT" >> "$LOG_FILE" 2>&1; then
        echo "SUCCESS: $ex" >> "$LOG_FILE"
    else
        echo "FAILURE: $ex" >> "$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi
done

echo "All Espresso tests completed ($FAILED example(s) failed): $(date)" >> "$LOG_FILE"
echo "--------------------------------------------------" >> "$LOG_FILE"
exit $FAILED
