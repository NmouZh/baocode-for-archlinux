import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:baocode/update/arch_release.dart' show forkReleasesUrl;
import 'package:baocode/update/installer_io.dart';
import 'package:baocode/update/update_github.dart';
import 'package:baocode/update/update_manifest.dart';
import 'package:baocode/update/update_service.dart';
import 'package:baocode/update/update_settings.dart';
import 'package:baocode/update/version.dart';

import 'update_fakes.dart';

/// A local server in place of the GitHub API and its asset hosts: what it
/// serves by path, which statuses it refuses with, and what it was asked.
class _Server {
  _Server._(this._server) {
    _server.listen(_handle);
  }

  static Future<_Server> start() async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, Uint8List> files = {};
  final Map<String, int> statuses = {};
  final List<String> requests = [];

  String get base => 'http://127.0.0.1:${_server.port}';

  Uri url(String path) => Uri.parse('$base/$path');

  /// [direct] as the gh-proxy.com would fetch it, on this server.
  Uri proxyUrl(Uri direct) => url('proxy/$direct');

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path.substring(1);
    requests.add(path);
    final response = request.response;
    if (statuses[path] case final status?) {
      response.statusCode = status;
      await response.close();
      return;
    }
    if (files[path] case final file?) {
      response.contentLength = file.length;
      response.add(file);
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// Makes real HTTP requests, which the test binding would otherwise answer
/// with 400.
class _RealHttp extends HttpOverrides {}

/// Runs nothing: pacman owns no package, and no process is started.
class _NoPacman implements UpdateProcesses {
  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async =>
      ProcessResult(0, 1, '', 'error: No package owns ${arguments.last}');

  @override
  Future<void> startDetached(String executable, List<String> arguments) async {}
}

String _route(Uri url) => url.path.substring(1);

Map<String, Object?> _assetJson({
  required Uri url,
  required String name,
  required int size,
  String? digest,
}) => {
  'name': name,
  'browser_download_url': '$url',
  'size': size,
  'digest': ?digest,
};

Map<String, Object?> _releaseJson({
  required String tag,
  List<Map<String, Object?>> assets = const [],
  bool draft = false,
  bool prerelease = false,
  String body = '',
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'body': body,
  'assets': assets,
};

void main() {
  late _Server server;
  late Directory directory;
  late GitHubUpdateBackend backend;

  final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 251));
  String shaOf(List<int> data) => '${crypto.sha256.convert(data)}';

  Map<String, Object?> assetOf({
    String name = 'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
    String? path,
    int? size,
    String? digest,
  }) => _assetJson(
    url: server.url(path ?? name),
    name: name,
    size: size ?? bytes.length,
    digest: digest ?? 'sha256:${shaOf(bytes)}',
  );

  GitHubUpdateBackend backendFor({
    String? packageName = 'baocode-bin',
    String arch = 'x86_64',
  }) => GitHubUpdateBackend(
    directory: directory.path,
    packageName: () async => packageName,
    arch: arch,
    releasesApiUrl: server.url('releases'),
    proxyUrl: server.proxyUrl,
    timeout: const Duration(seconds: 5),
  );

  void serveReleases(List<Map<String, Object?>> releases) {
    server.files[_route(server.url('releases'))] = Uint8List.fromList(
      utf8.encode(jsonEncode(releases)),
    );
  }

  Future<UpdateManifest> fetch([GitHubUpdateBackend? from]) async {
    final source = from ?? backend;
    final text = await source.fetchManifest(Uri.parse(forkReleasesUrl));
    return UpdateManifest.parse(text, policy: source.manifestPolicy);
  }

  setUp(() async {
    HttpOverrides.global = _RealHttp();
    server = await _Server.start();
    directory = await Directory.systemTemp.createTemp('baocode-updates');
    backend = backendFor();
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close();
    await directory.delete(recursive: true);
  });

  group('GitHubUpdateBackend.fetchManifest', () {
    test('builds the latest release as an unsigned manifest', () async {
      serveReleases([
        _releaseJson(
          tag: 'v1.9.4',
          assets: [
            assetOf(
              name: 'baocode-bin-1.9.4-1-x86_64.pkg.tar.zst',
              path: 'old.pkg.tar.zst',
            ),
          ],
        ),
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);

      final text = await backend.fetchManifest(Uri.parse(forkReleasesUrl));
      final manifest = UpdateManifest.parse(
        text,
        policy: backend.manifestPolicy,
      );
      expect(manifest.version, AppVersion.parse('1.9.5'));
      expect(manifest.platforms, ['linux-x64']);
      final asset = manifest.assetFor('linux-x64')!;
      expect(
        '${asset.url}',
        '${server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst')}',
      );
      expect(asset.size, bytes.length);
      expect(asset.sha256, shaOf(bytes));
      expect(asset.signature, isNull);

      // The upstream policy would not take this source's manifest.
      expect(
        () => UpdateManifest.parse(text).assetFor('linux-x64'),
        throwsA(isA<UpdateManifestException>()),
      );
    });

    test('takes the highest stable version, not the latest marker', () async {
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
        _releaseJson(tag: 'v1.10.0', assets: [assetOf()]),
        _releaseJson(tag: 'v9.0.0', assets: [assetOf()], prerelease: true),
        _releaseJson(tag: 'v10.0.0', assets: [assetOf()], draft: true),
        _releaseJson(tag: 'nightly', assets: [assetOf()]),
      ]);
      expect((await fetch()).version, AppVersion.parse('1.10.0'));
    });

