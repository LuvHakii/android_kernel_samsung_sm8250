#!/bin/bash
#
# Build Samsung SM8250 (kona) kernel for gts7l / gts7lwifi.
# Ported from AstideLabs android_kernel_xiaomi_sm8250 build_kernel.sh.
#
# Xiaomi specifics removed:
#   - MIUI DTS sed patches (dsi-panel-j*/g7a*) do not exist on Samsung
#   - MIUI/AOSP dual-target split (Samsung uses one Lineage config)
#   - Baseband-guard setup (Samsung source has no BBG hooks)
#   - AstideLabs AnyKernel3 kona branch (Xiaomi MIUI/AOSP layout)
#
# Samsung specifics:
#   - defconfig = vendor/kona-perf_defconfig
#               + vendor/samsung/kona-sec-common.config
#               + vendor/samsung/<device>.config
#     (mirrors TARGET_KERNEL_CONFIG in device/samsung/sm8250-common)
#   - AnyKernel3 = upstream osm0sis, Image/Image.gz at zip root
#
# Usage: ./build_samsung.sh <gts7l|gts7lwifi> [ksu]
set -e

if [ -z "$1" ]; then
    echo "[!] Usage: $0 <gts7l|gts7lwifi> [ksu]"
    exit 1
fi

DEVICE_NAME="$1"
shift || true

ENABLE_KSU=0
for arg in "$@"; do
    [ "$arg" = "ksu" ] && ENABLE_KSU=1
done

BASE_FRAG="arch/arm64/configs/vendor/kona-perf_defconfig"
COMMON_FRAG="arch/arm64/configs/vendor/samsung/kona-sec-common.config"
DEVICE_FRAG="arch/arm64/configs/vendor/samsung/${DEVICE_NAME}.config"

for f in "$BASE_FRAG" "$COMMON_FRAG" "$DEVICE_FRAG"; do
    if [ ! -f "$f" ]; then
        echo "[!] Missing fragment: $f"
        exit 1
    fi
done

KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

export CCACHE_DIR="$HOME/.cache/ccache_samsung"
export CCACHE_EXEC="$(command -v ccache || true)"
if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found, install it first."
    exit 1
fi
export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

clang --version || { echo "[!] clang missing in ${TOOLCHAIN_BIN}"; exit 1; }
mkdir -p "$CCACHE_DIR"

