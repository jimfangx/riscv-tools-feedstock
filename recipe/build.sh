#!/bin/bash

set -ex

TOOLCHAIN_NAME=riscv-tools

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
# Lock to the pinned upstream commit (master HEAD at pinning time). The feedstock
# gitlink is also set to this commit; enforcing it here guarantees the lock
# regardless of the checked-out gitlink. Override by exporting TOOLCHAIN_COMMIT.
TOOLCHAIN_COMMIT="${TOOLCHAIN_COMMIT:-2e37feb36e1152e965c56d29c0623d68b156c461}"
echo "Checking out toolchain commit ${TOOLCHAIN_COMMIT}"
retry 3 git fetch origin "${TOOLCHAIN_COMMIT}"
git checkout --detach "${TOOLCHAIN_COMMIT}"
# init only the submodules needed for the newlib(elf)+linux(glibc) toolchains
git submodule sync
for sub in binutils gcc gdb glibc newlib; do
    retry 3 git submodule update --init --recursive --depth 1 "${sub}"
done
popd

# Leave one core free: a full -j (all cores) saturated CPU + memory and froze
# the machine. Cap at (CPU_COUNT|nproc) - 1, floor of 1.
_NCPU="${CPU_COUNT:-$(nproc)}"
NPROC=$(( _NCPU > 1 ? _NCPU - 1 : 1 ))
echo "Building with -j ${NPROC} (of ${_NCPU} available cores)"
NPROC=$NPROC ./build-toolchains.sh --prefix $PREFIX/$TOOLCHAIN_NAME --clean-after-install

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
