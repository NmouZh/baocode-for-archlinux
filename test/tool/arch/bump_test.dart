import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/arch/bump.dart';

void main() {
  group('computeSourcePkgver', () {
    test('is the marketing version when level with the upstream tag', () {
      expect(computeSourcePkgver('1.9.5', 0, ''), '1.9.5');
    });

    test('counts the commits after the tag and names the commit', () {
      expect(computeSourcePkgver('1.9.5', 17, 'abc1234'), '1.9.5.r17.gabc1234');
    });

    test('keeps the first seven characters of a full SHA', () {
      expect(
        computeSourcePkgver('1.9.5', 1, 'abcdef1234567890abcdef1234567890'),
        '1.9.5.r1.gabcdef1',
      );
    });

    test('refuses a negative commit count', () {
      expect(
        () => computeSourcePkgver('1.9.5', -1, 'abc1234'),
        throwsArgumentError,
      );
    });

    test('refuses a SHA that is not seven hex characters at least', () {
      expect(
        () => computeSourcePkgver('1.9.5', 1, 'abc12'),
        throwsArgumentError,
      );
      expect(
        () => computeSourcePkgver('1.9.5', 1, 'not-hex'),
        throwsArgumentError,
      );
    });

    test('refuses anything but a plain marketing version', () {
      for (final version in ['', 'v1.9.5', '1.9', '1.9.5+31', '1.9.5-rc1']) {
        expect(
          () => computeSourcePkgver(version, 1, 'abc1234'),
          throwsArgumentError,
          reason: version,
        );
      }
    });
  });

  group('computeBinaryPkgver', () {
    test('is the marketing version untouched', () {
      expect(computeBinaryPkgver('1.9.5'), '1.9.5');
    });

    test('refuses anything but a plain marketing version', () {
      for (final version in ['', 'v1.9.5', '1.9', '1.9.5+31']) {
        expect(
          () => computeBinaryPkgver(version),
          throwsArgumentError,
          reason: version,
        );
      }
    });
  });

  group('nextPkgrel', () {
    test('stays put when this is not a forced rebuild', () {
      expect(nextPkgrel(5, false), 5);
    });

    test('goes up by one on a forced rebuild', () {
      expect(nextPkgrel(5, true), 6);
    });

    test('refuses a pkgrel below one', () {
      expect(() => nextPkgrel(0, false), throwsArgumentError);
      expect(() => nextPkgrel(-1, true), throwsArgumentError);
    });
  });

  group('rewritePkgbuild', () {
    test('rewrites only the lines it owns, leaving every other byte', () {
      expect(
        rewritePkgbuild(
          _pkgbuild,
          '1.9.5.r17.gabc1234',
          2,
          commit: 'abcdef1234567890',
          sha256sums: {
            'sha256sums': ['a1', 'b2'],
            'sha256sums_x86_64': ['c3'],
            'sha256sums_aarch64': ['d4'],
          },
        ),
        _rewrittenPkgbuild,
      );
    });

    test('leaves _commit alone when no commit is given', () {
      final rewritten = rewritePkgbuild(
        _pkgbuild,
        '1.9.5',
        1,
        sha256sums: {
          'sha256sums': ['a1'],
          'sha256sums_x86_64': ['c3'],
          'sha256sums_aarch64': ['d4'],
        },
      );
      expect(rewritten, contains('_commit=deadbeefdeadbeef'));
    });

    test('does not need a _commit line when no commit is given', () {
      final content = _pkgbuild.replaceFirst('_commit=deadbeefdeadbeef\n', '');
      final rewritten = rewritePkgbuild(content, '1.9.5', 1);
      expect(rewritten, contains('pkgver=1.9.5'));
      expect(rewritten, contains('pkgrel=1'));
    });

    test('writes an empty checksum array as an empty one-line array', () {
      expect(
        rewritePkgbuild(
          'pkgver=1.9.4\npkgrel=1\nsha256sums=(\'old\')\n',
          '1.9.5',
          1,
          sha256sums: {'sha256sums': []},
        ),
        contains('sha256sums=()\n'),
      );
    });

    test('keeps CRLF line endings', () {
      expect(
        rewritePkgbuild(
          'pkgver=1.9.4\r\n'
              "pkgrel=1\r\n"
              'sha256sums=(\r\n'
              "  'a'\r\n"
              "  'b'\r\n"
              ')\r\n'
              'keep=me\r\n',
          '1.9.5',
          2,
          sha256sums: {
            'sha256sums': ['a1', 'b2'],
          },
        ),
        'pkgver=1.9.5\r\n'
        "pkgrel=2\r\n"
        'sha256sums=(\r\n'
        "  'a1'\r\n"
        "  'b2'\r\n"
        ')\r\n'
        'keep=me\r\n',
      );
    });

    test('a missing pkgver, pkgrel or checksum array throws', () {
      expect(
        () => rewritePkgbuild('pkgrel=1\n', '1.9.5', 1),
        throwsFormatException,
      );
      expect(
        () => rewritePkgbuild('pkgver=1.9.5\n', '1.9.5', 1),
        throwsFormatException,
      );
      expect(
        () => rewritePkgbuild(
          'pkgver=1.9.5\npkgrel=1\n',
          '1.9.5',
          1,
          sha256sums: {
            'sha256sums': ['a1'],
          },
        ),
        throwsFormatException,
      );
      expect(
        () => rewritePkgbuild(
          'pkgver=1.9.5\npkgrel=1\n',
          '1.9.5',
          1,
          commit: 'abcdef1234567890',
        ),
        throwsFormatException,
      );
    });

    test('an unclosed checksum array throws', () {
      expect(
        () => rewritePkgbuild(
          'pkgver=1.9.5\npkgrel=1\nsha256sums=(\n  \'a\'\n',
          '1.9.5',
          1,
          sha256sums: {
            'sha256sums': ['a1'],
          },
        ),
        throwsFormatException,
      );
    });
  });

  group('bump CLI', () {
    test('pkgver prints the source package version', () {
      final out = StringBuffer();
      final err = StringBuffer();
      expect(
        runBumpCli(
          [
            'pkgver',
            '--upstream',
            '1.9.5',
            '--ahead',
            '17',
            '--short-sha',
            'abcdef1234',
          ],
          out: out,
          err: err,
        ),
        0,
      );
      expect(out.toString(), '1.9.5.r17.gabcdef1\n');
      expect(err.toString(), isEmpty);
    });

    test('pkgver prints the marketing version at zero ahead', () {
      final out = StringBuffer();
      expect(
        runBumpCli(
          [
            'pkgver',
            '--upstream',
            '1.9.5',
            '--ahead',
            '0',
            '--short-sha',
            'abcdef1',
          ],
          out: out,
          err: StringBuffer(),
        ),
        0,
      );
      expect(out.toString(), '1.9.5\n');
    });

    test('pkgrel stays put, and goes up with --force', () {
      final out = StringBuffer();
      expect(
        runBumpCli(['pkgrel', '--current', '3'], out: out, err: StringBuffer()),
        0,
      );
      expect(out.toString(), '3\n');
      out.clear();
      expect(
        runBumpCli(
          ['pkgrel', '--current', '3', '--force'],
          out: out,
          err: StringBuffer(),
        ),
        0,
      );
      expect(out.toString(), '4\n');
    });

    test('rewrite writes the file and prints a JSON summary', () {
      final directory = Directory.systemTemp.createTempSync('bump_test_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/PKGBUILD')
        ..writeAsStringSync(
          'pkgver=1.9.4\n'
          'pkgrel=1\n'
          '_commit=old\n'
          "sha256sums=('old')\n"
          "sha256sums_x86_64=('old')\n",
        );
      final out = StringBuffer();
      final err = StringBuffer();
      expect(
        runBumpCli(
          [
            'rewrite',
            '--file',
            file.path,
            '--pkgver',
            '1.9.5.r17.gabcdef1',
            '--pkgrel',
            '2',
            '--commit',
            'abcdef1234567890',
            '--sums',
            'a1,b2',
            '--sums',
            'sha256sums_x86_64=c3,d4',
          ],
          out: out,
          err: err,
        ),
        0,
      );
      expect(err.toString(), isEmpty);
      expect(
        file.readAsStringSync(),
        'pkgver=1.9.5.r17.gabcdef1\n'
        'pkgrel=2\n'
        '_commit=abcdef1234567890\n'
        "sha256sums=('a1' 'b2')\n"
        "sha256sums_x86_64=('c3' 'd4')\n",
      );
      expect(jsonDecode(out.toString()), {
        'file': file.path,
        'pkgver': '1.9.5.r17.gabcdef1',
        'pkgrel': 2,
        'commit': 'abcdef1234567890',
        'sha256sums': {
          'sha256sums': ['a1', 'b2'],
          'sha256sums_x86_64': ['c3', 'd4'],
        },
      });
    });

    test('a bad command or option explains itself on stderr', () {
      for (final arguments in [
        <String>[],
        ['nope'],
        ['pkgver', '--upstream', '1.9.5'],
        ['pkgrel', '--current', '0'],
        [
          'rewrite',
          '--file',
          '/no/such/PKGBUILD',
          '--pkgver',
          '1.9.5',
          '--pkgrel',
          '1',
        ],
      ]) {
        final out = StringBuffer();
        final err = StringBuffer();
        expect(
          runBumpCli(arguments, out: out, err: err),
          isNot(0),
          reason: '$arguments',
        );
        expect(out.toString(), isEmpty, reason: '$arguments');
        expect(err.toString(), isNotEmpty, reason: '$arguments');
      }
    });
  });
}

const _pkgbuild = r'''
# Maintainer: NmouZh <noreply@baocode.dev>
pkgname=baocode
pkgver=1.9.4
pkgrel=1
_commit=deadbeefdeadbeef
_upstream_version=1.9.4

arch=('x86_64' 'aarch64')
source=("baocode-$_commit.tar.gz" "BaoCode-${_upstream_version}-linux-amd64.tar.gz")
sha256sums=('old1' 'old2')
sha256sums_x86_64=(
  'old3'
)
sha256sums_aarch64=('old4')

build() {
  # pkgver=inside-a-comment
  local pkgver=indented
}
''';

const _rewrittenPkgbuild = r'''
# Maintainer: NmouZh <noreply@baocode.dev>
pkgname=baocode
pkgver=1.9.5.r17.gabc1234
pkgrel=2
_commit=abcdef1234567890
_upstream_version=1.9.4

arch=('x86_64' 'aarch64')
source=("baocode-$_commit.tar.gz" "BaoCode-${_upstream_version}-linux-amd64.tar.gz")
sha256sums=('a1' 'b2')
sha256sums_x86_64=(
  'c3'
)
sha256sums_aarch64=('d4')

build() {
  # pkgver=inside-a-comment
  local pkgver=indented
}
''';
