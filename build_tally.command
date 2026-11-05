#!/bin/bash
# Builds and opens Tally.
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="Tally" BUNDLE_ID="com.digitools.tally" BRAND="tally" bash ./build.command
