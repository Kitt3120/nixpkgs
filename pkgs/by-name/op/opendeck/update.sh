#!/usr/bin/env bash
set -euo pipefail

# OpenDeck update script
# Usage: ./update.sh <version>
# Example: ./update.sh 2.7.2

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 2.7.2"
    exit 1
fi

VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Updating OpenDeck to version $VERSION"

# Step 1: Fetch source and get hash
echo "==> Fetching source hash..."
SRC_HASH=$(nix-prefetch-url --unpack "https://github.com/nekename/opendeck/archive/refs/tags/v${VERSION}.tar.gz")
echo "    srcHash = \"sha256-${SRC_HASH}\""

# Step 2: Download source for lock file generation
echo "==> Downloading source..."
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

curl -sL "https://github.com/nekename/opendeck/archive/refs/tags/v${VERSION}.tar.gz" | tar xz -C "$TEMP_DIR"
SRC_DIR="$TEMP_DIR/opendeck-${VERSION}"

# Step 3: Generate main Cargo.lock
echo "==> Generating main Cargo.lock..."
cd "$SRC_DIR/src-tauri"
cargo generate-lockfile
cp Cargo.lock "$SCRIPT_DIR/Cargo.lock"
echo "    ✓ Cargo.lock updated"

# Step 4: Generate starterpack Cargo.lock
echo "==> Generating starterpack Cargo.lock..."
cd "$SRC_DIR/plugins/com.amansprojects.starterpack.sdPlugin"

# Check enigo version in Cargo.toml
ENIGO_REV=$(grep -oP 'git = "https://github.com/enigo-rs/enigo.git", rev = "\K[^"]+' Cargo.toml || echo "")
if [ -n "$ENIGO_REV" ]; then
    echo "    Found enigo rev: $ENIGO_REV"
    
    # Fetch enigo and generate its Cargo.lock
    echo "==> Fetching enigo..."
    ENIGO_DIR="$TEMP_DIR/enigo"
    git clone --quiet https://github.com/enigo-rs/enigo.git "$ENIGO_DIR"
    cd "$ENIGO_DIR"
    git checkout --quiet "$ENIGO_REV"
    
    ENIGO_HASH=$(nix-prefetch-git --url https://github.com/enigo-rs/enigo.git --rev "$ENIGO_REV" 2>/dev/null | grep -oP '"hash": "\K[^"]+')
    echo "    enigoHash = \"$ENIGO_HASH\""
    
    echo "==> Generating enigo Cargo.lock..."
    cargo generate-lockfile
    cp Cargo.lock "$SCRIPT_DIR/enigo-Cargo.lock"
    echo "    ✓ enigo-Cargo.lock updated"
    
    # Now generate starterpack lock with path dependency
    cd "$SRC_DIR/plugins/com.amansprojects.starterpack.sdPlugin"
    sed -i "s|git = \"https://github.com/enigo-rs/enigo.git\", rev = \"[^\"]*\"|path = \"$ENIGO_DIR\"|g" Cargo.toml
fi

cargo generate-lockfile
cp Cargo.lock "$SCRIPT_DIR/starterpack-Cargo.lock"
echo "    ✓ starterpack-Cargo.lock updated"

# Step 5: Calculate FOD hashes (these will fail first time, need manual update)
echo "==> Calculating FOD hashes..."
echo "    You need to update package.nix with the hashes above, then run:"
echo "    nix-build -A opendeck.frontend 2>&1 | grep 'got:'"
echo "    nix-build -A opendeck.pluginDenoDeps 2>&1 | grep 'got:'"
echo ""
echo "    Or let them fail and copy the 'got:' hashes from the error messages"

# Step 6: Summary
echo ""
echo "==> Summary of changes needed in package.nix:"
echo "    version = \"$VERSION\";"
echo "    srcHash = \"sha256-${SRC_HASH}\";"
if [ -n "$ENIGO_REV" ]; then
    echo "    enigoRev = \"$ENIGO_REV\";"
    echo "    enigoHash = \"$ENIGO_HASH\";"
fi
echo ""
echo "==> Lock files updated:"
echo "    ✓ Cargo.lock"
echo "    ✓ starterpack-Cargo.lock"
if [ -n "$ENIGO_REV" ]; then
    echo "    ✓ enigo-Cargo.lock"
fi
echo ""
echo "==> Next steps:"
echo "    1. Update version and hashes in package.nix"
echo "    2. Try building: nix-build -A opendeck"
echo "    3. Update frontendHash and pluginDenoDepsHash from build errors"
echo "    4. Build again until it works"
