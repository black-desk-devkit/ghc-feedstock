#!/bin/bash

set -exuo pipefail

JOBS="${CPU_COUNT:-$(getconf _NPROCESSORS_ONLN)}"

# Load-bearing: autoconf derives the build triple from these environment
# variables when set, and the conda triples (x86_64-conda-linux-*) differ
# textually from the bootstrap compiler's (x86_64-unknown-linux-*), which
# GHC's configure rejects as a platform mismatch. Unset so config.guess
# canonicalizes both sides the same way.
unset host_alias build_alias

mkdir stage0
stage0="$(pwd)/stage0"

# stage0: install the upstream binary distribution (bootstrap compiler).
pushd binary
  ./configure --prefix="$stage0"
  make install -j"$JOBS"
popd

if [[ "${target_platform}" == osx-* ]]; then
  # The stage-0 compiler must link the *upstream prebuilt* ghc-internal
  # static library (unit id *-c99a from the bindist; hadrian's stage-0
  # in-tree-library set does not include ghc-internal), whose iconv.o
  # references the bare POSIX _iconv symbols that only Apple's SDK
  # libiconv provides.  conda's libiconv (in the host prefix for our own
  # in-tree builds) only exports _libiconv*, and LIBRARY_PATH would make
  # -liconv resolve to it and break the bootstrap link.  Pin the SDK's
  # lib dir first in the bootstrap compiler's link flags; this only
  # affects stage-0 links against the immutable prebuilt archives.
  sdk_lib="$(xcrun --show-sdk-path)/usr/lib"
  settings="$stage0/lib/ghc-${PKG_VERSION}/lib/settings"
  python3 - "$settings" "$sdk_lib" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
key = ',("C compiler link flags", "'
i = s.index(key) + len(key)
j = s.index('")', i)
p.write_text(s[:j] + " -L" + sys.argv[2] + s[j:])
PYEOF
fi

# stage1: build the compiler we actually ship (with the RTS linker patch),
# using Hadrian. hadrian/build first compiles the hadrian tool itself with
# the bootstrap compiler via cabal-install (dependencies from Hackage), then
# uses it to orchestrate the build.
pushd source
  (
    PATH="$stage0/bin:${SRC_DIR}/cabal-install:$PATH"
    # consumed by hadrian/build-cabal
    export GHC=ghc
    export CABAL=cabal
    # rattler-build exports PYTHON="$PREFIX/bin/python" (host env, where
    # python is not installed); GHC's configure records it verbatim and
    # hadrian uses the recorded interpreter to generate RTS headers.
    export PYTHON="$BUILD_PREFIX/bin/python"
    # GHC composes its C compiler command lines from its settings file
    # and package metadata, insulated from CFLAGS/CPPFLAGS (the channel
    # conda activation uses).  CPATH and LIBRARY_PATH are read by the C
    # compiler itself at run time and inherited by every subprocess, so
    # they reach GHC-driven C compilations of all stages (including the
    # bootstrap compiler, whose host toolchain deliberately carries no
    # user flags) without mutating the sysroot.
    export CPATH="$PREFIX/include${CPATH:+:${CPATH}}"
    export LIBRARY_PATH="$PREFIX/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}"
    if [[ "${target_platform}" == osx-* ]]; then
      # hadrian's install rule executes freshly built binaries whose
      # rpaths only cover the bindist layout; libHSrts needs conda's
      # libffi.8.dylib from $PREFIX/lib at that point.
      export DYLD_FALLBACK_LIBRARY_PATH="$PREFIX/lib${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"
    fi

    cabal update

    # NB: GHC 9.12's configure does not recognize --with-gmp-{includes,libraries}
    # (it warns about unrecognized options); gmp and ncurses are actually found
    # through the CPATH/LIBRARY_PATH exports above.
    ./configure \
      --prefix="$PREFIX" \
      --with-ffi-includes="$PREFIX/include" \
      --with-ffi-libraries="$PREFIX/lib" \
      --with-system-libffi \
      --with-iconv-includes="$PREFIX/include" \
      --with-iconv-libraries="$PREFIX/lib"

    hadrian/build -j"$JOBS" --flavour=release --docs=none --prefix="$PREFIX" install
  )
popd

# Delete the package cache as it is invalid on installation.
# It is regenerated on activation by activate.sh (ghc-pkg recache).
rm -f "$PREFIX/lib/ghc-${PKG_VERSION}/package.conf.d/package.cache"

mkdir -p "${PREFIX}/etc/conda/activate.d"
cp "${RECIPE_DIR}/activate.sh" "${PREFIX}/etc/conda/activate.d/${PKG_NAME}_activate.sh"
