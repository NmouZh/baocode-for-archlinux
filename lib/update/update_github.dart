// The Linux update backend: the fork's GitHub Releases, fetched directly
// or through gh-proxy.com. Plain decisions about which release and asset
// live in arch_release.dart; this file is the I/O around them.
//
// The fork has no upstream Ed25519 key, so a released package is trusted
// by its GitHub `digest` (SHA-256) and size instead. The manifest text this
// backend writes keeps direct github.com links: the proxy is a fallback in
// the downloader, never something the manifest has to allow.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'arch_release.dart';
import 'update_manifest.dart';
import 'update_service.dart';
import 'version.dart';

/// The fork's releases list, twenty at a time.
final githubReleasesApiUrl = Uri.parse('$forkReleasesUrl?per_page=20');

/// [direct] fetched through gh-proxy.com, for networks that cannot reach
/// GitHub itself.
Uri githubProxyUrl(Uri direct) => proxyCandidates(direct).last;

/// The GitHub source could not give a usable release, or the network gave
/// neither the direct nor the proxied copy.
class GitHubUpdateException implements Exception {
  const GitHubUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Linux updates from the fork's GitHub Releases.
///
/// [fetchManifest] reads the releases list and synthesizes the manifest
/// shape the rest of the updater already reads: the highest stable release,
/// the package installed by pacman ([packageName]), and this machine's
/// [arch]. [download] fetches the chosen asset, directly then through
/// [proxyUrl], and checks its size and SHA-256 digest.
class GitHubUpdateBackend
    implements UpdateBackend, UpdateManifestPolicyProvider {
  GitHubUpdateBackend({
    required this.directory,
    required this.packageName,
    String? arch,
    AppVersion? currentVersion,
    this.installedVersion,
    Uri? releasesApiUrl,
    Uri Function(Uri direct)? proxyUrl,
    HttpClient Function()? client,
    this.userAgent = 'BaoCode',
    this.timeout = const Duration(seconds: 30),
  }) : arch = arch ?? _currentArch,
       currentVersion = currentVersion ?? currentAppVersion,
       releasesApiUrl = releasesApiUrl ?? githubReleasesApiUrl,
       proxyUrl = proxyUrl ?? githubProxyUrl,
       _client = client ?? HttpClient.new;

  /// `updates/` in the data folder.
  final String directory;

  /// The package pacman installed the app from: `baocode` or `baocode-bin`;
  /// null when neither does. Wired to pacman's ownership query elsewhere.
  final Future<String?> Function() packageName;

  /// The version running. A package rebuilt under the same marketing version
  /// is made newer than it: its pkgrel does not move the app's own version.
  final AppVersion currentVersion;

  /// The version (`pkgver-pkgrel`) pacman has for a package, or null when it
  /// does not know it. Wired to `pacman -Q` elsewhere.
  final Future<String?> Function(String packageName)? installedVersion;

  /// `x86_64` or `aarch64`: which package build this machine updates to.
  final String arch;

  /// The releases list [fetchManifest] reads.
  final Uri releasesApiUrl;

  /// [direct]'s fallback route.
  final Uri Function(Uri direct) proxyUrl;

  final String userAgent;

  /// For connecting, and for a response that stops sending.
  final Duration timeout;

  final HttpClient Function() _client;

  /// The releases list is JSON; anything near this is not one.
  static const maxReleasesBytes = 8 << 20;

  static String get _currentArch =>
      Abi.current() == Abi.linuxArm64 ? 'aarch64' : 'x86_64';

  @override
  UpdateUrlPolicy get manifestPolicy =>
      UpdateUrlPolicy.githubReleases(extraOrigins: {releasesApiUrl.origin});

  HttpClient _newClient() => _client()
    ..connectionTimeout = timeout
    ..userAgent = userAgent;

  /// The releases list, as the manifest the updater reads.
  ///
  /// [url] is the service's manifest URL and is not used: this source is
  /// [releasesApiUrl]. An override for trying a release before publishing
  /// passes that URL to the constructor.
  @override
  Future<String> fetchManifest(Uri url) async {
    // Decoding inside the fallback: a proxy copy may be intact where the
    // direct one is not. Everything after it is a semantic failure of the
    // same content, which the proxy cannot change.
    final Object? json = await _withFallback(releasesApiUrl, (candidate) async {
      final text = await _getText(candidate);
      try {
        return jsonDecode(text);
      } on FormatException catch (error) {
        throw _UnusableResponse(
          'The releases list is not JSON (${error.message})',
        );
      }
    });
    final latest = selectLatestRelease(parseGitHubReleases(json));
    if (latest == null) {
      throw const GitHubUpdateException('No stable release found');
    }
    final owner = await packageName();
    // Not a pacman install: offer the binary package anyway, so the install
    // attempt reaches the installer's manual-update fallback instead of
    // failing the check with no way to download.
    final pkgname = owner ?? 'baocode-bin';
    if (pkgname != 'baocode' && pkgname != 'baocode-bin') {
      throw GitHubUpdateException('Unsupported package "$pkgname"');
    }
    final machineArch = archFromMachine(arch);
    if (machineArch == null) {
      throw GitHubUpdateException('No package is built for "$arch"');
    }
    final asset = selectPackageAsset(latest, pkgname, machineArch);
    if (asset == null) {
      throw GitHubUpdateException(
        '${latest.tag} has no $pkgname package for $machineArch',
      );
    }
    if (asset.size <= 0) {
      throw GitHubUpdateException('${asset.name} is empty');
    }
    final package = archPackageVersionOf(asset.name, pkgname, machineArch);
    if (package == null) {
      throw GitHubUpdateException('${asset.name} has no package version');
    }
    final tagVersion = AppVersion.tryParse(latest.tag);
    if (tagVersion == null) {
      throw GitHubUpdateException('${latest.tag} is not a version');
    }
    // A rebuild keeps the marketing version and moves pkgrel; compare the
    // package versions so it is still an update. Without pacman's answer
    // (not installed by a package), offer it as before.
    final installed = await installedVersion?.call(pkgname);
    final newer =
        installed == null || compareArchVersions(package.text, installed) > 0;
    // The manifest's version is what UpdateService compares with the app's.
    // A rebuild's marketing version is already the running one, so its
    // pkgrel moves the build number past the app's.
    final version = newer
        ? AppVersion(
            tagVersion.major,
            tagVersion.minor,
            tagVersion.patch,
            preRelease: tagVersion.preRelease,
            build: currentVersion.build + package.pkgrel,
          )
        : tagVersion;
    final sha256 = _digestHex(asset.digest);
    final platform = switch (machineArch) {
      'x86_64' => 'linux-x64',
      'aarch64' => 'linux-arm64',
      _ => throw GitHubUpdateException('No update platform for "$machineArch"'),
    };
    return jsonEncode({
      'version': '$version',
      if (latest.body.trim().isNotEmpty) 'notes': {'en': latest.body},
      'platforms': {
        platform: {
          'url': asset.downloadUrl,
          'size': asset.size,
          'sha256': sha256,
        },
      },
    });
  }

  /// `sha256:<hex>`, the prefix case-insensitively, as GitHub writes it.
  static final _sha256Digest = RegExp(
    r'^sha256:([0-9a-f]{64})$',
    caseSensitive: false,
  );

  static String _digestHex(String? digest) {
    final match = _sha256Digest.firstMatch(digest?.trim() ?? '');
    if (match == null) {
      throw const GitHubUpdateException(
        'The package has no usable SHA-256 digest',
      );
    }
    return match.group(1)!.toLowerCase();
  }

  /// [version]'s folder.
  String versionDirectory(AppVersion version) => p.join(directory, '$version');

  /// Where [release] is downloaded to.
  String fileOf(UpdateRelease release) {
    final name = release.asset.fileName;
    return p.join(
      versionDirectory(release.version),
      name == '.' || name == '..' ? 'update' : name,
    );
  }

  @override
  Future<String> download(
    UpdateRelease release, {
    void Function(int received, int total)? onProgress,
  }) async {
    final target = File(fileOf(release));
    // Only the newest is kept.
    await _removeVersions(
      (name) => name != p.basename(versionDirectory(release.version)),
    );
    await target.parent.create(recursive: true);
    if (await target.exists()) {
      // Downloaded before, and not installed yet.
      if (await _verify(target, release) == null) return target.path;
      await target.delete();
    }
    final part = File('${target.path}.part');
    await _deleteQuietly(part);
    // Verification inside the fallback: corrupted bytes from one route may
    // be intact through the other. The part file is rewritten for each
    // candidate; the last verification problem is the one reported.
    String? lastProblem;
    try {
      await _withFallback(release.asset.url, (candidate) async {
        await _deleteQuietly(part);
        try {
          await _fetch(candidate, part, release.asset.size, onProgress);
        } on _VerificationFailure catch (error) {
          lastProblem = error.problem;
          rethrow;
        }
        final problem = await _verify(part, release);
        if (problem == null) return;
        lastProblem = problem;
        await _deleteQuietly(part);
        throw _VerificationFailure(problem);
      });
    } on Object {
      await _deleteQuietly(part);
      final problem = lastProblem;
      if (problem != null) throw UpdateVerificationException(problem);
      rethrow;
    }
    await part.rename(target.path);
    return target.path;
  }

  /// Why [file] is not [release]'s download; null when it is.
  Future<String?> _verify(File file, UpdateRelease release) async {
    final asset = release.asset;
    final size = await file.length();
    if (size != asset.size) {
      return 'The download is $size bytes, not ${asset.size}';
    }
    final digest = await crypto.sha256.bind(file.openRead()).first;
    if ('$digest' != asset.sha256.toLowerCase()) {
      return 'The download does not match its SHA-256';
    }
    return null;
  }

  /// [direct], then its [proxyUrl]. A 4xx means the release itself is
  /// wrong, not the route, and is not retried; network errors and 5xx are.
  Future<T> _withFallback<T>(
    Uri direct,
    Future<T> Function(Uri url) attempt,
  ) async {
    final candidates = <Uri>[direct];
    final proxied = proxyUrl(direct);
    if (proxied != direct) candidates.add(proxied);
    Object? last;
    for (final candidate in candidates) {
      try {
        return await attempt(candidate);
      } on _HttpStatusException catch (error) {
        if (error.statusCode < 500) {
          throw GitHubUpdateException(
            'HTTP ${error.statusCode} from ${error.uri}',
          );
        }
        last = error;
      } on Object catch (error) {
        if (!_retryable(error)) rethrow;
        last = error;
      }
    }
    throw last is _UnusableResponse
        ? GitHubUpdateException(last.message)
        : GitHubUpdateException('GitHub could not be reached: $last');
  }

  static bool _retryable(Object error) =>
      error is IOException ||
      error is TimeoutException ||
      error is _UnusableResponse ||
      error is _VerificationFailure;

  /// The releases list's text at [url].
  Future<String> _getText(Uri url) async {
    final client = _newClient();
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw _HttpStatusException(response.statusCode, url);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > maxReleasesBytes) {
          throw HttpException('The releases list is too large', uri: url);
        }
      }
      return utf8.decode(bytes.takeBytes());
    } finally {
      client.close(force: true);
    }
  }

  /// Fetches [url] into [part], overwriting what an earlier route wrote.
  Future<void> _fetch(
    Uri url,
    File part,
    int total,
    void Function(int received, int total)? onProgress,
  ) async {
    final client = _newClient();
    try {
      final request = await client.getUrl(url).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw _HttpStatusException(response.statusCode, url);
      }
      final sink = part.openWrite(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response.timeout(timeout)) {
          received += chunk.length;
          if (received > total) {
            throw const _VerificationFailure(
              'The download is larger than it should be',
            );
          }
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
    } on _VerificationFailure {
      await _deleteQuietly(part);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> cleanUp(AppVersion current) => _removeVersions((name) {
    final version = AppVersion.tryParse(name);
    return version == null || version <= current;
  });

  /// Removes the version folders whose name [remove] picks.
  Future<void> _removeVersions(bool Function(String name) remove) async {
    final root = Directory(directory);
    if (!await root.exists()) return;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory || !remove(p.basename(entry.path))) continue;
      try {
        await entry.delete(recursive: true);
      } on FileSystemException {
        // In use (an installer still running): next time.
      }
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Gone already.
    }
  }
}

class _HttpStatusException implements Exception {
  _HttpStatusException(this.statusCode, this.uri);

  final int statusCode;
  final Uri uri;

  @override
  String toString() => 'HTTP $statusCode from $uri';
}

/// The releases list's body did not decode as JSON. Another route may have
/// an intact copy, so the fallback treats it as retryable.
class _UnusableResponse implements Exception {
  const _UnusableResponse(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The bytes a route served did not verify (size, digest, or too much
/// data). Another route may serve intact bytes, so the fallback retries.
class _VerificationFailure implements Exception {
  const _VerificationFailure(this.problem);

  final String problem;

  @override
  String toString() => problem;
}
