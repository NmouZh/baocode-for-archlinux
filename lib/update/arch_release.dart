// Plain Dart, no Flutter and no I/O: the Arch update policy is a set of
// pure decisions, tested directly.
//
// The app's [AppVersion] reads pubspec-style versions and deliberately
// rejects Arch pkgver (`1.9.5.r17.gabc1234`). Release tags mirrored by the
// fork are marketing semver (`v1.9.5`), so selection parses those here,
// independently of pkgver parsing.

import 'update_manifest.dart';

/// Where the fork's mirrored releases are listed, as a GitHub releases API
/// list. Linux updates come from here instead of the upstream manifest.
const forkReleasesUrl =
    'https://api.github.com/repos/NmouZh/baocode-for-archlinux/releases';

/// A file attached to a GitHub release.
class GitHubReleaseAsset {
  const GitHubReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.digest,
  });

  /// The asset's file name, e.g.
  /// `baocode-bin-1.9.5-1-x86_64.pkg.tar.zst`.
  final String name;

  /// GitHub's `browser_download_url`.
  final String downloadUrl;

  /// The file's size in bytes.
  final int size;

  /// GitHub's `digest` (e.g. `sha256:<hex>`), when the API provides one.
  final String? digest;
}

/// A GitHub release, as the fork mirrors upstream ones.
class GitHubRelease {
  const GitHubRelease({
    required this.tag,
    required this.assets,
    this.draft = false,
    this.prerelease = false,
    this.body = '',
  });

  /// The release's `tag_name`, e.g. `v1.9.5`.
  final String tag;
  final bool draft;
  final bool prerelease;
  final String body;
  final List<GitHubReleaseAsset> assets;
}

/// The releases in a decoded GitHub `releases` API response, in their
/// original order. Entries that are not a release, and assets that are not
/// a usable download, are left out.
List<GitHubRelease> parseGitHubReleases(Object? json) {
  if (json is! List) return const [];
  final releases = <GitHubRelease>[];
  for (final entry in json) {
    final release = _parseRelease(entry);
    if (release != null) releases.add(release);
  }
  return releases;
}

GitHubRelease? _parseRelease(Object? json) {
  if (json is! Map) return null;
  final tag = json['tag_name'];
  if (tag is! String || tag.trim().isEmpty) return null;
  return GitHubRelease(
    tag: tag,
    draft: json['draft'] == true,
    prerelease: json['prerelease'] == true,
    body: json['body'] is String ? json['body'] as String : '',
    assets: _parseAssets(json['assets']),
  );
}

List<GitHubReleaseAsset> _parseAssets(Object? json) {
  if (json is! List) return const [];
  final assets = <GitHubReleaseAsset>[];
  for (final entry in json) {
    if (entry is! Map) continue;
    final name = entry['name'];
    final url = entry['browser_download_url'];
    final size = entry['size'];
    if (name is! String || name.isEmpty) continue;
    if (url is! String || url.isEmpty) continue;
    if (size is! int || size < 0) continue;
    final digest = entry['digest'];
    assets.add(
      GitHubReleaseAsset(
        name: name,
        downloadUrl: url,
        size: size,
        digest: digest is String && digest.isNotEmpty ? digest : null,
      ),
    );
  }
  return assets;
}

/// The newest non-draft, non-pre-release release by marketing semver, or
/// null when there is none. The GitHub `latest` marker is not consulted; a
/// fork release created for an older version must not become the update.
GitHubRelease? selectLatestRelease(List<GitHubRelease> releases) {
  GitHubRelease? latest;
  _SemVersion? latestVersion;
  for (final release in releases) {
    if (release.draft || release.prerelease) continue;
    final version = _SemVersion.tryParse(release.tag);
    if (version == null) continue;
    if (latestVersion == null || version.compareTo(latestVersion) > 0) {
      latest = release;
      latestVersion = version;
    }
  }
  return latest;
}

/// The Arch architecture named by [machine] (for example `uname -m` or
/// Dart's `Abi` name), or null when it is not one the fork builds for.
String? archFromMachine(String machine) {
  switch (machine.trim().toLowerCase()) {
    case 'x86_64':
    case 'amd64':
      return 'x86_64';
    case 'aarch64':
    case 'arm64':
      return 'aarch64';
    default:
      return null;
  }
}

/// Whether [fileName] is a package built from [pkgname].
///
/// Arch names packages `<pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst`.
/// The prefix match is exact: `baocode-bin-...` is not an asset of
/// `baocode`. pkgver starts with a digit, so requiring that after the
/// prefix keeps a longer package name from passing as a shorter one.
bool isPackageAssetOf(String fileName, String pkgname) {
  const suffix = '.pkg.tar.zst';
  final prefix = '$pkgname-';
  if (!fileName.startsWith(prefix) || !fileName.endsWith(suffix)) {
    return false;
  }
  final remainder = fileName.substring(
    prefix.length,
    fileName.length - suffix.length,
  );
  return RegExp(r'^\d').hasMatch(remainder);
}