    test('a direct 5xx is retried through gh-proxy.com', () async {
      final direct = server.url('releases');
      final proxied = server.proxyUrl(direct);
      server.statuses[_route(direct)] = HttpStatus.serviceUnavailable;
      server.files[_route(proxied)] = Uint8List.fromList(
        utf8.encode(
          jsonEncode([
            _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
          ]),
        ),
      );

      expect((await fetch()).version, AppVersion.parse('1.9.5'));
      expect(server.requests, [_route(direct), _route(proxied)]);
    });

    test('a direct non-JSON answer is retried through gh-proxy.com', () async {
      final direct = server.url('releases');
      final proxied = server.proxyUrl(direct);
      server.files[_route(direct)] = Uint8List.fromList(
        utf8.encode('not a releases list'),
      );
      server.files[_route(proxied)] = Uint8List.fromList(
        utf8.encode(
          jsonEncode([
            _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
          ]),
        ),
      );

      expect((await fetch()).version, AppVersion.parse('1.9.5'));
      expect(server.requests, [_route(direct), _route(proxied)]);
    });

    test('a direct 4xx is not retried', () async {
      final direct = server.url('releases');
      server.statuses[_route(direct)] = HttpStatus.forbidden;

      await expectLater(
        backend.fetchManifest(Uri.parse(forkReleasesUrl)),
        throwsA(isA<GitHubUpdateException>()),
      );
      expect(server.requests, [_route(direct)]);
    });

    test('both routes failing is a failed fetch', () async {
      final direct = server.url('releases');
      server.statuses[_route(direct)] = HttpStatus.internalServerError;
      server.statuses[_route(server.proxyUrl(direct))] = HttpStatus.badGateway;

      await expectLater(
        backend.fetchManifest(Uri.parse(forkReleasesUrl)),
        throwsA(isA<GitHubUpdateException>()),
      );
      expect(server.requests, hasLength(2));
    });

    test('selects the package and architecture installed', () async {
      final assets = [
        assetOf(
          name: 'baocode-1.9.5-1-x86_64.pkg.tar.zst',
          path: 'source-x64.pkg.tar.zst',
        ),
        assetOf(
          name: 'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
          path: 'bin-x64.pkg.tar.zst',
        ),
        assetOf(
          name: 'baocode-1.9.5-1-aarch64.pkg.tar.zst',
          path: 'source-arm.pkg.tar.zst',
        ),
        assetOf(
          name: 'baocode-bin-1.9.5-1-aarch64.pkg.tar.zst',
          path: 'bin-arm.pkg.tar.zst',
        ),
      ];
      serveReleases([_releaseJson(tag: 'v1.9.5', assets: assets)]);

      final bin = await fetch();
      expect(bin.platforms, ['linux-x64']);
      expect(bin.assetFor('linux-x64')!.url, server.url('bin-x64.pkg.tar.zst'));

      final source = await fetch(
        backendFor(packageName: 'baocode', arch: 'aarch64'),
      );
      expect(source.platforms, ['linux-arm64']);
      expect(
        source.assetFor('linux-arm64')!.url,
        server.url('source-arm.pkg.tar.zst'),
      );
    });

