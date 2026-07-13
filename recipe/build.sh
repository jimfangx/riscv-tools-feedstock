#!/bin/bash

set -ex

TOOLCHAIN_NAME=riscv-tools

# --- RISC-V target configuration (passed through to build-toolchains.sh) ------
# ARCH / ABI : leave empty to use the toolchain default. With MULTILIB=1 the
#              toolchain builds the full multilib set and ARCH/ABI 
#              Defaults: ARCH=rv64gc  ABI=lp64d
# MULTILIB   : 1 to build multilib variants (--enable-multilib), empty to disable
ARCH="rv64gc"
ABI="lp64d"
MULTILIB=1 # enables -march=rv64gcv, -march=rv32i etc

# TOOLCHAIN_GCC: which gcc version to target
#   16 -> gcc-16 / gdb-16 / binutils-2.46  (tag 2026.07.12) - lts
#   14 -> gcc-14 / gdb-15 / binutils-2.43  (tag 2025.01.20) - last stable chipyard
TOOLCHAIN_GCC="${TOOLCHAIN_GCC:-16}"
# ------------------------------------------------------------------------------

# strip debugging info
export LDFLAGS="$LDFLAGS -s"

# ---------------------------------------------------------------------------
# Fetch the RISC-V GNU toolchain sources.
#
# riscv-gnu-toolchain stays a git submodule of this feedstock, but it is marked
# `update = none` in .gitmodules. That makes conda-build's source provisioning
# (`git submodule update --init --recursive`) SKIP it entirely, so conda-build
# never recursively clones the toolchain's own submodules (llvm, qemu, spike,
# pk, musl, uclibc-ng, ...) from often-flaky upstreams. Instead we own that
# here: force-check-out the pinned submodule (the gitlink is the pin) and
# initialize only the submodules needed for the newlib (elf) + linux (glibc)
# GNU toolchains.
#
# The sourceware.org repos routinely return HTTP 502 on clone, so redirect them
# to reliable GitHub mirrors (which also allow fetch-by-SHA, so --depth 1 works).
# ---------------------------------------------------------------------------
git config --global url."https://github.com/gnutools/binutils-gdb.git".insteadOf "https://sourceware.org/git/binutils-gdb.git"
git config --global url."https://github.com/bminor/glibc.git".insteadOf         "https://sourceware.org/git/glibc.git"
git config --global url."https://github.com/mirror/newlib-cygwin.git".insteadOf  "https://sourceware.org/git/newlib-cygwin.git"

retry() {  # retry <attempts> <cmd...>
    local n=$1; shift
    local i
    for i in $(seq 1 "$n"); do
        "$@" && return 0
        echo "  attempt ${i}/${n} failed: $*"
        sleep 10
    done
    return 1
}

# conda-build skipped the submodule (update=none); check it out ourselves at the
# pinned gitlink. --checkout overrides update=none.
retry 3 git submodule update --init --checkout -- riscv-gnu-toolchain

pushd riscv-gnu-toolchain
# Resolve the pinned upstream commit from TOOLCHAIN_GCC (or override by exporting
# TOOLCHAIN_COMMIT directly). Enforcing the commit here guarantees the lock
# regardless of the checked-out gitlink.
case "${TOOLCHAIN_GCC}" in
    16) TOOLCHAIN_COMMIT="${TOOLCHAIN_COMMIT:-2e37feb36e1152e965c56d29c0623d68b156c461}" ;;  # tag 2026.07.12
    14) TOOLCHAIN_COMMIT="${TOOLCHAIN_COMMIT:-a33dac0251d17a7b74d99bd8fd401bfce87d2aed}" ;;  # tag 2025.01.20
    *)  echo "ERROR: TOOLCHAIN_GCC must be 14 or 16 (got '${TOOLCHAIN_GCC}')"; exit 1 ;;
esac
echo "Checking out toolchain commit ${TOOLCHAIN_COMMIT}"
retry 3 git fetch origin "${TOOLCHAIN_COMMIT}"
git checkout --detach "${TOOLCHAIN_COMMIT}"
# init only the submodules needed for the newlib(elf)+linux(glibc) toolchains
git submodule sync
for sub in binutils gcc gdb glibc newlib; do
    retry 3 git submodule update --init --recursive --depth 1 "${sub}"
done
popd

# The gcc-14 line ships gdb-15, whose bundled readline trips gcc>=14's default
# -Werror=incompatible-pointer-types. Relax it for that line only (the gcc-16
# line's gdb-16 readline is already fixed, so it stays strict).
if [ "${TOOLCHAIN_GCC}" = "14" ]; then
    export CFLAGS="${CFLAGS:-} -Wno-error=incompatible-pointer-types"
fi

# Leave one core free: a full -j (all cores) saturated CPU + memory and froze
# the machine. Cap at (CPU_COUNT|nproc) - 1, floor of 1.
_NCPU="${CPU_COUNT:-$(nproc)}"
NPROC=$(( _NCPU > 1 ? _NCPU - 1 : 1 ))
echo "Building with -j ${NPROC} (of ${_NCPU} available cores)"
NPROC=$NPROC ./build-toolchains.sh \
    --prefix "$PREFIX/$TOOLCHAIN_NAME" \
    --clean-after-install \
    ${MULTILIB:+--multilib} \
    ${ARCH:+--arch $ARCH} \
    ${ABI:+--abi $ABI}

# create activate & deactivate scripts that manage the toolchain
mkdir -p "${PREFIX}"/etc/conda/{de,}activate.d

perl -pe 's/\@NATURE\@/activate/' "${RECIPE_DIR}"/activate.sh > "${PREFIX}"/etc/conda/activate.d/activate-${PKG_NAME}.sh
perl -pe 's/\@NATURE\@/deactivate/' "${RECIPE_DIR}"/activate.sh > "${PREFIX}"/etc/conda/deactivate.d/deactivate-${PKG_NAME}.sh

pushd $PREFIX/$TOOLCHAIN_NAME/sysroot

# Strip $ORIGIN/.*/lib (if it exists) from the RPATH of all sysroot binaries.
# Fixes linux boot (since the RPATH shouldn't be set for the sysroot ld*.so)
shopt -s globstar
for file in ** ;
do
    file -b "${file}" | grep -q 'ELF' || continue
    if output=$(patchelf --print-rpath $file); then
        echo "Current RPATH=$output for FILE=$file"
        if [[ $output == *":"* ]]; then
            mails=$(echo $output | tr ":" "\n")
            new_rpath=""
            for addr in $mails
            do
                if [[ $addr != *"lib"* ]]; then
                    new_rpath="${new_rpath}${addr}:"
                fi
            done
            new_rpath=$(echo $new_rpath | sed 's/.$//')
            patchelf --force-rpath --set-rpath $new_rpath $file
            echo "Modify RPATH=$new_rpath"
        else
            echo "Remove RPATH"
            patchelf --remove-rpath $file
        fi
    else
        # not a elf that we can modify
        echo "Skip FILE=$file"
        continue
    fi
done

popd