/// A package's Arch version: its pkgver and numeric pkgrel.
class ArchPackageVersion {
  const ArchPackageVersion({required this.pkgver, required this.pkgrel});

  /// `1.9.6.r122.g9c5d062`.
  final String pkgver;
  final int pkgrel;

  /// `1.9.6.r122.g9c5d062-2`, as pacman prints it.
  String get text => '$pkgver-$pkgrel';
}

/// The version an Arch package asset name carries, for [pkgname] and
/// [arch]; null when [fileName] is not such a package.
ArchPackageVersion? archPackageVersionOf(
  String fileName,
  String pkgname,
  String arch,
) {
  const extension = '.pkg.tar.zst';
  final prefix = '$pkgname-';
  final suffix = '-$arch$extension';
  if (!isPackageAssetOf(fileName, pkgname) || !fileName.endsWith(suffix)) {
    return null;
  }
  final remainder = fileName.substring(
    prefix.length,
    fileName.length - suffix.length,
  );
  final pkgrelSeparator = remainder.lastIndexOf('-');
  if (pkgrelSeparator <= 0 || pkgrelSeparator == remainder.length - 1) {
    return null;
  }
  final pkgrel = int.tryParse(remainder.substring(pkgrelSeparator + 1));
  if (pkgrel == null || pkgrel < 1) return null;
  return ArchPackageVersion(
    pkgver: remainder.substring(0, pkgrelSeparator),
    pkgrel: pkgrel,
  );
}

/// The `.pkg.tar.zst` [release] asset built from [pkgname] for [arch], or
/// null when the release has none.
GitHubReleaseAsset? selectPackageAsset(
  GitHubRelease release,
  String pkgname,
  String arch,
) {
  for (final asset in release.assets) {
    if (archPackageVersionOf(asset.name, pkgname, arch) != null) return asset;
  }
  return null;
}

/// Arch's package version comparison, as `vercmp` makes it: negative when
/// [a] is older, zero when they are equal, positive when [a] is newer.
///
/// The app's [AppVersion] cannot read Arch pkgver, and a rebuilt package
/// moves pkgrel without moving the marketing version, so updates compare
/// these here.
int compareArchVersions(String a, String b) {
  final (epochA, restA) = _splitEpoch(a);
  final (epochB, restB) = _splitEpoch(b);
  final byEpoch = epochA.compareTo(epochB);
  if (byEpoch != 0) return byEpoch.sign;
  final (verA, relA) = _splitPkgrel(restA);
  final (verB, relB) = _splitPkgrel(restB);
  final byVersion = _rpmVersionCompare(verA, verB);
  if (byVersion != 0) return byVersion;
  // vercmp compares pkgrels only when both have one.
  if (relA == null || relB == null) return 0;
  return _rpmVersionCompare(relA, relB);
}

(int, String) _splitEpoch(String version) {
  final colon = version.indexOf(':');
  if (colon > 0) {
    final epoch = int.tryParse(version.substring(0, colon));
    if (epoch != null) return (epoch, version.substring(colon + 1));
  }
  return (0, version);
}

(String, String?) _splitPkgrel(String version) {
  final dash = version.lastIndexOf('-');
  if (dash <= 0 || dash == version.length - 1) return (version, null);
  return (version.substring(0, dash), version.substring(dash + 1));
}

/// pacman's rpmvercmp: alphanumeric segments compared left to right, and
/// more separators between them newer; a trailing alpha segment older.
int _rpmVersionCompare(String a, String b) {
  if (a == b) return 0;
  var one = 0;
  var two = 0;
  while (true) {
    final separatorStartOne = one;
    final separatorStartTwo = two;
    while (one < a.length && !_isArchAlnum(a.codeUnitAt(one))) {
      one++;
    }
    while (two < b.length && !_isArchAlnum(b.codeUnitAt(two))) {
      two++;
    }
    final separatorsOne = one - separatorStartOne;
    final separatorsTwo = two - separatorStartTwo;
    if (separatorsOne != separatorsTwo) {
      return separatorsOne < separatorsTwo ? -1 : 1;
    }
    if (one >= a.length || two >= b.length) break;

    final segmentStartOne = one;
    final segmentStartTwo = two;
    final bool numeric;
    if (_isArchDigit(a.codeUnitAt(segmentStartOne))) {
      while (one < a.length && _isArchDigit(a.codeUnitAt(one))) {
        one++;
      }
      while (two < b.length && _isArchDigit(b.codeUnitAt(two))) {
        two++;
      }
      numeric = true;
    } else {
      while (one < a.length && _isArchAlpha(a.codeUnitAt(one))) {
        one++;
      }
      while (two < b.length && _isArchAlpha(b.codeUnitAt(two))) {
        two++;
      }
      numeric = false;
    }
    if (one == segmentStartOne) return -1;
    // A numeric segment is newer than an alpha one (the second segment is
    // empty when its kind differs).
    if (two == segmentStartTwo) return numeric ? 1 : -1;

    var segmentOne = a.substring(segmentStartOne, one);
    var segmentTwo = b.substring(segmentStartTwo, two);
    if (numeric) {
      segmentOne = _stripLeadingZeros(segmentOne);
      segmentTwo = _stripLeadingZeros(segmentTwo);
      if (segmentOne.length != segmentTwo.length) {
        return segmentOne.length > segmentTwo.length ? 1 : -1;
      }
    }
    final order = segmentOne.compareTo(segmentTwo);
    if (order != 0) return order < 0 ? -1 : 1;
  }

  final oneEnded = one >= a.length;
  final twoEnded = two >= b.length;
  if (oneEnded && twoEnded) return 0;
  final oneChar = oneEnded ? -1 : a.codeUnitAt(one);
  final twoChar = twoEnded ? -1 : b.codeUnitAt(two);
  // A remaining alpha segment never beats an empty string; a remaining
  // numeric one does.
  if ((oneEnded && !_isArchAlpha(twoChar)) ||
      (!oneEnded && _isArchAlpha(oneChar))) {
    return -1;
  }
  return 1;
}

