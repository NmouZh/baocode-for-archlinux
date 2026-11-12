// Version and PKGBUILD updates for the Arch packages. Pure Dart: the
// functions here take and return plain values, so unit tests and the
// prepare job can use them without Flutter (see tool/arch/README.md).
//
//   dart run tool/arch/bump.dart pkgver --upstream 1.9.5 --ahead 17 \
//       --short-sha abc1234
//   dart run tool/arch/bump.dart pkgrel --current 1 --force
//   dart run tool/arch/bump.dart rewrite --file packaging/baocode/PKGBUILD \
//       --pkgver 1.9.5.r17.gabc1234 --pkgrel 1 --commit abc1234 \
//       --sums sha256sums=a,b
import 'dart:convert';
import 'dart:io';

final _marketingVersion = RegExp(r'^\d+\.\d+\.\d+$');
final _shortSha = RegExp(r'^[0-9a-fA-F]{7,}$');
final _sumsName = RegExp(r'^(sha256sums(?:_[A-Za-z0-9_]+)?)$');
final _sumsLine = RegExp(r'^(sha256sums(?:_[A-Za-z0-9_]+)?)=\((.*)$');

/// The source package's `pkgver`: the upstream marketing version, followed
/// by `.r<commitsAhead>.g<shortSha>` when the built commit is past the
/// upstream release tag.
String computeSourcePkgver(
  String upstreamVersion,
  int commitsAhead,
  String shortSha,
) {
  _checkMarketingVersion(upstreamVersion);
  if (commitsAhead < 0) {
    throw ArgumentError.value(
      commitsAhead,
      'commitsAhead',
      'must not be negative',
    );
  }
  if (commitsAhead == 0) return upstreamVersion;
  if (!_shortSha.hasMatch(shortSha)) {
    throw ArgumentError.value(
      shortSha,
      'shortSha',
      'must be at least seven hexadecimal characters',
    );
  }
  return '$upstreamVersion.r$commitsAhead.g${shortSha.substring(0, 7)}';
}

/// The binary package's `pkgver`: the upstream marketing version, since it
/// ships the upstream release's own tarball.
String computeBinaryPkgver(String upstreamVersion) {
  _checkMarketingVersion(upstreamVersion);
  return upstreamVersion;
}

/// The next `pkgrel`: unchanged unless this is a forced rebuild, which
/// makes pacman see the rebuild as newer.
int nextPkgrel(int current, bool forceRebuild) {
  if (current < 1) {
    throw ArgumentError.value(current, 'current', 'must be at least one');
  }
  return forceRebuild ? current + 1 : current;
}

