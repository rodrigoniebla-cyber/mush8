#!/bin/bash
# Mush8 - build-ipa-mac.sh
# Builds Mush8.ipa on your own Mac from game files already on it, then deletes
# everything it downloaded or built. Only the .ipa is kept, on your Desktop.
#
#   bash build-ipa-mac.sh                 # pick the files in a Finder window
#   bash build-ipa-mac.sh FILE [FILE ...] # or name them
#
# Pick prod.keys, the base game and update .nsp files (and dlc.nsp if you have
# it), or .zip / .rar / .7z archives holding them. Your files are never moved
# or changed: the build works on instant APFS copies of them.
#
# Needs Xcode 26 or newer, any copy of it. Everything else (Rust, XcodeGen,
# 7-Zip, the source code) goes into one temporary folder that is deleted when
# the script ends, whether the build worked, failed or you pressed Ctrl-C.
set -euo pipefail

REPO="${MUSH8_REPO:-https://github.com/rodrigoniebla-cyber/mush8.git}"
REF="${MUSH8_REF:-main}"
TOOLCHAIN=1.98.1
SEVENZIP_URL=https://github.com/ip7z/7zip/releases/download/25.01/7z2501-mac.tar.xz
XCODEGEN_URL=https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script is for macOS"

# --- Xcode -------------------------------------------------------------------
# Any copy of Xcode works (App Store, a .xip from developer.apple.com, Xcodes,
# a beta), wherever it is and whatever it's called. The newest one found is
# used; set MUSH8_XCODE=/path/to/Xcode.app to pick one yourself.
is_xcode() { [ -x "$1/Contents/Developer/usr/bin/xcodebuild" ] && [ -d "$1/Contents/Developer/Platforms/iPhoneOS.platform" ]; }
xcode_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo 0; }
find_xcode() {
  local a sel
  {
    sel="$(xcode-select -p 2>/dev/null || true)"
    case "$sel" in */Contents/Developer) echo "${sel%/Contents/Developer}" ;; esac
    mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true
    for a in /Applications/*.app /Applications/*/*.app "$HOME"/Applications/*.app \
      "$HOME"/Downloads/*.app "$HOME"/Downloads/*/*.app "$HOME"/Desktop/*.app; do
      echo "$a"
    done
  } | while IFS= read -r a; do
    if is_xcode "$a"; then printf '%s\t%s\n' "$(xcode_version "$a")" "$a"; fi
  done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | cut -f2-
}

XCODE_APP="${MUSH8_XCODE:-}"
if [ -z "$XCODE_APP" ]; then XCODE_APP="$(find_xcode)"; fi
if [ -z "$XCODE_APP" ]; then
  echo "Couldn't find Xcode on this Mac; choose it in the window that opens."
  XCODE_APP="$(osascript -e 'POSIX path of (choose file with prompt "Where is Xcode? (Xcode 26 or newer)" of type {"com.apple.application-bundle"} default location (path to applications folder))' 2>/dev/null)" \
    || die "no Xcode chosen. Xcode 26 or newer is needed (App Store, or a .xip from developer.apple.com/download)."
fi
XCODE_APP="${XCODE_APP%/}"
is_xcode "$XCODE_APP" || die "$XCODE_APP isn't a full Xcode with the iOS SDK"
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
XCODE_VERSION="$("$XCODEBUILD" -version | awk 'NR==1 {print $2}')"
[ "${XCODE_VERSION%%.*}" -ge 26 ] 2>/dev/null \
  || die "the newest Xcode found is $XCODE_VERSION ($XCODE_APP); Xcode 26 or newer is needed"
echo "Using Xcode $XCODE_VERSION: $XCODE_APP"
# sudo drops DEVELOPER_DIR, so these call this Xcode's xcodebuild by path
if ! "$XCODEBUILD" -license check >/dev/null 2>&1; then
  say "Xcode's license hasn't been accepted yet; accepting it needs your Mac password"
  sudo "$XCODEBUILD" -license accept
fi
if ! "$XCODEBUILD" -checkFirstLaunchStatus >/dev/null 2>&1; then
  say "Finishing Xcode's first-launch setup (needs your Mac password)"
  sudo "$XCODEBUILD" -runFirstLaunch
fi

# --- pick the game files -----------------------------------------------------
FILES=()
if [ $# -gt 0 ]; then
  for f in "$@"; do
    [ -e "$f" ] || die "no such file: $f"
    FILES+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")")
  done
else
  while :; do
    PICKED="$(osascript \
      -e 'set fs to choose file with prompt "Choose prod.keys and the game .nsp files (or archives holding them). Hold ⌘ to pick several." with multiple selections allowed' \
      -e 'set out to ""' \
      -e 'repeat with f in fs' -e 'set out to out & POSIX path of f & linefeed' -e 'end repeat' \
      -e 'return out' 2>/dev/null)" || { [ ${#FILES[@]} -gt 0 ] && break; die "no files chosen"; }
    while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<< "$PICKED"
    MORE="$(osascript -e "button returned of (display dialog \"${#FILES[@]} file(s) chosen. Add more from another folder?\" buttons {\"Add more\", \"Build\"} default button \"Build\")" 2>/dev/null || echo Build)"
    [ "$MORE" = "Add more" ] || break
  done
fi
say "Game files"
printf '  %s\n' "${FILES[@]}"

# --- temporary folder, deleted on exit ----------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mush8-build.XXXXXX")"
LOG="$WORK/build.log"
OK=0
cleanup() {
  local status=$?
  set +e
  [ -n "${CAFFEINATE:-}" ] && kill "$CAFFEINATE" 2>/dev/null
  if [ "$OK" != 1 ] && [ -f "$LOG" ]; then
    { echo; echo "---- shader log ----"; tail -50 "$WORK/src/work/precompile_ios.log" 2>/dev/null; } >> "$LOG"
    cp "$LOG" "$HOME/Desktop/mush8-build-failed.log" 2>/dev/null \
      && printf '\nThe build failed; its log is on your Desktop: mush8-build-failed.log\n' >&2
  fi
  printf '\nDeleting the temporary build folder and tools (%s)…\n' "$WORK" >&2
  case "$WORK" in
    "${TMPDIR:-/tmp}"*/mush8-build.*) chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK" ;;
  esac
  [ -e "$WORK" ] && printf 'Could not fully delete %s, remove it by hand.\n' "$WORK" >&2 || printf 'Cleaned up.\n' >&2
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
exec > >(tee -a "$LOG") 2>&1

