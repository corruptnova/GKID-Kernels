#!/usr/bin/env bash

WORKDIR="$(pwd)"
RELEASE_DIR="$WORKDIR/artifacts"

# Project name: zip names, release names and the kernel's -NAME-rN release suffix
KERNEL_NAME="NovaGKI"
# Shown in /proc/version as builder@host; forks get their own owner name
BUILD_USER="${GITHUB_REPOSITORY_OWNER:-builder}"
BUILD_HOST="$KERNEL_NAME"
# Release tags and build timestamps use this time zone
TIMEZONE="UTC"
ANYKERNEL_REPO="https://github.com/ahmed-alnassif/AK3-GKID"

KERNEL_DEFCONFIG="gki_defconfig"

KERNEL_VERSION="${KERNEL_VERSION:-6.1}"

sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

RELEASE="$(date +v%y.%m.%d)${RUN_NUM}"

mkdir -p $RELEASE_DIR

# Releases are published to the repo the workflow runs in
GKI_RELEASES_REPO="https://github.com/${GITHUB_REPOSITORY:-$(git -C "$WORKDIR" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}"
AK3_ZIP_NAME="$KERNEL_NAME-VARIANT-REL-KVER.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"
PATCHES_DIR="$WORKDIR/patches"
# Copies of GKI ABI files the build deletes but the KMI check still needs
KMI_REF_DIR="$WORKDIR/kmi-ref"

# FinaSU develops on dev; set FINASU_REF to a tag (e.g. v1.7.0) to pin it
FINASU_REPO="LyraVoid/FinaSU"
FINASU_REF="${FINASU_REF:-dev}"

source $WORKDIR/functions.sh

IFS='|' read -r KERNEL_REPO KERNEL_BRANCH KERNEL_KMI <<< "$(resolve_kernel_source "$KERNEL_VERSION")"

ANDROID_RELEASE="$(android_release_for_version "$KERNEL_VERSION")"
echo "KERNEL_VERSION=$KERNEL_VERSION" >> $GITHUB_ENV
echo "ANDROID_RELEASE=$ANDROID_RELEASE" >> $GITHUB_ENV
echo "KERNEL_SOURCE_REPO=$(simplify_gh_url "$KERNEL_REPO")" >> $GITHUB_ENV
echo "KERNEL_SOURCE_BRANCH=$KERNEL_BRANCH" >> $GITHUB_ENV

echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")" >> $GITHUB_ENV
echo "KERNEL_NAME=${KERNEL_NAME}${RUN_NUM}" >> $GITHUB_ENV
echo "RELEASE_NAME=$KERNEL_NAME $RELEASE" >> $GITHUB_ENV
echo "RELEASE=$RELEASE" >> $GITHUB_ENV

BUILD_LOGS="$RELEASE_DIR/build.log"
exec > >(tee -a "$BUILD_LOGS") 2>&1

trap 'echo "SCRIPT EXIT at $(date)" >> "$BUILD_LOGS"' EXIT
trap 'echo "[-] ERROR at line $LINENO: [[$BASH_COMMAND]]" >> "$BUILD_LOGS"' ERR
trap 'echo "[-] Received SIGTERM at $(date) - possible GitHub kill" >> "$BUILD_LOGS"' TERM
trap 'echo "[-] Received SIGINT at $(date)" >> "$BUILD_LOGS"' INT

log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC"

cd $KSRC
LINUX_VERSION=$(make kernelversion)
LINUX_VERSION_CODE=${LINUX_VERSION//./}
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
echo "LINUX_VERSION=$LINUX_VERSION" >> $GITHUB_ENV
cd $WORKDIR

log "Setting Kernel variant"
case "$KSU" in
  "BSU") VARIANT="BakaSU" ;;
  "FSU") VARIANT="FinaSU" ;;
  "KSU") VARIANT="KernelSU" ;;
  "no") VARIANT="Vanilla" ;;
  "vnlto") VARIANT="Vanilla+NoLTO" ;;
  *) VARIANT="Vanilla" ;;
esac

susfs_included && VARIANT+="+SuSFS"
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_DIR="$WORKDIR/susfs"
SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"

