#!/bin/bash
# Generates deploy-ready files for remote server hosting
# Clones vue-after-free from GitHub, builds full + lite, creates STORE ZIPs
#
# Usage: ./deploy.sh <ip_or_domain> [port]
#        ./deploy.sh clean
# Example: ./deploy.sh earthonion.com
#          ./deploy.sh earthonion.com 8080

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$1" = "clean" ]; then
    rm -rf "$SCRIPT_DIR/deploy"
    echo "Cleaned deploy/"
    exit 0
fi

if [ -z "$1" ]; then
    HOST=$(python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.connect(('10.255.255.255',1)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "127.0.0.1")
    PORT=42069
else
    HOST="$1"
    PORT="${2:-80}"
fi
OUT_DIR="$SCRIPT_DIR/deploy"
ENCRYPT="$SCRIPT_DIR/savedata/encrypt.py"

# Build base URL
if [ "$PORT" = "80" ]; then
    BASE_URL="http://$HOST"
    MANIFEST_SRC="http://$HOST/download0/serve.js.aes"
else
    BASE_URL="http://$HOST:$PORT"
    MANIFEST_SRC="http://$HOST:$PORT/download0/serve.js.aes"
fi

echo "Deploying for: $BASE_URL"
echo ""

# ============================================================
# Step 1: Clone and build vue-after-free from GitHub
# ============================================================
TMPDIR=$(mktemp -d)
REPO_DIR="$TMPDIR/vue-after-free"

echo "=== Cloning Vuemony/vue-after-free ==="
git clone --depth 1 https://github.com/Vuemony/vue-after-free.git "$REPO_DIR"
echo ""

echo "=== Installing dependencies ==="
(cd "$REPO_DIR" && npm install)
echo ""

echo "=== Building (npm run build) ==="
(cd "$REPO_DIR" && npm run build)
echo ""

# ============================================================
# Step 2: Copy assets into dist (mirrors CI build.yml)
# ============================================================
DIST="$REPO_DIR/dist"
SRC="$REPO_DIR/src"

echo "=== Copying assets to dist ==="

# Payloads (.elf, .bin)
mkdir -p "$DIST/download0/payloads"
cp "$SRC"/download0/payloads/*.elf "$DIST/download0/payloads/" 2>/dev/null || true
cp "$SRC"/download0/payloads/*.bin "$DIST/download0/payloads/" 2>/dev/null || true

# img, sfx, vid directories
cp -r "$SRC/download0/img" "$DIST/download0/" 2>/dev/null || true
cp -r "$SRC/download0/sfx" "$DIST/download0/" 2>/dev/null || true
cp -r "$SRC/download0/vid" "$DIST/download0/" 2>/dev/null || true

# .aes files (serve.js.aes, dummy_psn.json.aes)
cp "$SRC"/download0/*.aes "$DIST/download0/" 2>/dev/null || true

# Replace version string
find "$DIST" -type f -name '*.js' -exec sed -i "s/%VERSION_STRING%/main/g" {} +

echo "  payloads, img, sfx, vid, .aes copied"
echo ""

# ============================================================
# Step 3: Build lite variant (mirrors CI build.yml)
# ============================================================
DIST_LITE="$REPO_DIR/dist-lite"

echo "=== Building lite variant ==="
mkdir -p "$DIST_LITE/download0"

for f in serve.js.aes dummy_psn.json.aes loader.js userland.js types.js kernel.js \
         lapse.js netctrl_c0w_twins.js binloader.js check-jailbroken.js defs.js; do
    cp "$DIST/download0/$f" "$DIST_LITE/download0/" 2>/dev/null || echo "  warn: $f not found"
done

# Hardcoded lite config
cat > "$DIST_LITE/download0/config.json" <<'LITECONF'
{
    "config": {
        "autolapse": true,
        "autopoop": false,
        "autoclose": true,
        "autoclose_delay": 0,
        "music": false,
        "jb_behavior": 0
    },
    "payloads": []
}
LITECONF

echo "  lite variant built"
echo ""

# ============================================================
# Step 4: Create STORE-only ZIPs for installer
# ============================================================
mkdir -p "$OUT_DIR/download0"
mkdir -p "$OUT_DIR/savedata"

echo "=== full.zip (STORE) ==="
(cd "$DIST/download0" && zip -0 -r "$OUT_DIR/download0/full.zip" .)
echo ""

echo "=== lite.zip (STORE) ==="
(cd "$DIST_LITE/download0" && zip -0 -r "$OUT_DIR/download0/lite.zip" .)
echo ""

# ============================================================
# Step 5: Copy bootstrap files (needed by Phase 1 XHR)
# ============================================================
echo "=== Bootstrap files ==="
for f in types.js defs.js userland.js; do
    cp "$DIST/download0/$f" "$OUT_DIR/download0/$f"
    echo "  copied $f"
done
echo ""

# ============================================================
# Step 6: Patch serve.js.aes (installer entry point)
# ============================================================
echo "=== serve.js.aes ==="
sed -e "s|REPLACE_IP|$HOST|g" \
    -e "s|REPLACE_PORT|$PORT|g" \
    "$SCRIPT_DIR/serve.js.aes" > "$OUT_DIR/download0/serve.js.aes"
echo ""

# ============================================================
# Step 7: Patch manifest.aes
# ============================================================
echo "=== manifest.aes ==="
cat > "$OUT_DIR/manifest.aes" <<MEOF
{"app_version":"1.29","override":true,"scripts":[{"src":"$MANIFEST_SRC","version":"555"}]}
MEOF
echo ""

# ============================================================
# Step 8: Patch and encrypt localstorage
# ============================================================
if [ -f "$SCRIPT_DIR/savedata/localstorage" ]; then
    echo "=== localstorage.aes ==="
    sed -e "s|REPLACE_IP|$HOST|g" -e "s|REPLACE_PORT|$PORT|g" \
        "$SCRIPT_DIR/savedata/localstorage" > "$OUT_DIR/savedata/localstorage"
    python3 "$ENCRYPT" "$OUT_DIR/savedata/localstorage"
    rm "$OUT_DIR/savedata/localstorage"
    echo ""
fi

# ============================================================
# Cleanup
# ============================================================
echo "=== Cleaning up ==="
rm -rf "$TMPDIR"
echo ""

echo "=== Done ==="
echo ""
echo -e "Save file in \033[32m$OUT_DIR/savedata/\033[0m"
echo ""
echo -e "Serving installer on \033[31m$HOST:$PORT\033[0m..."
python3 "$SCRIPT_DIR/server.py" "$PORT"