FREE_GB="$(df -g "$WORK" | awk 'NR==2 {print $4}')"
if [ "$FREE_GB" -lt 30 ]; then
  echo "Only ${FREE_GB} GB free on this disk; the build needs about 30 GB (more if your files are in archives)."
  read -r -p "Try anyway? [y/N] " yn < /dev/tty
  [ "$yn" = y ] || [ "$yn" = Y ] || exit 1
fi

caffeinate -dims -w $$ &
CAFFEINATE=$!

TOOLS="$WORK/tools"
mkdir -p "$TOOLS/bin"
export RUSTUP_HOME="$TOOLS/rustup" CARGO_HOME="$TOOLS/cargo" CLANG_MODULE_CACHE_PATH="$WORK/module-cache"
export PATH="$TOOLS/bin:$CARGO_HOME/bin:$PATH"

# --- tools (all inside $WORK) --------------------------------------------------
say "Downloading Rust $TOOLCHAIN (private copy, deleted afterwards)"
ARCH="$(uname -m)"; [ "$ARCH" = arm64 ] && ARCH=aarch64
curl -fsSL "https://static.rust-lang.org/rustup/dist/$ARCH-apple-darwin/rustup-init" -o "$TOOLS/rustup-init"
chmod +x "$TOOLS/rustup-init"
"$TOOLS/rustup-init" -y -q --no-modify-path --profile minimal --default-toolchain "$TOOLCHAIN"
rustup target add aarch64-apple-ios --toolchain "$TOOLCHAIN"

say "Downloading XcodeGen and 7-Zip"
curl -fsSL "$XCODEGEN_URL" -o "$TOOLS/xcodegen.zip"
unzip -q "$TOOLS/xcodegen.zip" -d "$TOOLS"
ln -s "$TOOLS/xcodegen/bin/xcodegen" "$TOOLS/bin/xcodegen"
curl -fsSL "$SEVENZIP_URL" | tar xJ -C "$TOOLS/bin" 7zz

METAL_ADDED=0
if ! xcrun -sdk iphoneos metal -v >/dev/null 2>&1; then
  say "Installing Xcode's Metal Toolchain (needed to compile the shaders)"
  xcodebuild -downloadComponent MetalToolchain
  METAL_ADDED=1
fi

# --- source and game files -----------------------------------------------------
say "Getting the Mush8 source ($REF)"
git clone -q --depth 1 --branch "$REF" "$REPO" "$WORK/src"
cd "$WORK/src"

say "Building host tools"
cargo build --release --locked

say "Sorting out the game files"
mkdir -p work/uploads
for f in "${FILES[@]}"; do
  # clone on APFS: instant, takes no extra space, and leaves your file alone
  cp -cR "$f" work/uploads/ 2>/dev/null || cp -R "$f" work/uploads/
done
python3 -I tools/fetch-game-files.py --dest . --work work/download \
  --local work/uploads --nxfs target/release/nxfs
ls -la ./*.nsp prod.keys

say "Building the ipa (the shader step takes a while)"
BUNDLE_ID="${BUNDLE_ID:-ch.cclerc.mush8}" ./make-ios.sh --ipa

OUT="$HOME/Desktop/Mush8.ipa"
[ -e "$OUT" ] && OUT="$HOME/Desktop/Mush8-$(date +%Y%m%d-%H%M%S).ipa"
mv build/Mush8.ipa "$OUT"
OK=1
rm -f "$HOME/Desktop/mush8-build-failed.log"
say "Done: $OUT"
if [ "$METAL_ADDED" = 1 ]; then
  echo "Xcode's Metal Toolchain was installed for this build and stays with Xcode."
  echo "To remove it too: Xcode > Settings > Components, then delete Metal Toolchain."
fi
