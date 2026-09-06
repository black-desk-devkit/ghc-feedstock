# Carried patches

Every patch in `recipe/` is documented here with the exact failure that
motivated it, how the root cause was found, and its upstreaming status.
These write-ups are intended to be reusable as upstream issue/MR
descriptions.

---

## `rts-linker-sysroot-fallback.patch`

**TL;DR: Template Haskell and GHCi crash with
`<command line>: /lib64/libc.so.6: cannot open shared object file` when
GHC is configured with a relocated cross toolchain (e.g. conda-forge's
sysroot'd binutils) and runs on a host whose filesystem layout differs
from the sysroot (Debian/Ubuntu, NixOS).**

### How it was found

Building ShellCheck 0.11.0 with conda-forge `ghc` 8.10.7 + `gcc` on an
`ubuntu-latest` (24.04) runner failed at exactly the **first module with
`{-# LANGUAGE TemplateHaskell #-}`** (`ShellCheck.Fixer`):

```
[ 6 of 28] Compiling ShellCheck.Fixer ( ... )
<command line>: /lib64/libc.so.6: cannot open shared object file: No such file or directory
Error: [Cabal-7125] Failed to build ShellCheck-0.11.0
```

Modules 1-5 (no TH) compiled fine. `cabal build -v3` showed the `ghc
--make` command carried no relevant `-L`/sysroot flags, so the failure
happened inside GHC's runtime linker, not Cabal.

### Root cause chain

1. TH splices run in-process and need the RTS linker to load the C
   libraries declared in `extra-libraries` of the involved packages
   (e.g. `c m` in `ghc-prim`).
2. The compiler-side `locateLib` (`compiler/GHC/Runtime/Linker.hs` ->
   `searchForLibUsingGcc` -> `askLd`) resolves a library by running the
   configured linker with `--print-file-name=libc.so`.
3. GHC's `settings` (generated while the conda toolchain was active)
   names `x86_64-conda-linux-gnu-ld`, which has
   `--with-sysroot=$PREFIX/x86_64-conda-linux-gnu/sysroot`
   **compiled into the binary**. It therefore prints
   `$SYSROOT/lib64/libc.so` — a GNU ld **linker script** (text), not ELF.
4. dlopen of that path fails with `invalid ELF header`; the GHC #2615
   workaround parses the script, extracts the **first** `GROUP(...)`
   token and dlopens it verbatim: `/lib64/libc.so.6` — an absolute path
   written for the CentOS-derived sysroot root.
5. Debian-family hosts keep libraries in `/lib/x86_64-linux-gnu/`;
   `/lib64/` only contains the loader symlink. dlopen fails with ENOENT
   and the error is fatal.

Corroborating experiment: rewriting `libc.so`'s GROUP entries to bare
SONAMEs inside the build sysroot moved the failure to
`/lib64/libm.so.6` (the next `extra-libraries` entry), proving the
parse-and-follow chain.

### Why the fix is a *fallback*, not a removal of the #2615 logic

On native toolchains the #2615 script-following is **load-bearing**:
for a stock GHC bindist on Ubuntu, `ld --print-file-name=libc.so`
returns the *system* dev script whose absolute GROUP paths exist on the
host — that is exactly how `c`/`m` become loadable at all (a bare
`dlopen("libc.so")` would fail; the ld.so cache only contains
versioned SONAMEs). Therefore the first-choice behavior must stay.

### The fix

When following a GROUP entry fails **and** the entry contained a `/`,
retry with the bare file name so the host's dynamic loader resolves it
through its own search order (`LD_LIBRARY_PATH`, `ld.so.cache`, default
dirs). Native setups are unaffected (the first dlopen succeeds there).

* In GHC 8.10.7 the relevant code lived in `rts/Linker.c` `addDLL`.
* In GHC 9.12.4 (this recipe) it lives in
  `rts/linker/Elf.c` `loadNativeObjFromLinkerScript_ELF`; the same
  blind GROUP-following exists and the patch is adapted to the new
  `loadNativeObj_POSIX` API.

### Upstreaming status

* Verified the same logic exists in 8.10.7, 9.6.7, 9.8.4, 9.10.1 and
  9.12.4.
* Affects all conda/Nix-style relocated toolchains on Debian-layout
  hosts. The conda-forge shellcheck feedstock works around the symptom
  by not compiling on Linux at all (it ships upstream prebuilt
  binaries), and the conda-forge ghc feedstock only builds/tests inside
  CentOS-family containers where the absolute paths happen to exist.
* Plan: file a GHC issue with this write-up + reproduction, then MR
  against master.

### Validation

The linux-64 package built by this recipe (GHC 9.12.4 on
ubuntu-latest, conda gcc 16.2 sysroot toolchain) passes a Template
Haskell smoke test **in a fresh test environment on the Ubuntu host**:

```
[1 of 2] Compiling Main ( th_smoke.hs, th_smoke.o )
[2 of 2] Linking th_smoke
template haskell works
✔ all tests passed!
```

This is precisely the scenario in which the stock conda-forge GHC
dies with `<command line>: /lib64/libc.so.6: cannot open shared
object file`.

---

## Build notes (not patches, but same "why")

* **Why 9.12.4 instead of the conda-forge-familiar 8.10.7**: three of
  the four patches 8.10.7 needed on modern CI hosts were purely
  version-age artifacts that vanish with a current GHC:
  1. hp2ps K&R declarations vs. C23 (GCC >= 14 default),
  2. `-Werror=unused-but-set-variable` vs. new GCC 16 diagnostics,
  3. no AArch64 NCG in 8.10 (hard LLVM 9-13 dependency; NCG landed in
     9.0).
  Only the Linker patch above is a real cross-version bug and carries
  over (re-targeted to its new home in `rts/linker/Elf.c`).
* **Bootstrap bindist choice**: the stage 0 binary distribution must
  actually run on the build host. deb12 (glibc 2.36) and
  aarch64-apple-darwin bindists work on ubuntu-latest / macos-latest
  runners. (Historical note: conda-forge's centos7 stage 0 needs
  `libtinfo.so.5`, which does not exist on Ubuntu 24.04 — that failure
  is what forced this investigation of bindist selection.)
* **Hadrian bootstrap**: `hadrian/build` first compiles the hadrian
  tool itself with the bootstrap compiler via cabal-install; hadrian's
  dependencies (Shake, alex, happy, ...) are fetched from Hackage at
  build time (the GHC source tree ships no freeze file). `GHC`/`CABAL`
  env vars let us point it at `$stage0/bin/ghc` and conda's `cabal`.
* **rattler-build migration** (from the original conda-build recipe):
  `$BUILD`/`$HOST` become `$build_alias`/`$host_alias`; `CPU_COUNT` is
  not exported (fall back to `getconf _NPROCESSORS_ONLN`); sources are
  selected per-platform with `if/then` selectors.
* **Making the host prefix visible to GHC-driven compilations**: GHC
  composes C compiler command lines from its settings file and package
  metadata, insulated from `CFLAGS`/`CPPFLAGS` (the channel conda
  activation uses), and the *host* toolchain used by the bootstrap
  compiler deliberately carries no user flags (`m4/ghc_toolchain.m4`
  only passes `cc-opt` for the *target* toolchain). The channels that
  work are the ones read by the C compiler **itself** and inherited by
  every subprocess: `CPATH` and `LIBRARY_PATH` (plus
  `DYLD_FALLBACK_LIBRARY_PATH` on macOS for build-time test
  executions). Do not "fix" this by copying headers into the sysroot;
  that mutates shared toolchain state.
* **`unset host_alias build_alias` before `./configure`**: autoconf
  derives the build triple from `$build_alias`; conda's
  `x86_64-conda-linux-*` differs textually from the bootstrap
  compiler's `x86_64-unknown-linux-*` and GHC's configure rejects the
  mismatch.
* **`PYTHON=$BUILD_PREFIX/bin/python`**: rattler-build exports
  `PYTHON=$PREFIX/bin/python` (host env, python only installed in the
  build env); GHC's configure records it verbatim and hadrian needs
  python to generate RTS headers.
* **autotools in build deps**: some in-tree packages (haddock-library)
  ship no pre-generated configure; cabal invokes `autoreconf`.
* **hadrian's install rule needs `--prefix` as its own argument** —
  configure's `--prefix` does not propagate to it.
* **license**: rattler-build resolves `license_file` relative to the
  source/recipe dirs, but `${{ SRC_DIR }}` is undefined at render
  time; carrying the (stable) GHC license text in the recipe dir is
  the robust form.
* **macOS iconv identity**: on macOS the conda toolchain resolves
  `-liconv` to conda's own GNU libiconv (`libiconv` is pulled into
  every osx env transitively via the compiler stack), which only
  exports the GNU-prefixed symbols `_libiconv*` and renames the POSIX
  calls in its header (`#define iconv libiconv`).  Apple's SDK header
  instead yields bare `_iconv*` references.  ghc-internal's
  `cbits/iconv.c` must therefore be compiled against **conda's**
  header so that `libHSghc-internal.a` references the symbols the
  linker will actually find; this is why `libiconv` is a host
  dependency and `./configure` gets
  `--with-iconv-includes/--with-iconv-libraries`: hadrian
  forwards them to ghc-internal's cabal configure, which records
  `include-dirs`/`extra-lib-dirs`/`extra-libraries` in its buildinfo —
  so the header used to compile `iconv.c` and the library every
  user-program link resolves are both pinned to `$PREFIX`
  deterministically (CPATH alone does work through GHC, but the
  explicit buildinfo channel does not depend on env propagation).
  One wrinkle remains: hadrian's stage-0 "in-tree libraries" set does
  not include ghc-internal, so the stage-0 bootstrap `ghc` links the
  **upstream prebuilt** `libHSghc-internal-...-c99a.a`, whose iconv.o
  immutably references the bare POSIX names that only Apple's SDK
  libiconv provides.  build.sh therefore appends
  `-L$(xcrun --show-sdk-path)/usr/lib` to the *bootstrap compiler's*
  settings link flags, pinning `-liconv` to Apple's during bootstrap
  while everything we build and ship uses conda's.