SUSFS_BRANCH="$(resolve_susfs_branch "$KERNEL_VERSION")"
SUSFS_PATCH="$SUSFS_BRANCH"

log "Changelog of repos"
clone_susfs 5
cd "$SUSFS_DIR"
git log --pretty=format:"- [%h](https://${SUSFS_URL#https://}/commit/%H) %s" -5 "$SUSFS_BRANCH" \
> "$RELEASE_DIR/susfs_changelog-${KERNEL_VERSION}.txt"
cd ..

echo "No changelog generator wired up yet for $KERNEL_VERSION" \
  > "$RELEASE_DIR/android_kernel-${KERNEL_VERSION}_changelog.txt"
generate_gh_changelog "maxsteeel/nomount" "master" 5 "$RELEASE_DIR/nomount_changelog.txt"
generate_gh_changelog "tiann/KernelSU" "main" 5 "$RELEASE_DIR/ksu_changelog.txt"
generate_gh_changelog "Baka-SU/BakaSU" "main" 5 "$RELEASE_DIR/BakaSU_changelog.txt"
generate_gh_changelog "$FINASU_REPO" "$FINASU_REF" 5 "$RELEASE_DIR/FinaSU_changelog.txt"

echo "::group::[*] Downloading Clang"
CLANG_BIN="$WORKDIR/neutron-clang/bin"
mkdir -p "$WORKDIR/neutron-clang"
cd "$WORKDIR/neutron-clang"
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
cd $OLDPWD
if [ ! -d "$CLANG_BIN" ]; then
    error "Clang not found in ${CLANG_BIN}."
    exit 1
fi

export PATH="${CLANG_BIN}:$PATH"
echo "::endgroup::"

echo "::group::[*] Rust toolchain"
setup_rust_toolchain "$KSRC"
echo "::endgroup::"

export CCACHE_DIR="$HOME/.ccache"
export CCACHE_BASEDIR="$WORKDIR"
export CCACHE_NOHARDLINK=true
export CCACHE_COMPILERCHECK=content
export CC="ccache clang"
export CXX="ccache clang++"

ccache --zero-stats
ccache --max-size=5G
ccache --set-config=sloppiness="pch_defines,time_macros,file_macro,include_file_mtime,include_file_ctime"
ccache --set-config=hash_dir=false
ccache --set-config=base_dir="$WORKDIR"
ccache --set-config=compiler_check=content

COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')
echo "COMPILER_STRING=$COMPILER_STRING" >> $GITHUB_ENV

cd $KSRC

echo "::group::[+] pahole installation"
build_and_install_pahole
echo "::endgroup::"

echo "::group::[+] Applied patches"

apply_kernel_patches
apply_force_load_module_patch
apply_s2idle_wake_gate
apply_extract_cert_key_pass_patch
keep_gki_ll_max_header
hide_counted_by_from_genksyms
keep_gki_stack_protector
# Part of the hardening set (configs/hardening.config)
if [ "${HARDENING:-true}" = "true" ]; then
  default_init_on_free_on
fi
cleanup_abi_gki_protected_exports



log "Applying BBRv3 patch"
# KMI-safe backport for this GKI line: adds BBRv3 as a separate "bbr3" algorithm
# next to stock BBR and keeps the TCP structures at GKI's layout
BBR_PATCH="$KERNEL_PATCHES/bbrv3/bbrv3-${KERNEL_VERSION}.patch"
if [ -f "$BBR_PATCH" ]; then
  apply_patch_file "$BBR_PATCH"
else
  warning "No BBRv3 patch for ${KERNEL_VERSION}; building with stock BBR only"
fi

log "Applying wakelock timeout patch"
# Caps userspace /sys/power/wake_lock locks taken without a timeout to 500ms
apply_patch_file "$KERNEL_PATCHES/power/add_timeout_wakelocks_globally.patch"

log "Applying hiding patches"
# Stop zero-width/ignorable code points from being stripped during casefold,
# which let paths like "Android<U+200B>/data" resolve to the real Android/data
if kernel_version_ge "$KERNEL_VERSION" "6.1"; then
  apply_patch_file "$KERNEL_PATCHES/hiding/unicode_bypass_fix_6.1+.patch"
