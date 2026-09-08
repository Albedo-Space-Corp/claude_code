#!/usr/bin/env bash
set -euo pipefail

# Albedo plugin marketplace setup for Claude Code.
#
# For machines that already have Claude Code and the Bedrock AWS profiles
# configured. setup_ccb.sh does this same work as its step 7; this script exists
# so an existing install can pick up the marketplace on its own.
#
# The marketplace is a CodeCommit repository cloned over HTTPS, authorized by
# the caller's own AlbedoBedrockUsers role through the AWS CLI git credential
# helper. Nothing long-lived is stored on this machine.
#
# Safe to re-run.
#
# Usage:
#   bash setup-marketplace.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup-marketplace.sh)

# ── Configuration ───────────────────────────────────────────────────────────
AWS_PROFILE_NAME="${ALBEDO_AWS_PROFILE:-prod-it01-bedrock}"
CODECOMMIT_HOST="git-codecommit.us-west-2.amazonaws.com"
MARKETPLACE_REPO="albedo-plugins"
# The trailing .git is mandatory: without it Claude Code classifies the URL as a
# direct marketplace.json download, sends no credentials, and fails with an
# opaque HTTP 401.
MARKETPLACE_URL="https://${CODECOMMIT_HOST}/v1/repos/${MARKETPLACE_REPO}.git"
MARKETPLACE_KEY="albedo-claude-plugin-marketplace"
OFFICIAL_KEY="claude-plugins-official"
CRED_SECTION="credential.${MARKETPLACE_URL}"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
KNOWN_MARKETPLACES="$CLAUDE_DIR/plugins/known_marketplaces.json"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
MARKETPLACE_CLONE="$CLAUDE_DIR/plugins/marketplaces/$MARKETPLACE_KEY"
STAMP="$(date +%Y%m%d_%H%M%S)"

echo "Setting up the Albedo plugin marketplace for Claude Code..."

# ── Prerequisites ───────────────────────────────────────────────────────────
for tool in git aws python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is required but not on PATH." >&2
    echo "Run the full setup first: setup_ccb.sh" >&2
    exit 1
  fi
done

SSO_OK=1
if ! aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" >/dev/null 2>&1; then
  SSO_OK=0
  echo "Warning: no valid session for profile '$AWS_PROFILE_NAME'."
  echo "  Run: aws sso login --profile $AWS_PROFILE_NAME"
  echo "  Continuing; the check at the end will fail until you log in."
fi

# ── Clear any cached credential for this host ───────────────────────────────
# The AWS helper mints a SigV4 password valid for about 15 minutes. A
# general-purpose credential store (macOS keychain, libsecret) that cached one
# keeps serving the dead value, which surfaces as intermittent 403s that logging
# in again never fixes. Purge before reconfiguring, while that store is still
# the helper git consults.
printf 'protocol=https\nhost=%s\npath=v1/repos/%s\n\n' "$CODECOMMIT_HOST" "$MARKETPLACE_REPO" \
  | git credential reject >/dev/null 2>&1 || true
printf 'protocol=https\nhost=%s\n\n' "$CODECOMMIT_HOST" \
  | git credential reject >/dev/null 2>&1 || true
if [ "$(uname -s)" = "Darwin" ]; then
  while security delete-internet-password -s "$CODECOMMIT_HOST" >/dev/null 2>&1; do :; done
fi

# ── Git credential helper ───────────────────────────────────────────────────
# Scoped to this one repository URL so every other remote keeps its own
# configuration, including any other CodeCommit repository that may need a
# different AWS profile.
#
# The empty helper entry before the real one is load-bearing. Git consults
# helpers in configuration order, and the platform credential store is
# registered unscoped, so it would answer first and the AWS helper would never
# run. An empty value resets the inherited list for this repository only.
#
# The profile is pinned rather than inherited from the environment because
# claude-gov runs with AWS_PROFILE set to the GovCloud profile, which cannot
# read this commercial repository.
#
# UseHttpPath earns its place twice: the SigV4 signature covers the repository
# path, and git only matches a URL-scoped section when it sends that path.
git config --global --remove-section "$CRED_SECTION" 2>/dev/null || true
git config --global --add "$CRED_SECTION.helper" ""
git config --global --add "$CRED_SECTION.helper" "!aws --profile $AWS_PROFILE_NAME codecommit credential-helper \$@"
git config --global "$CRED_SECTION.UseHttpPath" true
echo "Git credential helper configured for $MARKETPLACE_REPO."

# ── Register the marketplace ────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR/plugins"
[ -f "$KNOWN_MARKETPLACES" ] && cp "$KNOWN_MARKETPLACES" "$KNOWN_MARKETPLACES.backup.$STAMP"

MARKETPLACE_KEY="$MARKETPLACE_KEY" MARKETPLACE_URL="$MARKETPLACE_URL" \
MARKETPLACE_CLONE="$MARKETPLACE_CLONE" OFFICIAL_KEY="$OFFICIAL_KEY" \
CLAUDE_DIR="$CLAUDE_DIR" KNOWN_MARKETPLACES="$KNOWN_MARKETPLACES" \
python3 - <<'PY'
import json, os
from datetime import datetime, timezone