    test('a non-pacman install is offered the binary package', () async {
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);
      final manifest = await fetch(backendFor(packageName: null));
      expect(manifest.version, AppVersion.parse('1.9.5'));
      expect(manifest.platforms, ['linux-x64']);
      expect(
        manifest.assetFor('linux-x64')!.url,
        server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'),
      );
    });

    test('the other package is not taken for the installed one', () async {
      serveReleases([
        _releaseJson(
          tag: 'v1.9.5',
          assets: [
            assetOf(
              name: 'baocode-1.9.5-1-x86_64.pkg.tar.zst',
              path: 'source.pkg.tar.zst',
            ),
          ],
        ),
      ]);
      await expectLater(fetch(), throwsA(isA<GitHubUpdateException>()));
    });

    test('a release with no digest for the asset is refused', () async {
      serveReleases([
        _releaseJson(
          tag: 'v1.9.5',
          assets: [assetOf(digest: '')],
        ),
      ]);
      await expectLater(fetch(), throwsA(isA<GitHubUpdateException>()));
    });

    test('the digest prefix and hex are read case-insensitively', () async {
      serveReleases([
        _releaseJson(
          tag: 'v1.9.5',
          assets: [assetOf(digest: 'SHA256:${shaOf(bytes).toUpperCase()}')],
        ),
      ]);
      expect((await fetch()).assetFor('linux-x64')!.sha256, shaOf(bytes));
    });
  });

  group('UpdateManifest signature policy', () {
    Map<String, Object?> manifestWithoutSignature({String? signature}) => {
      'version': '1.2.0',
      'platforms': {
        'windows-x64': {
          'url': 'https://baocode.dev/releases/x.exe',
          'size': 100,
          'sha256': 'a' * 64,
          'signature': ?signature,
        },
      },
    };

    test('the upstream source still requires the signature', () {
      expect(
        () =>
            UpdateManifest.parse(jsonEncode(manifestWithoutSignature()))
                .assetFor('windows-x64'),
        throwsA(
          isA<UpdateManifestException>().having(
            (e) => e.message,
            'message',
            contains('signature'),
          ),
        ),
      );
    });

    test('the GitHub source may leave the signature out', () {
      final manifest = UpdateManifest.parse(
        jsonEncode(manifestWithoutSignature()),
        policy: UpdateUrlPolicy.githubReleases(),
      );
      expect(manifest.assetFor('windows-x64')!.signature, isNull);
    });

    test('a signature that is there but wrong is still refused', () {
      expect(
        () => UpdateManifest.parse(
          jsonEncode(
            manifestWithoutSignature(signature: base64.encode([1, 2, 3])),
          ),
          policy: UpdateUrlPolicy.githubReleases(),
        ).assetFor('windows-x64'),
        throwsA(
          isA<UpdateManifestException>().having(
            (e) => e.message,
            'message',
            contains('signature'),
          ),
        ),
      );
    });

    test('GitHub download links pass only under the GitHub policy', () {
      final url = Uri.parse(
        'https://github.com/NmouZh/baocode-for-archlinux/releases/download/'
        'v1.9.5/baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
      );
      expect(UpdateUrlPolicy.githubReleases().allows(url), isTrue);
      expect(const UpdateUrlPolicy().allows(url), isFalse);
    });
  });

  group('GitHubUpdateBackend.download', () {
    Future<UpdateRelease> downloadedRelease() async {
      final manifest = await fetch();
      final platform = manifest.platforms.first;
      return UpdateRelease(
        manifest: manifest,
        platform: platform,
        asset: manifest.assetFor(platform)!,
      );
    }

    List<String> files() => [
      for (final entity in directory.listSync(recursive: true))
        if (entity is File) p.relative(entity.path, from: directory.path),
    ]..sort();

    test('downloads the asset and checks its size and digest', () async {
      server.files['baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'] = bytes;
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);

      final progress = <int>[];
      final path = await backend.download(
        await downloadedRelease(),
        onProgress: (received, total) {
          expect(total, bytes.length);
          progress.add(received);
        },
      );
      expect(
        path,
        p.join(
          directory.path,
          '1.9.5',
          'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst',
        ),
      );
      expect(await File(path).readAsBytes(), bytes);
      expect(progress.last, bytes.length);
      expect(files(), [
        p.join('1.9.5', 'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'),
      ]);
    });

    test('a direct 5xx is retried through gh-proxy.com', () async {
      server.files['baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'] = bytes;
      server.files[_route(
            server.proxyUrl(
              server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'),
            ),
          )] =
          bytes;
      server.statuses[_route(
            server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'),
          )] =
          HttpStatus.internalServerError;
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);
      final release = await downloadedRelease();
      server.requests.clear();

      final path = await backend.download(release);
      expect(await File(path).readAsBytes(), bytes);
      expect(server.requests, [
        _route(server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst')),
        _route(
          server.proxyUrl(server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst')),
        ),
      ]);
    });

    test('a direct download that does not verify is retried through '
        'gh-proxy.com', () async {
      final name = 'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst';
      final direct = server.url(name);
      final proxied = server.proxyUrl(direct);
      final corrupted = Uint8List.fromList([
        for (final byte in bytes) byte ^ 0xff,
      ]);
      server.files[_route(direct)] = corrupted;
      server.files[_route(proxied)] = bytes;
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);
      final release = await downloadedRelease();
      server.requests.clear();

      final progress = <int>[];
      final path = await backend.download(
        release,
        onProgress: (received, total) => progress.add(received),
      );
      expect(await File(path).readAsBytes(), bytes);
      expect(progress.last, bytes.length);
      expect(server.requests, [_route(direct), _route(proxied)]);
      expect(files(), [p.join('1.9.5', name)]);
    });

    test('both download routes corrupted is a verification failure', () async {
      final name = 'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst';
      final direct = server.url(name);
      final corrupted = Uint8List.fromList([
        for (final byte in bytes) byte ^ 0xff,
      ]);
      server.files[_route(direct)] = corrupted;
      server.files[_route(server.proxyUrl(direct))] = corrupted;
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);
      final release = await downloadedRelease();
      server.requests.clear();

      await expectLater(
        backend.download(release),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(server.requests, [
        _route(direct),
        _route(server.proxyUrl(direct)),
      ]);
      expect(files(), isEmpty, reason: 'the bad downloads are gone');
    });

    test('both download routes failing is an error', () async {
      server.statuses[_route(
            server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'),
          )] =
          HttpStatus.internalServerError;
      server.statuses[_route(
        server.proxyUrl(server.url('baocode-bin-1.9.5-1-x86_64.pkg.tar.zst')),
      )] = HttpStatus
          .badGateway;
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);
      final release = await downloadedRelease();

      await expectLater(
        backend.download(release),
        throwsA(isA<GitHubUpdateException>()),
      );
      expect(files(), isEmpty);
    });

    test('a download whose digest is not the asset\'s is refused', () async {
      server.files['baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'] = bytes;
      serveReleases([
        _releaseJson(
          tag: 'v1.9.5',
          assets: [
            assetOf(digest: 'sha256:${shaOf([1, 2, 3])}'),
          ],
        ),
      ]);
      await expectLater(
        backend.download(await downloadedRelease()),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(files(), isEmpty, reason: 'the bad download is gone');
    });

    test('a download smaller than the asset is refused', () async {
      server.files['baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'] = bytes;
      serveReleases([
        _releaseJson(
          tag: 'v1.9.5',
          assets: [assetOf(size: bytes.length + 10)],
        ),
      ]);
      await expectLater(
        backend.download(await downloadedRelease()),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.message,
            'message',
            contains('not ${bytes.length + 10}'),
          ),
        ),
      );
      expect(files(), isEmpty);
    });

    test('a download larger than the asset is refused', () async {
      server.files['baocode-bin-1.9.5-1-x86_64.pkg.tar.zst'] = bytes;
      serveReleases([
        _releaseJson(
          tag: 'v1.9.5',
          assets: [assetOf(size: bytes.length - 10)],
        ),
      ]);
      await expectLater(
        backend.download(await downloadedRelease()),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.message,
            'message',
            contains('larger'),
          ),
        ),
      );
      expect(files(), isEmpty);
    });

    test('cleans up what is installed by now', () async {
      for (final name in ['1.0.0', '1.9.5', 'junk']) {
        await File(p.join(directory.path, name, 'x')).create(recursive: true);
      }
      await backend.cleanUp(AppVersion.parse('1.0.0'));
      expect(files(), [p.join('1.9.5', 'x')]);
    });
  });

  group('UpdateService with the GitHub source', () {
    UpdateService serviceWith(UpdateBackend source, String platform) =>
        UpdateService(
          current: AppVersion.parse('1.9.4'),
          platform: platform,
          manifestUrl: Uri.parse(forkReleasesUrl),
          backend: source,
          installer: FakeInstaller(),
          mode: () => UpdateMode.manual,
          store: MemoryUpdateStore(),
        );

    test('a check takes the GitHub manifest without a signature', () async {
      serveReleases([
        _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
      ]);
      final service = serviceWith(backend, 'linux-x64');

      final result = await service.check(manual: true);
      expect(result, isA<UpdateFound>());
      final offer = (result as UpdateFound).offer;
      expect(offer.release.version, AppVersion.parse('1.9.5'));
      expect(offer.release.platform, 'linux-x64');
      expect(service.status, UpdateStatus.available);
    });

    test(
      'a non-pacman install is offered, then sent to the fork releases',
      () async {
        final name = 'baocode-bin-1.9.5-1-x86_64.pkg.tar.zst';
        server.files[name] = bytes;
        serveReleases([
          _releaseJson(tag: 'v1.9.5', assets: [assetOf()]),
        ]);
        final service = UpdateService(
          current: AppVersion.parse('1.9.4'),
          platform: 'linux-x64',
          manifestUrl: Uri.parse(forkReleasesUrl),
          backend: backendFor(packageName: null),
          installer: LinuxUpdateInstaller(
            executable: '/opt/baocode/baocode',
            pid: 1,
            updatesDirectory: directory.path,
            processes: _NoPacman(),
            pkexec: '/no/pkexec',
          ),
          mode: () => UpdateMode.manual,
          store: MemoryUpdateStore(),
        );

        final result = await service.check(manual: true);
        expect(result, isA<UpdateFound>());
        expect(
          (result as UpdateFound).offer.release.asset.fileName,
          name,
          reason: 'the binary package is offered when pacman owns nothing',
        );
        await expectLater(
          service.prepare(),
          throwsA(
            isA<ManualUpdateRequired>().having(
              (e) => e.downloadPage,
              'page',
              Uri.parse(
                'https://github.com/NmouZh/baocode-for-archlinux/releases',
              ),
            ),
          ),
        );
      },
    );

    test('a check still refuses an unsigned upstream manifest', () async {
      final unsigned = jsonEncode({
        'version': '2.0.0',
        'platforms': {
          'windows-x64': {
            'url': 'https://baocode.dev/releases/x.exe',
            'size': 100,
            'sha256': 'a' * 64,
          },
        },
      });
      final service = serviceWith(FakeBackend(unsigned), 'windows-x64');

      final result = await service.check(manual: true);
      expect(result, isA<UpdateCheckFailed>());
      expect(
        (result as UpdateCheckFailed).error,
        isA<UpdateManifestException>(),
      );
    });
  });
}