else
  apply_patch_file "$KERNEL_PATCHES/hiding/unicode_bypass_fix_5.10-5.15.patch"
fi
# Lets CONFIG_FAKE_DISABLE strip chosen options from /proc/config.gz
apply_patch_file "$KERNEL_PATCHES/hiding/fake_config.patch"


if kernel_version_lt "$KERNEL_VERSION" "6.12"; then
  log "Applying NTSync patches..."
  curl -LSs "https://github.com/WildKernels/kernel_patches/raw/main/common/ntsync/ntsync_base.patch" | apply_patch_file

  apply_ntsync_compat_patch "$KERNEL_KMI"
  success "NTSync patches applied"
fi

log "BBG included"
wget -qO- "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "security/Kconfig"

if [ "$KSU" = "no" ] || [ "$KSU" = "vnlto" ] || [ "$No_DS" = "true" ]; then
  export DROIDSPACES="false"
  export NH="false"
  warning "DroidSpaces/NetHunter doesn't supported in this builds"
  VARIANT+="+NoDS"
fi

if { [ "$DROIDSPACES" = "true" ] || [ "$NH" = "true" ]; } && kernel_version_lt "$KERNEL_VERSION" "6.12"; then
  log "Applying DroidSpaces/NetHunter sysvipc patch"
  # Prefer a copy rebased for this GKI line (e.g. 001.GKI-6.6-fix_sysvipc_kabi.patch)
  SYSVIPC_PATCH="$KERNEL_PATCHES/droidspaces/001.GKI-${KERNEL_VERSION}-fix_sysvipc_kabi.patch"
  [ -f "$SYSVIPC_PATCH" ] || SYSVIPC_PATCH="$KERNEL_PATCHES/droidspaces/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch"
  apply_patch_file "$SYSVIPC_PATCH"
  if kernel_version_eq "$KERNEL_VERSION" "5.10"; then
    apply_patch_file "$KERNEL_PATCHES/droidspaces/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"
  fi
elif [ "$DROIDSPACES" = "true" ] || [ "$NH" = "true" ]; then
  log "Applying DroidSpaces/NetHunter sysvipc patch"
  apply_patch_file "$KERNEL_PATCHES/droidspaces/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch"
fi

if [ "$NH" = "true" ] && [ "$No_DS" = "false" ]; then
  log "Applying NetHunter patches"
  # Prefer a variant rebased for this GKI line, else the generic one
  NH_PATCH="$KERNEL_PATCHES/nethunter/0001-mac80211-cfg80211-Add-monitor-mode-and-packet-inject-${KERNEL_VERSION}.patch"
  [ -f "$NH_PATCH" ] || NH_PATCH="$KERNEL_PATCHES/nethunter/0001-mac80211-cfg80211-Add-monitor-mode-and-packet-inject.patch"
  log "Using $(basename "$NH_PATCH")"
  apply_patch_file "$NH_PATCH"
  git clone --depth=1 "https://github.com/ahmed-alnassif/rtw88"
  rm -rf "drivers/net/wireless/realtek/rtw88"
  mv rtw88 "drivers/net/wireless/realtek/"

  if kernel_version_lt "$KERNEL_VERSION" "6.1"; then
    apply_patch_file "$KERNEL_PATCHES/nethunter/0001-wifi-rtw88-rtw8723x-avoid-shared-loop-variable-name-.patch"
  fi
fi

set -eo pipefail
if susfs_included && [ "$KSU" = "BSU" ]; then
  log "BakaSU included"
  install_ksu "Baka-SU/BakaSU" "main"

  register_bakasu_susfs_types

  clone_susfs
  apply_susfs_patches

fi

if [ "$KSU" = "FSU" ]; then
  log "FinaSU included"
  install_ksu "$FINASU_REPO" "$FINASU_REF"
  resolve_finasu_manager_cert "$FINASU_REPO" || exit 1

  if susfs_included; then
    # FinaSU carries the KernelSU side of SUSFS in-tree, so only the kernel
    # side is applied here (no 10_enable_susfs_for_ksu.patch)
    clone_susfs
    apply_susfs_patches
  fi
