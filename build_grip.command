#!/bin/bash
# Builds and opens Grip.
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="Studio Session" BUNDLE_ID="com.digitools.grip" BRAND="grip" bash ./build.command
