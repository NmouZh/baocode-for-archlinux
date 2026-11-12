import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/update/arch_release.dart';

Map<String, Object?> assetJson(
  String name, {
  String? url,
  int size = 120,
  String? digest,
}) => {
  'name': name,
  'browser_download_url':
      url ??
      'https://github.com/NmouZh/baocode-for-archlinux/releases/download/v1.9.5/$name',
  'size': size,
  'digest': digest,
};

Map<String, Object?> releaseJson(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  String body = '',
  List<Map<String, Object?>> assets = const [],
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'body': body,
  'assets': assets,
};

List<GitHubRelease> releasesOf(List<Object?> json) =>
    parseGitHubReleases(jsonDecode(jsonEncode(json)));

void main() {
  group('GitHub releases', () {
    test('parses the fields the Arch updater uses', () {
      final releases = releasesOf([
        releaseJson(
          'v1.9.5',
          body: 'notes',
          assets: [
            assetJson(
              'baocode-1.9.5-1-x86_64.pkg.tar.zst',
              digest: 'sha256:abc123',
            ),
          ],
        ),
      ]);

      final release = releases.single;
      expect(release.tag, 'v1.9.5');
      expect(release.body, 'notes');
      expect(release.draft, isFalse);
      expect(release.prerelease, isFalse);
      final asset = release.assets.single;
      expect(asset.name, 'baocode-1.9.5-1-x86_64.pkg.tar.zst');
      expect(
        asset.downloadUrl,
        'https://github.com/NmouZh/baocode-for-archlinux/releases/download/v1.9.5/baocode-1.9.5-1-x86_64.pkg.tar.zst',
      );
      expect(asset.size, 120);
      expect(asset.digest, 'sha256:abc123');
    });

    test('ignores malformed releases and assets', () {
      final releases = releasesOf([
        'not a release',
        {'tag_name': '', 'assets': <Object?>[]},
        {'draft': false, 'assets': <Object?>[]},
        {
          'tag_name': 'v1.9.5',
          'assets': [
            'nope',
            {'name': 'baocode-1.9.5-1-x86_64.pkg.tar.zst'},
            {'browser_download_url': 'https://example.com/x'},
            assetJson('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'),
          ],
        },
      ]);

      expect(releases, hasLength(1));
      expect(releases.single.assets, hasLength(1));
      expect(
        releases.single.assets.single.name,
        'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
      );
    });

    test('selects the highest marketing version, ignoring drafts and '
        'pre-releases', () {
      final releases = releasesOf([
        releaseJson('v1.9.9'),
        releaseJson('v1.9.10'),
        releaseJson('v2.0.0', draft: true),
        releaseJson('v2.1.0', prerelease: true),
        releaseJson('v1.10.0'),
      ]);

      expect(selectLatestRelease(releases)?.tag, 'v1.10.0');
    });

    test('orders version parts numerically, not as text', () {
      final releases = releasesOf([
        releaseJson('1.9.9'),
        releaseJson('v1.9.10'),
        releaseJson('1.9.8'),
      ]);

      expect(selectLatestRelease(releases)?.tag, 'v1.9.10');
    });

    test('tolerates the v prefix and does not need a latest marker', () {
      final releases = releasesOf([
        releaseJson('v1.8.0'),
        releaseJson('1.9.5'),
        releaseJson('v1.9.4'),
      ]);

      expect(selectLatestRelease(releases)?.tag, '1.9.5');
    });

    test('has no latest release when none is usable', () {
      expect(selectLatestRelease(const []), isNull);
      expect(
        selectLatestRelease(
          releasesOf([
            releaseJson('v1.9.5', draft: true),
            releaseJson('v1.9.6', prerelease: true),
            releaseJson('nightly'),
          ]),
        ),
        isNull,
      );
    });
  });

  group('architecture', () {
    test('maps machine names to Arch architectures', () {
      expect(archFromMachine('x86_64'), 'x86_64');
      expect(archFromMachine('amd64'), 'x86_64');
      expect(archFromMachine('aarch64'), 'aarch64');
      expect(archFromMachine('arm64'), 'aarch64');
    });

    test('has no architecture for other machines', () {
      expect(archFromMachine('i686'), isNull);
      expect(archFromMachine('riscv64'), isNull);
      expect(archFromMachine(''), isNull);
    });
  });

  group('package asset', () {
    GitHubRelease releaseWithBothPackages() => releasesOf([
      releaseJson(
        'v1.9.5',
        assets: [
          assetJson('baocode-1.9.5-1-x86_64.pkg.tar.zst'),
          assetJson('baocode-1.9.5-1-aarch64.pkg.tar.zst'),
          assetJson('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'),
          assetJson('baocode-bin-1.9.5-1-aarch64.pkg.tar.zst'),
        ],
      ),
    ]).single;

    test('picks the package matching both name and architecture', () {
      final release = releaseWithBothPackages();
      expect(
        selectPackageAsset(release, 'baocode', 'x86_64')?.name,
        'baocode-1.9.5-1-x86_64.pkg.tar.zst',
      );
      expect(
        selectPackageAsset(release, 'baocode', 'aarch64')?.name,
        'baocode-1.9.5-1-aarch64.pkg.tar.zst',
      );
      expect(
        selectPackageAsset(release, 'baocode-bin', 'x86_64')?.name,
        'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
      );
      expect(
        selectPackageAsset(release, 'baocode-bin', 'aarch64')?.name,
        'baocode-bin-1.9.5-1-aarch64.pkg.tar.zst',
      );
    });

    test('does not let the shorter package name match the longer one', () {
      final binOnly = releasesOf([
        releaseJson(
          'v1.9.5',
          assets: [assetJson('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst')],
        ),
      ]).single;

      expect(selectPackageAsset(binOnly, 'baocode', 'x86_64'), isNull);
      expect(
        selectPackageAsset(binOnly, 'baocode-bin', 'x86_64')?.name,
        'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
      );
    });

    test('has no asset when the architecture or package is missing', () {
      final release = releaseWithBothPackages();
      expect(selectPackageAsset(release, 'baocode', 'riscv64'), isNull);
      expect(selectPackageAsset(release, 'other', 'x86_64'), isNull);
      expect(
        selectPackageAsset(
          releasesOf([releaseJson('v1.9.5')]).single,
          'baocode',
          'x86_64',
        ),
        isNull,
      );
    });

    test('needs a pkgrel and the right architecture', () {
      final noPkgrel = releasesOf([
        releaseJson(
          'v1.9.5',
          assets: [assetJson('baocode-1.9.5-x86_64.pkg.tar.zst')],
        ),
      ]).single;
      expect(selectPackageAsset(noPkgrel, 'baocode', 'x86_64'), isNull);

      final otherArch = releasesOf([
        releaseJson(
          'v1.9.5',
          assets: [assetJson('baocode-1.9.5-1-aarch64.pkg.tar.zst')],
        ),
      ]).single;
      expect(selectPackageAsset(otherArch, 'baocode', 'x86_64'), isNull);
    });
  });

  group('package file name', () {
    test('matches only the exact package name it was built from', () {
      expect(
        isPackageAssetOf(
          'baocode-1.9.5.r17.gabc1234-1-x86_64.pkg.tar.zst',
          'baocode',
        ),
        isTrue,
      );
      expect(
        isPackageAssetOf(
          'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
          'baocode-bin',
        ),
        isTrue,
      );
      expect(
        isPackageAssetOf('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst', 'baocode'),
        isFalse,
        reason: 'the version has to start where the shorter name ends',
      );
      expect(
        isPackageAssetOf('baocode-1.9.5-1-x86_64.pkg.tar.zst', 'baocode-bin'),
        isFalse,
      );
    });

    test('rejects other names, other formats and a version without digits', () {
      expect(
        isPackageAssetOf('baocode-1.9.5-1-x86_64.pkg.tar.xz', 'baocode'),
        isFalse,
      );
      expect(
        isPackageAssetOf('/tmp/baocode-1.9.5-1-x86_64.pkg.tar.zst', 'baocode'),
        isFalse,
      );
      expect(
        isPackageAssetOf('baocode-nightly-1-x86_64.pkg.tar.zst', 'baocode'),
        isFalse,
      );
      expect(isPackageAssetOf('baocode-.pkg.tar.zst', 'baocode'), isFalse);
      expect(
        isPackageAssetOf('other-1.9.5-1-x86_64.pkg.tar.zst', 'baocode'),
        isFalse,
      );
    });
  });

  group('pacman ownership', () {
    const executable = '/opt/baocode/baocode';

    test('reads pacman -Qo output for the executable', () {
      expect(
        parsePacmanOwnership(
          '$executable is owned by baocode 1.9.5.r17.gabc1234-1\n',
          executable,
        ),
        'baocode',
      );
      expect(
        parsePacmanOwnership(
          '$executable is owned by baocode-bin 1.9.5-1\n',
          executable,
        ),
        'baocode-bin',
      );
    });

    test('reads pacman -Qoq output', () {
      expect(parsePacmanOwnership('baocode\n', executable), 'baocode');
      expect(parsePacmanOwnership('baocode-bin\n', executable), 'baocode-bin');
    });

    test('reports no owner for another path, another package or an error', () {
      expect(
        parsePacmanOwnership(
          '/usr/bin/baocode is owned by baocode 1.9.5-1\n',
          executable,
        ),
        isNull,
      );
      expect(
        parsePacmanOwnership(
          '$executable is owned by other 1.9.5-1\n',
          executable,
        ),
        isNull,
      );
      expect(
        parsePacmanOwnership(
          'error: No package owns $executable\n',
          executable,
        ),
        isNull,
      );
      expect(parsePacmanOwnership('other\n', executable), isNull);
      expect(parsePacmanOwnership('', executable), isNull);
    });
  });

  group('pacman install', () {
    const assetPath =
        '/home/user/.local/share/baocode/updates/1.9.5/baocode-1.9.5-1-x86_64.pkg.tar.zst';

    test('builds a one-prompt pacman command', () {
      expect(pacmanInstallCommand(assetPath), [
        'pkexec',
        'pacman',
        '-U',
        '--noconfirm',
        assetPath,
      ]);
    });

    test('uses the pkexec the installer resolved', () {
      expect(pacmanInstallCommand(assetPath, pkexec: '/usr/bin/pkexec'), [
        '/usr/bin/pkexec',
        'pacman',
        '-U',
        '--noconfirm',
        assetPath,
      ]);
    });
  });

  group('update source', () {
    const upstream = 'https://dl.baocode.dev/releases/latest.json';
    const fork =
        'https://api.github.com/repos/NmouZh/baocode-for-archlinux/releases';

    test('keeps the upstream source off Linux', () {
      expect(
        updateSourceDecision(isLinux: false, envUpdateUrl: null),
        upstream,
      );
      expect(
        updateSourceDecision(
          isLinux: false,
          envUpdateUrl: 'https://mirror.example/latest.json',
        ),
        upstream,
      );
    });

    test('uses the fork releases on Linux', () {
      expect(updateSourceDecision(isLinux: true, envUpdateUrl: null), fork);
      expect(updateSourceDecision(isLinux: true, envUpdateUrl: ''), fork);
      expect(updateSourceDecision(isLinux: true, envUpdateUrl: '   '), fork);
    });

    test('lets an explicit URL win on Linux', () {
      expect(
        updateSourceDecision(
          isLinux: true,
          envUpdateUrl: 'https://mirror.example/latest.json',
        ),
        'https://mirror.example/latest.json',
      );
    });
  });

  group('proxy candidates', () {
    test('tries the direct URL first, then gh-proxy', () {
      final direct = Uri.parse(
        'https://api.github.com/repos/NmouZh/baocode-for-archlinux/releases',
      );
      expect(proxyCandidates(direct), [
        direct,
        Uri.parse(
          'https://gh-proxy.com/https://api.github.com/repos/NmouZh/baocode-for-archlinux/releases',
        ),
      ]);
    });
  });
}