fi

if [ "$KSU" = "KSU" ]; then
  log "KernelSU included"
  if ! susfs_included; then
    install_ksu "tiann/KernelSU" "main"
  fi

  if susfs_included; then
    VARIANT+="+Multiple-Managers"
    git clone "https://github.com/tiann/KernelSU" && echo "[+] Repository cloned."
    clone_susfs

    cd KernelSU
    #git reset --hard "61c6313"
    git reset --soft HEAD~1
    apply_patch_file "$PATCHES_DIR/0001-feat-avc-log-spoofing.patch"
    apply_patch_file "$PATCHES_DIR/0001-feat-add-multiple-managers.patch"
    #apply_patch_file "$PATCHES_DIR/0001-feat-throne_tracker-offload-to-kthread.patch"
    apply_patch_file "$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch"
    apply_patch_file "$PATCHES_DIR/0001-feat-escape-persistent_allow_list-to-kthread.patch"
    apply_patch_file "$PATCHES_DIR/0001-feat-supercalls-allow-userspace-to-pull-list-entries.patch"
    sed -i "/    git pull && echo \"\[+\] Repository updated.\"/d" "kernel/setup.sh"
    git add .
    git -c user.name="CI" -c user.email="ci@localhost" commit -q -m "susfs patch"
    cd ..
    bash "KernelSU/kernel/setup.sh" "main"

    apply_susfs_patches

  fi

fi

if [ "$KSU_COMPAT" = "true" ]; then
  if [ "$C_LTO" = "true" ]; then
    VARIANT="Compat+${VARIANT}"
  else
    VARIANT="Compat+NoLTO+${VARIANT}"
  fi
fi

echo "VARIANT=$VARIANT" >> $GITHUB_ENV

if [ "$NM" = "true" ] && [ "$KSU" = "FSU" ]; then
  # FinaSU loads its own NoMount driver; a built-in one below the API it
  # requires can't be replaced at runtime and would block it
  warning "Skipping built-in NoMount: FinaSU ships its own"
elif [ "$NM" = "true" ]; then
  log "Applying NoMount"
  curl "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s master
fi
echo "::endgroup::"
set +eo pipefail

AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

log "Applying configs..."
source "$WORKDIR/configs/gki_defconfig.sh"
# The LTO mode this build actually uses (gki_defconfig.sh can turn it off), for the release notes
echo "BUILD_LTO=${LTO:-noneLTO}" >> $GITHUB_ENV

if [ "${TODO:-kernel}" = "kernel" ]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  SUFFIX="${RUN_NUM}-${LATEST_COMMIT_HASH}"
  KERNEL_LOCALVERSION="-${KERNEL_NAME}${SUFFIX}"

  # STOCK_NAME: report what a stock kernel reports instead of -${KERNEL_NAME}-rN-...
  if [ "${STOCK_NAME:-false}" = "true" ]; then
    # Don't quietly ship the project name when a stock one was asked for
    if ! resolve_stock_identity; then
      error "STOCK_NAME: no usable stock identity"
      exit 1
    fi
    KERNEL_LOCALVERSION="$STOCK_LOCALVERSION"
    BUILD_USER="$STOCK_BUILD_USER"
    BUILD_HOST="$STOCK_BUILD_HOST"

    if [ -n "$STOCK_COMPILER" ]; then
      # Report the stock compiler in /proc/version. mkcompile_h builds that
      # string from the real compiler; let an exported override win.
      export KBUILD_BUILD_COMPILER="$STOCK_COMPILER"
      sed -i \
        -e 's/"\${CC_VERSION}, \${LD_VERSION}"/"${KBUILD_BUILD_COMPILER:-${CC_VERSION}, ${LD_VERSION}}"/' \
        -e 's/"\$CC_VERSION, \$LD_VERSION"/"${KBUILD_BUILD_COMPILER:-$CC_VERSION, $LD_VERSION}"/' \
        scripts/mkcompile_h
      grep -q "KBUILD_BUILD_COMPILER" scripts/mkcompile_h \
        || warning "STOCK_NAME: scripts/mkcompile_h not in the expected shape, /proc/version keeps the real compiler"
    fi

    log "Stock kernel release: ${LINUX_VERSION%.*}.${STOCK_SUBLEVEL:-${LINUX_VERSION##*.}}${KERNEL_LOCALVERSION} (${USER}@${HOST})"
  fi

  config --set-str CONFIG_LOCALVERSION "$KERNEL_LOCALVERSION"
  config --disable CONFIG_LOCALVERSION_AUTO
  sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion
