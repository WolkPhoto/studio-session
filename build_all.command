#!/bin/bash
# Builds Studio Session. Keeps going if one fails, saves everything to
# build_log.txt, and prints any errors at the end.
cd "$(dirname "$0")"
LOG="$PWD/build_log.txt"
: > "$LOG"
echo "Running backup tests..."
if ! bash ./RUN_FAST_BACKUP_TESTS.command >>"$LOG" 2>&1; then
  echo ""
  echo "The backup tests did not pass, so nothing was built."
  echo "Send build_log.txt from this folder to Claude."
  grep -n "error:\|FAIL\|Error" "$LOG" | head -40
  exit 1
fi
BUILT=()
FAILED=()
build_one() {
  local key="$1" name="$2" bundle="$3"
  echo "Building $name..."
  echo "" >>"$LOG"
  echo "===== $name =====" >>"$LOG"
  if SKIP_TESTS=1 NO_OPEN=1 APP_NAME="$name" BUNDLE_ID="$bundle" BRAND="$key" bash ./build.command >>"$LOG" 2>&1; then
    BUILT+=("$name")
  else
    FAILED+=("$name")
  fi
}
build_one grip "Studio Session" "com.digitools.grip"
echo ""
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "Studio Session built. Opening it now."
  for name in "${BUILT[@]}"; do open -n "$PWD/$name.app"; done
else
  echo "Built: ${BUILT[*]:-none}"
  echo "Did not build: ${FAILED[*]}"
  echo ""
  echo "First errors:"
  grep -n "error:" "$LOG" | sort -u -t: -k3 | head -30
  echo ""
  echo "Send build_log.txt from this folder to Claude."
  for name in "${BUILT[@]+"${BUILT[@]}"}"; do open -n "$PWD/$name.app"; done
fi
