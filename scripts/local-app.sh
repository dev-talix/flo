#!/bin/bash
# Build/install the local test app, or switch between installed channels.
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-install}"
case "$ACTION" in
    install|local|production) ;;
    *) echo "Usage: $0 [install|local|production]" >&2; exit 2 ;;
esac

LOCAL_APP="/Applications/Flo Local.app"
# Sparkle updates in place, so installs from before the rename keep the old
# bundle name until someone reinstalls from the DMG.
PRODUCTION_APP="/Applications/Flo.app"
if [[ ! -d "$PRODUCTION_APP" && -d /Applications/Walkie.app ]]; then
    PRODUCTION_APP="/Applications/Walkie.app"
elif [[ ! -d "$PRODUCTION_APP" && -d /Applications/LocalFlow.app ]]; then
    PRODUCTION_APP="/Applications/LocalFlow.app"
fi
if [[ "$ACTION" == "install" ]]; then
    VERSION="$(python3 -c 'import json; print(json.load(open(".github/.release-please-manifest.json"))["."])')"
    LOCAL_BUILD=1 UPDATER_ENABLED=false SKIP_PREWARM=1 APP_VERSION="$VERSION" ./scripts/make-app.sh
    codesign --verify --deep --strict "build/Flo Local.app"
fi

if [[ "$ACTION" == "production" ]]; then
    TARGET_APP="$PRODUCTION_APP"
else
    TARGET_APP="$LOCAL_APP"
    if [[ "$ACTION" == "local" && ! -d "$TARGET_APP" ]]; then
        if [[ -d "/Applications/Walkie Local.app" ]]; then
            TARGET_APP="/Applications/Walkie Local.app"
        elif [[ -d "/Applications/LocalFlow Local.app" ]]; then
            TARGET_APP="/Applications/LocalFlow Local.app"
        fi
    fi
fi
if [[ "$ACTION" != "install" && ! -d "$TARGET_APP" ]]; then
    echo "error: $TARGET_APP is not installed" >&2
    exit 1
fi

# Older installed builds lack the app's Quit guard. Check every running
# bundle, request normal Quit, and refuse replacement until both channels exit.
python3 scripts/app-lifecycle.py

if [[ "$ACTION" == "install" ]]; then
    # Seed preferences once. Later installs preserve local settings; history
    # stays separate. Do not print vocabulary, corrections, or other values.
    python3 - <<'PY'
import plistlib
import subprocess
import tempfile

local_id = 'app.talix.localflow.local'
existing = subprocess.run(['/usr/bin/defaults', 'export', local_id, '-'], capture_output=True)
if existing.returncode != 0 or not plistlib.loads(existing.stdout):
    production = subprocess.run(['/usr/bin/defaults', 'export', 'app.talix.localflow', '-'], capture_output=True)
    settings = plistlib.loads(production.stdout) if production.returncode == 0 else {}
    settings = {k: v for k, v in settings.items() if not k.startswith('SU') and k not in ('loginItemSetupDone', 'diagLogPrivacyVersion')}
    settings['automaticUpdates'] = False
    with tempfile.NamedTemporaryFile(suffix='.plist') as f:
        plistlib.dump(settings, f)
        f.flush()
        subprocess.run(['/usr/bin/defaults', 'import', local_id, f.name], check=True, stdout=subprocess.DEVNULL)
PY
    # Stage on the same volume. Preserve the previous local app for recovery.
    STAGING="$(mktemp -d /Applications/.flo-local.XXXXXX)"
    ditto "build/Flo Local.app" "$STAGING/Flo Local.app"
    codesign --verify --deep --strict "$STAGING/Flo Local.app"
    if [[ -e "$LOCAL_APP" ]]; then
        mv "$LOCAL_APP" "$STAGING/Previous Flo Local.app"
        echo "Previous local build saved in $STAGING"
    fi
    # Pre-rename copy: same bundle ID, so it must not stay next to the new one.
    for LEGACY_LOCAL_NAME in "Walkie Local" "LocalFlow Local"; do
        if [[ -e "/Applications/$LEGACY_LOCAL_NAME.app" ]]; then
            mv "/Applications/$LEGACY_LOCAL_NAME.app" "$STAGING/Previous $LEGACY_LOCAL_NAME.app"
            echo "Pre-rename local build saved in $STAGING"
        fi
    done
    mv "$STAGING/Flo Local.app" "$LOCAL_APP"
    rmdir "$STAGING" 2>/dev/null || true
fi

if [[ "$ACTION" == "install" ]]; then
    python3 scripts/wait-for-local-ready.py
else
    open "$TARGET_APP"
    echo "Opened $TARGET_APP"
fi
echo "Local diagnostics: ~/Library/Logs/LocalFlow-Local-diag.log"