fi

export KBUILD_BUILD_USER="$BUILD_USER"
export KBUILD_BUILD_HOST="$BUILD_HOST"
if [ -n "${STOCK_BUILD_TIMESTAMP:-}" ]; then
  # Build date copied from the stock version line in STOCK_VERSION
  export KBUILD_BUILD_TIMESTAMP="$STOCK_BUILD_TIMESTAMP"
elif [ "${STOCK_NAME:-false}" = "true" ]; then
  # Stock GKI stamps the build time the way `date` prints it, in UTC
  export KBUILD_BUILD_TIMESTAMP=$(TZ=UTC git -C $KSRC log -1 --format=%cd --date=format-local:'%a %b %e %T UTC %Y')
else
  export KBUILD_BUILD_TIMESTAMP=$(git -C $KSRC log -1 --format=%cd --date=format-local:'%a %b %d %T %z %Y')
fi
export KCFLAGS="-w"
# 6.12+ compute symbol CRCs from DWARF (gendwarfksyms). Google's build runs it
# in stable mode, which applies the ANDROID_KABI_* annotations; without it
# nearly every CRC differs from GKI's. Unused on lines that use genksyms.
export KBUILD_GENDWARFKSYMS_STABLE=1

LINK_CACHE_PATH="/dev/shm/thinlto-cache"
LINKER_SHIM="/tmp/clang-lto-linker"
MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  -j$(nproc --all)
  O="$OUTDIR"
)

# NOTE: STOCK_VERSION may carry an older patch level than the source (e.g. a
# stock 6.6.127 line against a 6.6.144 tree). We deliberately do NOT change the
# build's SUBLEVEL to match: reporting a different version than the kernel was
# built from desyncs vendor modules' vermagic, so the display/touch/modem
# drivers fail to load and the device bootloops. The real source version is
# kept; only the name suffix, builder, compiler and date from STOCK_VERSION are
# applied. The reported release therefore keeps the source patch level.
if [ -n "${STOCK_SUBLEVEL:-}" ] && [ "$STOCK_SUBLEVEL" != "${LINUX_VERSION##*.}" ]; then
  warning "STOCK_VERSION patch level $STOCK_SUBLEVEL differs from source ${LINUX_VERSION##*.}; keeping ${LINUX_VERSION##*.} so vendor modules still load"
fi

# AutoFDO: optimize with the sample profile Google ships in the GKI tree
# (android15-6.6 and later). Without CLANG_AUTOFDO_PROFILE the kernel only gets
# the profiling flags and none of the optimization.
if [ "${AUTOFDO:-true}" = "true" ]; then
  if grep -q "^config AUTOFDO_CLANG" arch/Kconfig 2>/dev/null && AUTOFDO_PROFILE="$(find_autofdo_profile)"; then
    log "AutoFDO: using in-tree profile ${AUTOFDO_PROFILE#"$KSRC"/}"
    config --enable CONFIG_AUTOFDO_CLANG
    MAKE_ARGS+=(CLANG_AUTOFDO_PROFILE="$AUTOFDO_PROFILE")
  else
    log "AutoFDO: no in-tree profile for $KERNEL_VERSION, building without it"
  fi
fi