if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "[*] Setting up ReSukiSU..."
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

    echo "[*] Fetching SuSFS kernel-4.19 patches..."
    rm -rf /tmp/susfs4ksu
    git clone --depth 1 --branch kernel-4.19 https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs4ksu
    cp /tmp/susfs4ksu/kernel_patches/fs/susfs.c /tmp/susfs4ksu/kernel_patches/fs/sus_su.c fs/
    cp /tmp/susfs4ksu/kernel_patches/include/linux/susfs.h \
       /tmp/susfs4ksu/kernel_patches/include/linux/sus_su.h \
       /tmp/susfs4ksu/kernel_patches/include/linux/susfs_def.h include/linux/

    echo "[*] Applying SuSFS 4.19 patch..."
    echo "    (fs/namespace.c: 3 upstream hunks do not fit this tree and are"
    echo "     excluded here, hand-adapted below; rest applies normally)"
    awk '
        function emit(   keep) {
            keep = 1
            if (hbuf ~ /alloc_vfsmnt\(name, true, 0\)/) keep = 0
            else if (hbuf ~ /if \(susfs_is_current_zygote_domain\(\)\) \{/) keep = 0
            else if (hbuf ~ /bool is_current_ksu_domain/) keep = 0
            if (keep && hbuf != "") { print hhdr; printf "%s", hbuf }
            hbuf = ""; hhdr = ""
        }
        /^diff --git / {
            if (in_ns) emit()
            in_ns = ($0 == "diff --git a/fs/namespace.c b/fs/namespace.c")
            if (!in_ns) print
            next
        }
        !in_ns { print; next }
        /^@@ / { emit(); hhdr = $0; next }
        /^--- / { print; next }
        /^\+\+\+ / { print; next }
        /^index / { print; next }
        { hbuf = hbuf $0 "\n" }
        END { emit() }
    ' /tmp/susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch > /tmp/susfs-filtered.patch
    patch -p1 -F 3 --no-backup-if-mismatch < /tmp/susfs-filtered.patch || {
        echo "[!] SuSFS patch failed, fix *.rej manually."
        exit 1
    }
    if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
        echo "[!] SuSFS left *.rej files, fix manually."
        exit 1
    fi

    echo "[*] Applying Samsung-specific fs/namespace.c SuSFS adaptation..."
    echo "    (vfs_kern_mount is an fs_context wrapper here, real alloc lives in"
    echo "     vfs_create_mount; clone_mnt has extra clone_mnt_data block)"
    python3 - <<'PYEOF'
p = 'fs/namespace.c'
s = open(p).read()
T = chr(9); N = chr(10)

def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, "anchor count=%d: %r" % (n, old[:60])
    s = s.replace(old, new)

rep(
T + 'mnt = alloc_vfsmnt(fc->source ?: "none");',
'#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT' + N
+ T + '// For newly created mounts, the only caller process we care is KSU' + N
+ T + 'if (unlikely(susfs_is_current_ksu_domain())) {' + N
+ T + T + 'mnt = alloc_vfsmnt(fc->source ?: "none", true, 0);' + N
+ T + T + 'goto bypass_orig_flow;' + N
+ T + '}' + N
+ T + 'mnt = alloc_vfsmnt(fc->source ?: "none", false, 0);' + N
+ 'bypass_orig_flow:' + N
+ '#else' + N
+ T + 'mnt = alloc_vfsmnt(fc->source ?: "none");' + N
+ '#endif'
)
rep(
T + 'mnt->mnt_parent' + T + T + '= mnt;',
T + 'mnt->mnt_parent' + T + T + '= mnt;' + N
+ '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT' + N
+ T + '// If caller process is zygote, then it is a normal mount, so we just reorder the mnt_id' + N
+ T + 'if (susfs_is_current_zygote_domain()) {' + N
+ T + T + 'mnt->mnt.susfs_mnt_id_backup = mnt->mnt_id;' + N
+ T + T + 'mnt->mnt_id = current->susfs_last_fake_mnt_id++;' + N
+ T + '}' + N
+ '#endif'
)
rep(
T + 'int err;' + N + N + T + 'mnt = alloc_vfsmnt(old->mnt_devname);',
T + 'int err;' + N
+ '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT' + N
+ T + 'bool is_current_ksu_domain = susfs_is_current_ksu_domain();' + N
+ T + 'bool is_current_zygote_domain = susfs_is_current_zygote_domain();' + N
+ '#endif' + N + N
+ '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT' + N
+ T + 'if (unlikely(is_current_ksu_domain)) {' + N
+ T + T + 'if (!(flag & CL_COPY_MNT_NS)) {' + N
+ T + T + T + 'mnt = alloc_vfsmnt(old->mnt_devname, true, 0);' + N
+ T + T + T + 'goto bypass_orig_flow;' + N
+ T + T + '}' + N
+ T + T + 'mnt = alloc_vfsmnt(old->mnt_devname, true, old->mnt_id);' + N
+ T + T + 'if (mnt) {' + N
+ T + T + T + 'mnt->mnt.susfs_mnt_id_backup = DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE;' + N
+ T + T + '}' + N
+ T + T + 'goto bypass_orig_flow;' + N
+ T + '}' + N
+ T + 'if (likely(is_current_zygote_domain) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {' + N
+ T + T + 'mnt = alloc_vfsmnt(old->mnt_devname, true, 0);' + N
+ T + T + 'goto bypass_orig_flow;' + N
+ T + '}' + N
+ T + 'if ((flag & CL_COPY_MNT_NS) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {' + N
+ T + T + 'mnt = alloc_vfsmnt(old->mnt_devname, true, 0);' + N
+ T + T + 'goto bypass_orig_flow;' + N
+ T + '}' + N
+ T + 'mnt = alloc_vfsmnt(old->mnt_devname, false, 0);' + N
+ 'bypass_orig_flow:' + N
+ '#else' + N
+ T + 'mnt = alloc_vfsmnt(old->mnt_devname);' + N
+ '#endif'
)
open(p, 'w').write(s)
print("[+] fs/namespace.c adapted.")
PYEOF
    [ $? -eq 0 ] || { echo "[!] namespace adaptation failed, tree changed upstream?"; exit 1; }
    if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
        echo "[!] *.rej files present, fix manually."
        exit 1
    fi
fi

rm -rf anykernel
git clone https://github.com/osm0sis/AnyKernel3 --single-branch --depth=1 anykernel
sed -i "s/^kernel.string=.*/kernel.string=SamsungSM8250 by ${DEVICE_NAME}/" anykernel/anykernel.sh
sed -i "s/^device.name1=.*/device.name1=gts7l/" anykernel/anykernel.sh
sed -i "s/^device.name2=.*/device.name2=gts7lwifi/" anykernel/anykernel.sh

OUT_DIR="${KERNEL_DIR}/out_${DEVICE_NAME}"
MAKE_OPTS=(
    -j"$(nproc)"
    O="${OUT_DIR}"
    ARCH=arm64
    SUBARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CC="ccache clang"
    HOSTCC="ccache clang"
    CROSS_COMPILE="${CROSS_COMPILE}"
    CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
)

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

echo "[*] Merging ${BASE_FRAG} + kona-sec-common + ${DEVICE_NAME}.config ..."
ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" \
    "$BASE_FRAG" "$COMMON_FRAG" "$DEVICE_FRAG"

if [ "$ENABLE_KSU" -eq 1 ]; then
    scripts/config --file "${OUT_DIR}/.config" \
        -e KSU \
        -e THREAD_INFO_IN_TASK \
        -e KSU_SUSFS || echo "[!] KSU symbols missing, continuing"
fi

make "${MAKE_OPTS[@]}" olddefconfig
make "${MAKE_OPTS[@]}"

BOOT_DIR="${OUT_DIR}/arch/arm64/boot"
IMAGE=""
for cand in Image.gz-dtb Image.gz Image; do
    [ -f "${BOOT_DIR}/${cand}" ] && IMAGE="$cand" && break
done
if [ -z "$IMAGE" ]; then
    echo "[-] No kernel image in ${BOOT_DIR}"
    exit 1
fi

echo "[+] Built: ${BOOT_DIR}/${IMAGE}"
cp "${BOOT_DIR}/${IMAGE}" anykernel/
[ -f "${BOOT_DIR}/dtb" ] && cp "${BOOT_DIR}/dtb" anykernel/
[ -f "${BOOT_DIR}/dtbo.img" ] && cp "${BOOT_DIR}/dtbo.img" anykernel/
if [ -f "${BOOT_DIR}/Image" ] && [ "$IMAGE" != "Image" ]; then
    cp "${BOOT_DIR}/Image" anykernel/
fi

if [ "$ENABLE_KSU" -eq 1 ]; then KSU_STR="ReSukiSU-SuSFS"; else KSU_STR="NoKSU"; fi
SHA="$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
ZIP="SamsungSM8250_${DEVICE_NAME}_${KSU_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${SHA}.zip"

pushd anykernel > /dev/null
zip -r9 "../${ZIP}" ./* -x .git .gitignore ./*.zip > /dev/null
popd > /dev/null
echo "[+] Packed: ${ZIP}"
ccache -s
