#!/bin/bash
# Builds and opens Wrap.
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="Wrap" BUNDLE_ID="com.digitools.wrap" BRAND="wrap" bash ./build.command