if [ "$KSU" = "FSU" ]; then
  # Trust the FinaSU release manager through the second signature slot, and
  # fail the build instead of silently dropping preinit if UAPI headers are missing
  MAKE_ARGS+=(
    KSU_EXPECTED_SIZE2="$FINASU_CERT_SIZE"
    KSU_EXPECTED_HASH2="$FINASU_CERT_HASH"
    KSU_SECOND_SIGNATURE_RELEASE=1
    KSU_REQUIRE_PREINIT=1
  )
fi

if [ "${LTO:-}" = "thinLTO" ] && [ "$CLEAN_LTO_CACHE" = "true" ]; then
  rm -rf "$LINK_CACHE_PATH"
  success "ThinLTO cache removed"
fi

if [ "${LTO:-}" = "thinLTO" ]; then
    log "ThinLTO cache enabled"
    mkdir -p "$LINK_CACHE_PATH"
    cat > "$LINKER_SHIM" << SHIM
#!/usr/bin/env bash
JOBCOUNT=\$(( \$(nproc --all) / 2 ))
exec ld.lld "\$@" --thinlto-cache-dir="$LINK_CACHE_PATH" --thinlto-jobs=\$JOBCOUNT
SHIM
    chmod +x "$LINKER_SHIM"
    MAKE_ARGS+=(LD="$LINKER_SHIM" HOSTLD="$LINKER_SHIM")
fi

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"
KMI_CHECK="$WORKDIR/py/kmi-check.py"

echo "::group::[*] Generating config"
make ${MAKE_ARGS[@]} "$KERNEL_DEFCONFIG"
echo "::endgroup::"

# Root/hiding options to report as "not set" in /proc/config.gz (fake_config.patch)
FAKE_DISABLE_CONFIGS="$(grep -oE '^CONFIG_(KSU|KPM|NOMOUNT|BBG)(_[A-Za-z0-9_]*)?=' "$OUTDIR/.config" | tr -d '=' | tr '\n' ' ' | sed 's/ $//')"
if [ -n "$FAKE_DISABLE_CONFIGS" ]; then
  log "Hiding from /proc/config.gz: $FAKE_DISABLE_CONFIGS"
fi

if susfs_included; then

  log "DEBUG: Checking defconfig for SUSFS"
  grep -i susfs ./arch/arm64/configs/gki_defconfig || error "SUSFS NOT FOUND in defconfig!"
  echo ""

  log "DEBUG: Checking .config for SUSFS"
  grep CONFIG_KSU_SUSFS $OUTDIR/.config || error "SUSFS NOT ENABLED in .config!"
  grep CONFIG_KSU_SUSFS_SUS_MAP $OUTDIR/.config || error "SUSFS_SUS_MAP not enabled!"
  echo ""

  if grep -q "CONFIG_KSU_SUSFS" ./arch/arm64/configs/gki_defconfig && ! grep -q "CONFIG_KSU_SUSFS=y" $OUTDIR/.config; then
    warning "SUSFS in defconfig but not in .config - checking dependencies..."
    grep "depends on" $(find . -name "Kconfig" -exec grep -l "KSU_SUSFS" {} \;) 2>/dev/null || error "No dependency info found"
  fi

fi

if [ "$KSU" = "FSU" ]; then
  # Kconfig drops these without a warning, so check the final .config
  log "DEBUG: Checking .config for FinaSU"
  FSU_REQUIRED=(CONFIG_KSU=y CONFIG_KALLSYMS_ALL=y CONFIG_HEADERS_INSTALL=y)
  susfs_included && FSU_REQUIRED+=(CONFIG_KSU_HOOK_SUSFS_INLINE=y)
  for opt in "${FSU_REQUIRED[@]}"; do
    if ! grep -qx "$opt" "$OUTDIR/.config"; then
      error "$opt missing from .config"
      exit 1
    fi
  done
  success "FinaSU options present: ${FSU_REQUIRED[*]}"
fi

if [ "$TEST" = "yes" ]; then
  success "Pipeline test done"
  mkdir -p "$RELEASE_DIR"
  echo "test-${VARIANT}" > "$RELEASE_DIR/test-${VARIANT}.zip"
  exit 0
fi

if [[ $TODO == "defconfig" ]]; then
  log "Copying defconfig"
  mkdir -p "$RELEASE_DIR"
  cp "$OUTDIR/.config" "$RELEASE_DIR/config-${VARIANT}.txt"
  exit 0
