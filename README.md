# ghc-feedstock (black-desk-devkit)

Fork of [conda-forge/ghc-feedstock](https://github.com/conda-forge/ghc-feedstock),
repackaged with [rattler-build](https://github.com/prefix-dev/rattler-build)
(`recipe.yaml`), building **GHC 9.12.4** from source (Hadrian build
system) on plain GitHub-hosted Ubuntu/macOS runners.

## Why

The conda-forge GHC package (8.10.7, built only inside CentOS-family
containers) cannot run Template Haskell / GHCi on hosts whose filesystem
layout differs from the (CentOS-derived) sysroot used by the conda
toolchain: GHC's RTS linker resolves C libraries via its configured
sysroot'd `ld`, gets a GNU ld *linker script* back, follows the script's
absolute `GROUP(...)` paths (e.g. `/lib64/libc.so.6`) straight into
`dlopen`, and dies with ENOENT on Debian-family hosts.

This feedstock carries a small patch (see `PATCHES.md`) that falls back
to the bare file name when a GROUP entry does not exist on the host,
letting the host dynamic loader resolve it. First-choice behavior is
unchanged for native toolchains.

## Tests

Besides `ghc hello.hs`, the package is tested with a Template Haskell
smoke test (`th_smoke.hs`) that exercises exactly the patched code path
on the Ubuntu CI host.