/// Returns [content] with the PKGBUILD lines this tool owns rewritten:
/// `pkgver=`, `pkgrel=`, `_commit=` (only when [commit] is given), and each
/// checksum array named in [sha256sums] (including `sha256sums_x86_64=`
/// style variants). Everything else, comments included, is left byte for
/// byte. Arrays keep their one-line or multi-line shape.
String rewritePkgbuild(
  String content,
  String pkgver,
  int pkgrel, {
  String? commit,
  Map<String, List<String>> sha256sums = const {},
}) {
  _checkAssignmentValue('pkgver', pkgver);
  if (pkgrel < 1) {
    throw ArgumentError.value(pkgrel, 'pkgrel', 'must be at least one');
  }
  if (commit != null) _checkAssignmentValue('commit', commit);
  for (final MapEntry(key: name, value: sums) in sha256sums.entries) {
    if (!_sumsName.hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'sha256sums',
        'must be sha256sums or sha256sums_<suffix>',
      );
    }
    for (final sum in sums) {
      if (sum.contains('\n') || sum.contains('\r')) {
        throw ArgumentError.value(sum, name, 'a checksum may not span lines');
      }
    }
  }

  final lines = content.split('\n');
  final out = <String>[];
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final eol = raw.endsWith('\r') ? '\r' : '';
    final line = eol.isEmpty ? raw : raw.substring(0, raw.length - 1);

    if (line.startsWith('pkgver=')) {
      seen.add('pkgver');
      out.add('pkgver=$pkgver$eol');
      continue;
    }
    if (line.startsWith('pkgrel=')) {
      seen.add('pkgrel');
      out.add('pkgrel=$pkgrel$eol');
      continue;
    }
    if (commit != null && line.startsWith('_commit=')) {
      seen.add('_commit');
      out.add('_commit=$commit$eol');
      continue;
    }

    final opening = _sumsLine.firstMatch(line);
    if (opening != null && sha256sums.containsKey(opening.group(1))) {
      final name = opening.group(1)!;
      seen.add(name);
      final rest = opening.group(2)!;
      final body = _bashArrayBody(sha256sums[name]!);

      final end = _closingParenthesis(rest);
      if (end != null) {
        out.add('$name=($body)${rest.substring(end + 1)}$eol');
        continue;
      }

      final close = _nextClosingLine(lines, i + 1);
      if (close == null) {
        throw FormatException('Unclosed $name=( array');
      }
      final closeEol = lines[close].endsWith('\r') ? '\r' : '';
      final closeLine = closeEol.isEmpty
          ? lines[close]
          : lines[close].substring(0, lines[close].length - 1);
      final after = closeLine.substring(closeLine.indexOf(')') + 1);
      out.add('$name=($eol');
      for (final sum in sha256sums[name]!) {
        out.add('  ${_bashQuote(sum)}$eol');
      }
      out.add(')$after$closeEol');
      i = close;
      continue;
    }

    out.add(raw);
  }

  if (!seen.contains('pkgver')) {
    throw const FormatException('No pkgver= line at the start of a line');
  }
  if (!seen.contains('pkgrel')) {
    throw const FormatException('No pkgrel= line at the start of a line');
  }
  if (commit != null && !seen.contains('_commit')) {
    throw const FormatException('No _commit= line at the start of a line');
  }
  for (final name in sha256sums.keys) {
    if (!seen.contains(name)) {
      throw FormatException('No $name=( array at the start of a line');
    }
  }
  return out.join('\n');
}

/// The index of the `)` closing an array opened on [rest], ignoring quoted
/// text, or null when the array carries on past this line.
int? _closingParenthesis(String rest) {
  var quoted = false;
  for (var i = 0; i < rest.length; i++) {
    final char = rest[i];
    if (char == "'") {
      quoted = !quoted;
    } else if (!quoted && char == ')') {
      return i;
    }
  }
  return null;
}

/// The index of the line that starts the close of an array, if any.
int? _nextClosingLine(List<String> lines, int start) {
  for (var i = start; i < lines.length; i++) {
    final line = lines[i].endsWith('\r')
        ? lines[i].substring(0, lines[i].length - 1)
        : lines[i];
    if (line.trimLeft().startsWith(')')) return i;
  }
  return null;
}

String _bashArrayBody(List<String> values) => values.map(_bashQuote).join(' ');

String _bashQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

void _checkAssignmentValue(String name, String value) {
  if (value.isEmpty || value.contains(RegExp(r'\s'))) {
    throw ArgumentError.value(
      value,
      name,
      'must be one non-empty word without whitespace',
    );
  }
}

void _checkMarketingVersion(String version) {
  if (!_marketingVersion.hasMatch(version)) {
    throw ArgumentError.value(
      version,
      'upstreamVersion',
      'must be a marketing version such as 1.9.5',
    );
  }
}

const _usage = '''
Usage:
  dart run tool/arch/bump.dart pkgver --upstream <x.y.z> --ahead <n> --short-sha <sha>
  dart run tool/arch/bump.dart pkgrel --current <n> [--force]
  dart run tool/arch/bump.dart rewrite --file <path> --pkgver <v> --pkgrel <n>
      [--commit <sha>] [--sums [<array>=]<comma-separated>]...''';