fi

echo "::group::[*] Aggressive Resource Optimization for FullLTO"

info "Initial storage: $(df -h / | awk 'NR==2 {print $4}') available"
info "Initial memory: $(free -h | awk '/^Mem:/ {print $7}') available"

sudo apt-get clean -qq
sudo apt-get autoremove -y -qq
sudo apt-get autoclean -qq
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/cache/apt/*

for dir in \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /usr/local/share/powershell \
    /usr/local/share/chromium \
    /usr/local/lib/node_modules \
    /opt/ghc \
    /usr/local/.ghcup \
    /opt/hostedtoolcache \
    /usr/local/share/boost \
    /usr/local/share/gradle-* \
    /usr/local/share/kotlin \
    /usr/local/share/sbt \
    /usr/share/swift \
    /usr/local/share/php \
    /usr/local/share/rust \
    /usr/local/share/go \
    /usr/local/julia* \
    /usr/share/az_* \
    /usr/share/miniconda \
    /opt/microsoft \
    /opt/google \
    /opt/az \
    /usr/lib/jvm \
    /usr/local/lib/heroku \
    /var/lib/containers \
    /var/lib/docker \
    /var/lib/gems \
    /var/lib/mysql \
    /var/lib/postgresql \
    /var/lib/snapd \
    /var/cache/* \
    /tmp/* \
    /home/runner/.cargo \
    /home/runner/.rustup \
    /home/runner/.npm \
    /home/runner/.cache \
    /home/runner/go \
    /home/runner/.local/share \
    /home/runner/.dotnet \
    /home/runner/.gradle \
    /home/runner/.m2 \
    /etc/skel \
    /home/packer \
    /opt/pipx; do
    if [ -e "$dir" ]; then
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "?")
        sudo rm -rf "$dir" 2>/dev/null || true
        success "Removed $dir ($SIZE)"
    fi
done

sudo docker system prune -af --volumes 2>/dev/null || true
sudo docker builder prune -af 2>/dev/null || true
sudo docker image prune -af 2>/dev/null || true

sudo journalctl --vacuum-size=1M 2>/dev/null || true
sudo find /var/log -type f \( -name "*.log" -o -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete 2>/dev/null || true
sudo rm -rf /var/log/journal/* 2>/dev/null || true

if [ -f /swapfile ]; then
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile
fi
if [ -f /mnt/swapfile ]; then
    sudo swapoff /mnt/swapfile 2>/dev/null || true
    sudo rm -f /mnt/swapfile
fi

warning "Creating 32GB swap"
sudo fallocate -l 32G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=32768 status=none
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
success "32GB swap created and activated"

sudo sysctl -w vm.swappiness=90
sudo sysctl -w vm.vfs_cache_pressure=200
sudo sysctl -w vm.dirty_ratio=5
sudo sysctl -w vm.dirty_background_ratio=2
sudo sysctl -w vm.drop_caches=3
sudo sysctl -w vm.overcommit_memory=1

success "Final storage: $(df -h / | awk 'NR==2 {print $4}') available"
success "Final memory:  $(free -h | awk '/^Mem:/ {print $7}') available | Swap: $(free -h | awk '/^Swap:/ {print $2}')"
echo "::endgroup::"

set -eo pipefail
echo "::group::[*] Building kernel"
make ${MAKE_ARGS[@]} CC="ccache clang" CXX="ccache clang++" CONFIG_FAKE_DISABLE="$FAKE_DISABLE_CONFIGS"
echo "::endgroup::"
set +eo pipefail

# GKI wants Rust on this line but the kernel was built without it (Kconfig
# re-checks the toolchain on every build): say why instead of silently shipping
# without ashmem and the Rust binder exports
if grep -q '^CONFIG_RUST=y' "$KSRC/arch/arm64/configs/gki_defconfig" && ! grep -q '^CONFIG_RUST=y' "$OUTDIR/.config"; then
  echo "::warning::${KERNEL_VERSION}: built without Rust (CONFIG_RUST off): no ashmem, and the Rust binder exports are missing. See 'make rustavailable' in the log"
  make ${MAKE_ARGS[@]} rustavailable || true
fi

# Vendor modules with mismatched symbol CRCs are force-loaded (see
# 0003-kernel-module.c patch), so report which symbols they use changed here
# instead of finding out on a device. The full list goes into the artifacts.
KMI_REPORT="$RELEASE_DIR/kmi-report-${KERNEL_VERSION}-${VARIANT}.txt"
KMI_SUMMARY="$WORKDIR/kmi-summary.txt"
# Lines whose KMI matches stock GKI fail the build on a regression; the rest
# only warn until they match too. Set KMI_STRICT=true or false to override.
KMI_STRICT_LINES="6.1 6.6"
if [ -z "${KMI_STRICT:-}" ]; then
  case " $KMI_STRICT_LINES " in
    *" $KERNEL_VERSION "*) KMI_STRICT=true ;;
    *) KMI_STRICT=false ;;
  esac
fi
echo "::group::[*] KMI symbol CRC check (KMI_STRICT=$KMI_STRICT)"
python3 "$KMI_CHECK" --ksrc "$KSRC" --symvers "$OUTDIR/vmlinux.symvers" \
  --module-symvers "$OUTDIR/Module.symvers" \
  --protected-exports "$KMI_REF_DIR/abi_gki_protected_exports_aarch64" \
  --report "$KMI_REPORT" --summary-file "$KMI_SUMMARY"
KMI_RC=$?
echo "::endgroup::"
# gendwarfksyms CRCs come from the compiler's DWARF, not just the source:
# show where the changed ones come from (debug info or the tool itself)
if [ $KMI_RC -eq 1 ] && grep -q '^CONFIG_GENDWARFKSYMS=y' "$OUTDIR/.config"; then
  echo "::group::[*] KMI: changed gendwarfksyms CRCs explained"
  python3 "$WORKDIR/py/kmi-explain.py" --ksrc "$KSRC" --outdir "$OUTDIR" --report "$KMI_REPORT"
  echo "::endgroup::"
fi
if [ $KMI_RC -eq 1 ]; then
  if [ "$KMI_STRICT" = "true" ]; then
    echo "::error::KMI ${KERNEL_VERSION} ${VARIANT}: $(cat "$KMI_SUMMARY"). This line's KMI matched stock GKI, so the build stops (KMI_STRICT=false overrides). Details: $(basename "$KMI_REPORT") in the build artifacts"
    exit 1
  fi
  echo "::warning::KMI ${KERNEL_VERSION} ${VARIANT}: $(cat "$KMI_SUMMARY"). Details: $(basename "$KMI_REPORT") in the build artifacts"
elif [ $KMI_RC -ne 0 ]; then
  warning "KMI check could not run (see the log above)"
fi

cd $WORKDIR

log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 $ANYKERNEL_REPO anykernel

AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
# AK3-GKID shows GKID's banner and messages on the install screen; use ours
cp "$WORKDIR/ak3/banner" "$WORKDIR/anykernel/banner"
sed -i \
  -e "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT}/g" \
  -e "s/supported_kernel=\".*\"/supported_kernel=\"${KERNEL_VERSION}\"/g" \
  -e "s/GKID Supported:/${KERNEL_NAME} supported:/" \
  -e "s/Thank you for using GKID/Thank you for using ${KERNEL_NAME}/" \
  -e "s#^ui_print \"Please join our community.*#ui_print \"Help and bug reports: ${GKI_RELEASES_REPO}/issues\"#" \
  -e "/t\.me\/ahmed_alnassif_tg/d" \
  $WORKDIR/anykernel/anykernel.sh

cd anykernel
log "Zipping anykernel"
if [ ! -f "$KERNEL_IMAGE" ];then
  error "$KERNEL_IMAGE not found."
  exit 1
fi
cp "$KERNEL_IMAGE" .
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd $OLDPWD

echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> $GITHUB_ENV
mkdir -p $RELEASE_DIR
mv $WORKDIR/*.zip $RELEASE_DIR
