# Arch package bump tool

`tool/arch/bump.dart` holds the version and PKGBUILD logic shared by the
Arch mirror pipeline. It is pure Dart (no Flutter), so it runs with plain
`dart run` and is unit-tested in `test/tool/arch/bump_test.dart`:

```
flutter test test/tool/arch
```

The function `computeBinaryPkgver(upstream)` returns the binary package's
version unchanged; the `pkgver` command below computes the source package's.

## `pkgver`

```
dart run tool/arch/bump.dart pkgver \
    --upstream 1.9.5 --ahead 17 --short-sha abc1234
```

Prints the source package's `pkgver` as one line. With `--ahead 0` it is
the upstream marketing version (`1.9.5`). With commits after the upstream
release tag it is `<marketing>.r<commitsAhead>.g<shortSha>`, the SHA cut to
seven characters (`1.9.5.r17.gabc1234`).

`--upstream` must be a plain `x.y.z` marketing version (no `v` prefix, no
build number), `--ahead` must be zero or more, and `--short-sha` must be at
least seven hexadecimal characters (it is ignored when `--ahead` is 0).
Bad values exit non-zero.

## `pkgrel`

```
dart run tool/arch/bump.dart pkgrel --current 1
dart run tool/arch/bump.dart pkgrel --current 1 --force
```

Prints the current `pkgrel`, or one more with `--force`, for a rebuild that
pacman must see as newer. `--current` must be at least 1.

## `rewrite`

```
dart run tool/arch/bump.dart rewrite \
    --file packaging/baocode/PKGBUILD \
    --pkgver 1.9.5.r17.gabc1234 \
    --pkgrel 1 \
    --commit abc1234 \
    --sums sha256sums=a1,b2 \
    --sums sha256sums_x86_64=c3,d4
```

Rewrites the file in place and prints a JSON summary:

```json
{"file":"packaging/baocode/PKGBUILD","pkgver":"1.9.5.r17.gabc1234","pkgrel":1,"commit":"abc1234","sha256sums":{"sha256sums":["a1","b2"],"sha256sums_x86_64":["c3","d4"]}}
```

Only assignments starting a line are touched: `pkgver=`, `pkgrel=`,
`_commit=` (only when `--commit` is given), and the checksum arrays named by
`--sums`. `_upstream_version=` and every other line, comments included, are
kept byte for byte. A one-line array stays one line; a multi-line array
stays multi-line, rewritten as a valid bash array of single-quoted values.

`--sums` is repeatable. `--sums a1,b2` without an array name rewrites
`sha256sums`; `--sums sha256sums_x86_64=c3,d4` rewrites that suffix variant
(`sha256sums_aarch64=`, ...). An empty value makes an empty array
(`--sums sha256sums=`).

The file must already contain every array named by `--sums`, and a
`_commit=` line when `--commit` is given; a missing line, an unclosed array
or an unreadable file exits non-zero without writing.

## Exit codes

- `0` — the value was printed, or the file was rewritten.
- `1` — an invalid value, a malformed or incomplete PKGBUILD, or an I/O
  error.
- `2` — bad command line; the usage is printed on stderr.