path = os.environ["KNOWN_MARKETPLACES"]
key = os.environ["MARKETPLACE_KEY"]
official = os.environ["OFFICIAL_KEY"]
claude_dir = os.environ["CLAUDE_DIR"]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

data = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (ValueError, OSError):
        # A corrupt file is rebuilt rather than inherited; the backup taken
        # above is the copy to recover from.
        data = {}

if official not in data:
    data[official] = {
        "source": {"source": "github", "repo": "anthropics/claude-plugins-official"},
        "installLocation": os.path.join(claude_dir, "plugins", "marketplaces", official),
        "lastUpdated": now,
    }

# Merged rather than replaced so a hand-set installLocation, and any field
# Claude Code itself added, survive.
entry = data.get(key, {})
entry["source"] = {"source": "git", "url": os.environ["MARKETPLACE_URL"]}
entry.setdefault("installLocation", os.environ["MARKETPLACE_CLONE"])
entry["lastUpdated"] = now
data[key] = entry

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
echo "Marketplace registered at $MARKETPLACE_URL."

# ── Reconcile settings.json ─────────────────────────────────────────────────
# A marketplace may also be declared in settings.json. When the two disagree
# Claude Code refuses it outright: "its network source differs from the one
# declared for it in settings".
if [ -f "$CLAUDE_SETTINGS" ]; then
  MARKETPLACE_KEY="$MARKETPLACE_KEY" MARKETPLACE_URL="$MARKETPLACE_URL" \
  CLAUDE_SETTINGS="$CLAUDE_SETTINGS" STAMP="$STAMP" \
  python3 - <<'PY'
import json, os, shutil

path = os.environ["CLAUDE_SETTINGS"]
key = os.environ["MARKETPLACE_KEY"]
url = os.environ["MARKETPLACE_URL"]

try:
    with open(path) as f:
        settings = json.load(f)
except (ValueError, OSError):
    raise SystemExit(0)

entry = settings.get("extraKnownMarketplaces", {}).get(key)
if not isinstance(entry, dict) or entry.get("source", {}).get("url") == url:
    raise SystemExit(0)

shutil.copyfile(path, "%s.backup.%s" % (path, os.environ["STAMP"]))
entry["source"] = {"source": "git", "url": url}
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("settings.json marketplace declaration updated to match.")
PY
fi

# ── Verify, then retire the old clone ───────────────────────────────────────
# Verification has to come first. An existing checkout is a working marketplace
# even when its remote is unreachable: Claude Code reads plugins from the working
# tree and needs the remote only to update. Discarding it before the replacement
# is proven would turn "stale but usable" into "no marketplace at all" for anyone
# whose SSO session has lapsed.
echo "Verifying access to the marketplace repository..."
if MARKETPLACE_ERR="$(git ls-remote "$MARKETPLACE_URL" 2>&1 >/dev/null)"; then
  # A checkout whose origin is any other URL cannot pull from the marketplace.
  # The replacement is known good now, so drop it and let Claude Code clone
  # fresh on launch.
  if [ -d "$MARKETPLACE_CLONE" ]; then
    OLD_ORIGIN="$(git -C "$MARKETPLACE_CLONE" remote get-url origin 2>/dev/null || echo "")"
    if [ "$OLD_ORIGIN" != "$MARKETPLACE_URL" ]; then
      rm -rf "$MARKETPLACE_CLONE"
      echo "Removed a stale marketplace clone (origin was ${OLD_ORIGIN:-unknown})."
    fi
  fi
  echo ""
  echo "Done. The Albedo plugin marketplace is registered and reachable."
  echo "Restart Claude Code and run /plugin to browse and install plugins."
else
  # git prefixes the credential helper's own output with a newline, so collapse to
  # one line: otherwise the message below prints with a blank first line and the
  # real reason buried underneath.
  MARKETPLACE_ERR="$(printf '%s' "$MARKETPLACE_ERR" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
  echo "Error: could not reach the marketplace repository." >&2
  case "$MARKETPLACE_ERR" in
    *403*)
      echo "  403 — credentials were rejected." >&2
      if [ "$SSO_OK" = "0" ]; then
        echo "  Run: aws sso login --profile $AWS_PROFILE_NAME   then re-run this script." >&2
      else
        echo "  Your role may lack codecommit:GitPull. Ask in #it-help with this message." >&2
      fi
      ;;
    *"not found"*|*404*)
      echo "  Repository not found. Expected: $MARKETPLACE_URL" >&2 ;;
    *)
      echo "  $MARKETPLACE_ERR" >&2 ;;
  esac
  echo "" >&2
  echo "  Any marketplace already on this machine was left untouched, so /plugin" >&2
  echo "  keeps working from its last sync. Re-run this script once the above is fixed." >&2
  exit 1
fi
