#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/djstompzone/bedrock-viz.git"
REPO_DIR="bedrock-viz"

PATCHES=(
  "patches/leveldb-1.22.patch"
  "patches/pugixml-disable-install.patch"
)

DEPS=(
  git cmake build-essential
  libpng++-dev zlib1g-dev libboost-program-options-dev
)

# ---------- utils ----------

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_deps_if_needed() {
  if ! have_cmd apt; then
    echo "[!] Watch out, we got a badass over here! (Non-APT system detected)"
    echo "Skipping auto-install..."
    return 0
  fi

  local missing=()

  for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "[*] Installing missing packages: ${missing[*]}"
    sudo apt update
    sudo apt install -y "${missing[@]}"
  else
    echo "[+] All dependencies already installed"
  fi
}

apply_patch_if_needed() {
  local patch="$1"

  if git apply --check -p0 "$patch" >/dev/null 2>&1; then
    echo "[*] Applying $patch"
    git apply -p0 "$patch"
    return 0
  fi

  if git apply --reverse --check -p0 "$patch" >/dev/null 2>&1; then
    echo "[*] Skipping $patch (already applied)"
    return 0
  fi

  echo "[!] Failed to apply $patch cleanly"
  return 1
}

build_with() {
  local build_dir="$1"
  shift

  echo "[*] Building in $build_dir"
  cmake -S . -B "$build_dir" -DCMAKE_CXX_STANDARD=17 "$@"
  cmake --build "$build_dir" -j"$(nproc)"
}

find_fallback_compiler() {
  for v in 12 11 10 9 8; do
    if have_cmd "g++-$v"; then
      echo "$v"
      return 0
    fi
  done
  return 1
}

# ---------- main ----------

install_deps_if_needed

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "[*] Cloning repo"
  git clone --recursive "$REPO_URL" "$REPO_DIR"
else
  echo "[*] Repo already exists"
fi

cd "$REPO_DIR"

for p in "${PATCHES[@]}"; do
  apply_patch_if_needed "$p"
done

echo "[*] Attempting build with system compiler"

if build_with build-default; then
  echo "[+] Build succeeded with system compiler"
  exit 0
fi

echo "[!] Default build failed, searching for fallback compiler"

if ver=$(find_fallback_compiler); then
  echo "[*] Trying gcc-$ver fallback"
  build_with build-gcc"$ver" \
    -DCMAKE_C_COMPILER="gcc-$ver" \
    -DCMAKE_CXX_COMPILER="g++-$ver"

  echo "[+] Build succeeded with gcc-$ver"
  exit 0
fi

echo "[X] No suitable fallback compiler found... You're on your own, amigo. o7"
exit 1