String _stripLeadingZeros(String text) {
  var start = 0;
  while (start < text.length && text.codeUnitAt(start) == 0x30) {
    start++;
  }
  return start == 0 ? text : text.substring(start);
}

bool _isArchDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

bool _isArchAlpha(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7a);

bool _isArchAlnum(int codeUnit) =>
    _isArchDigit(codeUnit) || _isArchAlpha(codeUnit);

/// The package among pacman's `baocode` and `baocode-bin` that owns
/// [executablePath], or null when neither does.
///
/// [output] may be from `pacman -Qo` (a line saying the path is owned by a
/// package and version) or `pacman -Qoq` (just the package name).
String? parsePacmanOwnership(String output, String executablePath) {
  final ownedBy = RegExp(r'^(.+?) is owned by (\S+) \S+$');
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line == 'baocode' || line == 'baocode-bin') return line;
    final match = ownedBy.firstMatch(line);
    if (match == null) continue;
    if (match.group(1) != executablePath) continue;
    final pkgname = match.group(2);
    if (pkgname == 'baocode' || pkgname == 'baocode-bin') return pkgname;
  }
  return null;
}

/// The command that installs a downloaded Arch package with pacman behind
/// one privilege prompt, through [pkexec] (the installer's path to it).
List<String> pacmanInstallCommand(
  String assetPath, {
  String pkexec = 'pkexec',
}) => [pkexec, 'pacman', '-U', '--noconfirm', assetPath];

/// Where updates come from: the upstream manifest elsewhere; on Linux the
/// fork's GitHub releases, unless [envUpdateUrl] overrides it. The
/// environment override exists to try a release before it is published.
String updateSourceDecision({required bool isLinux, String? envUpdateUrl}) {
  if (!isLinux) return defaultManifestUrl;
  final override = envUpdateUrl?.trim() ?? '';
  if (override.isNotEmpty) return override;
  return forkReleasesUrl;
}

/// [direct] first, then the same URL through `gh-proxy.com` for networks
/// that cannot reach GitHub. The order is fixed: direct before proxy.
List<Uri> proxyCandidates(Uri direct) => [
  direct,
  Uri.parse('https://gh-proxy.com/$direct'),
];

/// A marketing semver tag (`v1.9.10`), which may carry a pre-release.
class _SemVersion implements Comparable<_SemVersion> {
  const _SemVersion(this.major, this.minor, this.patch, this.preRelease);

  final int major;
  final int minor;
  final int patch;
  final List<String> preRelease;

  static final _pattern = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  static _SemVersion? tryParse(String text) {
    final match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    final preRelease = match.group(4)?.split('.') ?? const <String>[];
    if (preRelease.any((part) => part.isEmpty)) return null;
    return _SemVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      preRelease,
    );
  }

  @override
  int compareTo(_SemVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    final pre = _comparePreRelease(preRelease, other.preRelease);
    return pre;
  }

  /// Semver's precedence: a release is above its pre-releases; identifiers
  /// compared in turn, numbers numerically and below words.
  static int _comparePreRelease(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return b.length.compareTo(a.length).sign;
    for (var i = 0; i < a.length && i < b.length; i++) {
      final x = int.tryParse(a[i]);
      final y = int.tryParse(b[i]);
      final order = switch ((x, y)) {
        (final x?, final y?) => x.compareTo(y),
        (_?, null) => -1,
        (null, _?) => 1,
        _ => a[i].compareTo(b[i]),
      };
      if (order != 0) return order.sign;
    }
    return a.length.compareTo(b.length).sign;
  }
}
