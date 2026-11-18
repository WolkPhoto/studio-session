#!/bin/bash
# Puts this version of Studio Session on GitHub.
# First run: signs you in to GitHub (in your browser), creates the repository,
# and keeps a permanent copy in ~/Developer/StudioSession. Later runs copy the
# newest version folder into it, commit, and push. Nothing else on your Mac is touched.
set -uo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
REPO_DIR="$HOME/Developer/StudioSession"
VERSION="$(sed -nE 's/^VERSION="([^"]+)"/\1/p' build.command)"

stop() { echo ""; echo "STOPPED: $1"; exit 1; }
TRAILER=$'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01TANehL37xtRD4NS5Ypnp7E'

echo "=== Studio Session $VERSION to GitHub ==="

# 1. GitHub's command-line tool
if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing GitHub's command-line tool (gh) with Homebrew..."
    brew install gh || stop "Couldn't install gh."
  else
    cat <<'MSG'

This needs GitHub's command-line tool, "gh". Install it once:
  1. Go to https://cli.github.com and download the macOS installer.
  2. Open it and follow the steps.
  3. Run this again.
MSG
    exit 1
  fi
fi

# 2. Signed in to GitHub (opens your browser the first time)
if ! gh auth status >/dev/null 2>&1; then
  echo "Signing in to GitHub. Pick: GitHub.com, HTTPS, and log in with a web browser."
  gh auth login --hostname github.com --git-protocol https --web || stop "GitHub sign-in didn't finish."
fi
gh auth setup-git >/dev/null 2>&1 || true
OWNER="$(gh api user --jq .login 2>/dev/null)" || stop "Couldn't read your GitHub username."

# 3. First run: make the repository
if [ ! -d "$REPO_DIR/.git" ]; then
  echo ""
  read -r -p "Repository name [studio-session]: " NAME
  NAME="${NAME:-studio-session}"
  echo ""
  echo "Should the code be public?"
  echo "  Private: only you can see the code. Release DMGs go in a separate public"
  echo "           repository ($NAME-releases) so Check for Updates can reach them."
  echo "  Public:  anyone can see the code and the releases."
  read -r -p "Type private or public [private]: " VIS
  VIS="${VIS:-private}"
  mkdir -p "$REPO_DIR"
  rsync -a --exclude '.git' --exclude '*.app' --exclude '*.zip' --exclude '*.dmg' \
    --exclude 'build_log.txt' --exclude 'release_log.txt' "$HERE/" "$REPO_DIR/"
  cd "$REPO_DIR" || stop "Couldn't open $REPO_DIR."
  git init -q -b main
  if [ "$VIS" = "public" ]; then
    echo "$OWNER/$NAME" > UPDATE_REPO.txt
  else
    echo "$OWNER/$NAME-releases" > UPDATE_REPO.txt
  fi
  git add -A
  git commit -q -m "Studio Session $VERSION" -m "$TRAILER" || stop "Couldn't make the first commit."
  gh repo create "$OWNER/$NAME" "--$VIS" --source . --remote origin --push \
    --description "Studio Session: backups and shoot-day tools for digital techs (macOS)" \
    || stop "Couldn't create $OWNER/$NAME on GitHub."
  if [ "$VIS" != "public" ]; then
    gh repo create "$OWNER/$NAME-releases" --public \
      --description "Studio Session downloads (signed, notarized DMGs)" >/dev/null 2>&1 \
      || echo "Note: $OWNER/$NAME-releases already exists or couldn't be made."
  fi
  echo ""
  echo "Done: https://github.com/$OWNER/$NAME"
  echo "Check for Updates will look at: https://github.com/$(cat UPDATE_REPO.txt)/releases"
  echo "Copy UPDATE_REPO.txt into each new version folder, or the next publish will do it for you."
  cp UPDATE_REPO.txt "$HERE/UPDATE_REPO.txt"
  exit 0
fi

# 4. Later runs: bring this version into the repository and push
cd "$REPO_DIR" || stop "Couldn't open $REPO_DIR."
KEEP_REPO="$(cat UPDATE_REPO.txt 2>/dev/null)"
rsync -a --delete --exclude '.git' --exclude '*.app' --exclude '*.zip' --exclude '*.dmg' \
  --exclude 'build_log.txt' --exclude 'release_log.txt' --exclude 'UPDATE_REPO.txt' "$HERE/" "$REPO_DIR/"
[ -n "$KEEP_REPO" ] && echo "$KEEP_REPO" > UPDATE_REPO.txt && cp UPDATE_REPO.txt "$HERE/UPDATE_REPO.txt"
git add -A
if git diff --cached --quiet; then
  echo "Nothing changed since the last publish."
  exit 0
fi
git commit -q -m "Studio Session $VERSION" -m "$TRAILER" || stop "Couldn't commit."
git push -q origin main || stop "Couldn't push to GitHub."
echo "Pushed Studio Session $VERSION to $(git remote get-url origin)"