/// Runs a bump command and returns the process exit code. [out] receives
/// the version, or the JSON summary of a rewrite; [err] receives the
/// reason for a failure.
int runBumpCli(
  List<String> arguments, {
  required StringSink out,
  required StringSink err,
}) {
  try {
    if (arguments.isEmpty) throw const _UsageException('No command given');
    final options = _parseOptions(arguments.sublist(1));
    switch (arguments.first) {
      case 'pkgver':
        _onlyOptions(options, const {'upstream', 'ahead', 'short-sha'});
        out.writeln(
          computeSourcePkgver(
            _requiredOption(options, 'upstream'),
            _intOption(options, 'ahead'),
            _requiredOption(options, 'short-sha'),
          ),
        );
        return 0;
      case 'pkgrel':
        _onlyOptions(options, const {'current', 'force'});
        out.writeln(
          nextPkgrel(
            _intOption(options, 'current'),
            options.containsKey('force'),
          ),
        );
        return 0;
      case 'rewrite':
        _onlyOptions(options, const {
          'file',
          'pkgver',
          'pkgrel',
          'commit',
          'sums',
        });
        final file = File(_requiredOption(options, 'file'));
        final pkgver = _requiredOption(options, 'pkgver');
        final pkgrel = _intOption(options, 'pkgrel');
        final commit = options.containsKey('commit')
            ? _requiredOption(options, 'commit')
            : null;
        final sums = _parseSums(options['sums'] ?? const []);
        file.writeAsStringSync(
          rewritePkgbuild(
            file.readAsStringSync(),
            pkgver,
            pkgrel,
            commit: commit,
            sha256sums: sums,
          ),
        );
        out.writeln(
          jsonEncode(<String, Object?>{
            'file': file.path,
            'pkgver': pkgver,
            'pkgrel': pkgrel,
            'commit': ?commit,
            'sha256sums': sums,
          }),
        );
        return 0;
      default:
        throw _UsageException('Unknown command: ${arguments.first}');
    }
  } on _UsageException catch (error) {
    err
      ..writeln(error.message)
      ..writeln(_usage);
    return 2;
  } on ArgumentError catch (error) {
    err.writeln(error);
    return 1;
  } on FormatException catch (error) {
    err.writeln(error);
    return 1;
  } on FileSystemException catch (error) {
    err.writeln('Cannot rewrite ${error.path}: ${error.message}');
    return 1;
  }
}

const _flags = {'force'};

Map<String, List<String>> _parseOptions(List<String> arguments) {
  final options = <String, List<String>>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--') || argument.length == 2) {
      throw _UsageException('Unexpected argument: $argument');
    }
    final name = argument.substring(2);
    if (_flags.contains(name)) {
      if (options.containsKey(name)) {
        throw _UsageException('--$name given more than once');
      }
      options[name] = const [''];
      continue;
    }
    if (i + 1 >= arguments.length) {
      throw _UsageException('$argument needs a value');
    }
    options.putIfAbsent(name, () => []).add(arguments[++i]);
  }
  return options;
}

void _onlyOptions(Map<String, List<String>> options, Set<String> allowed) {
  for (final name in options.keys) {
    if (!allowed.contains(name)) {
      throw _UsageException('Unknown option: --$name');
    }
  }
}

String _requiredOption(Map<String, List<String>> options, String name) {
  final values = options[name];
  if (values == null) throw _UsageException('--$name is required');
  if (values.length > 1) throw _UsageException('--$name given more than once');
  return values.single;
}

int _intOption(Map<String, List<String>> options, String name) {
  final value = _requiredOption(options, name);
  return int.tryParse(value) ??
      (throw _UsageException('--$name must be an integer, not $value'));
}

/// `--sums a,b` is the sha256sums array; `--sums sha256sums_x86_64=c,d` names
/// another.
Map<String, List<String>> _parseSums(List<String> specs) {
  final sums = <String, List<String>>{};
  for (final spec in specs) {
    final equals = spec.indexOf('=');
    final name = equals < 0 ? 'sha256sums' : spec.substring(0, equals);
    final value = equals < 0 ? spec : spec.substring(equals + 1);
    if (!_sumsName.hasMatch(name)) {
      throw _UsageException('Not a checksum array: $name');
    }
    if (sums.containsKey(name)) {
      throw _UsageException('--sums $name given more than once');
    }
    sums[name] = value.isEmpty
        ? []
        : value.split(',').map((sum) {
            final trimmed = sum.trim();
            if (trimmed.isEmpty) {
              throw _UsageException('Empty checksum in --sums $spec');
            }
            return trimmed;
          }).toList();
  }
  return sums;
}

class _UsageException implements Exception {
  const _UsageException(this.message);

  final String message;
}

void main(List<String> arguments) {
  final code = runBumpCli(arguments, out: stdout, err: stderr);
  if (code != 0) exit(code);
}
