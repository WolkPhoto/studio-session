#!/bin/bash
# Builds and opens Proof.
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="Proof" BUNDLE_ID="com.digitools.proof" BRAND="proof" bash ./build.command
