import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../kernel/kernel_types.dart';
import '../platform/app_platform.dart';
import '../platform/data_dir.dart' show writeFileAtomically;
import 'dms_questions.dart';

DmsQuestionPresenter? currentDmsQuestionPresenter() {
  if (!AppPlatform.isLinux || !Platform.isLinux) return null;
  // A test writes nothing outside its own folders.
  if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
  return DmsQuestionBridge();
}

/// Publishes the questions agents wait on to the DMS plugin, over the
/// session's runtime folder:
///
/// * `state.json`: every request waiting, as the popup shows it;
/// * `answers/<token>.json`: what the user wrote there, which this applies
///   to the agent and takes away.
///
/// Only the app that published a request answers it, by the token it gave
/// it. See packaging/dms/baocodeQuestions.
class DmsQuestionBridge implements DmsQuestionPresenter {
  DmsQuestionBridge({
    Directory? root,
    this.scanInterval = const Duration(seconds: 1),
  }) : _root = root ?? _defaultRoot();

  /// The session's, where the DMS plugin looks too. None without an
  /// XDG_RUNTIME_DIR, as on a session that has no shell to show it in.
  static Directory? _defaultRoot() {
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtime == null || runtime.isEmpty) return null;
    return Directory('$runtime/baocode/questions');
  }

  /// What the DMS plugin reads. There, or under [root] in a test.
  final Directory? _root;

  /// How often the answers are looked for besides the folder's events.
  final Duration scanInterval;

  Directory? get _answers =>
      _root == null ? null : Directory('${_root.path}/answers');

  File? get _state => _root == null ? null : File('${_root.path}/state.json');

  /// What the plugin touches while it is loaded (see the daemon's
  /// heartbeat): there is no other way to know whether anything reads
  /// [state].
  File? get _presence => _root == null ? null : File('${_root.path}/plugin');

  /// A heartbeat older than this is a plugin that is not running any more.
  static const presenceFreshFor = Duration(seconds: 30);

  @override
  bool get available {
    final presence = _presence;
    if (presence == null) return false;
    try {
      final modified = presence.statSync().modified;
      return DateTime.now().difference(modified) < presenceFreshFor;
    } on FileSystemException {
      return false;
    }
  }

  Future<void>? _started;
  Timer? _scan;
  Timer? _debounce;
  StreamSubscription<FileSystemEvent>? _watch;
  bool _reading = false;
  bool _disposed = false;

  /// What each token shows now, for the next answer.
  final Map<String, DmsQuestionNotice> _live = {};

  /// The token each (agent, request) was given, kept while it waits.
  final Map<(String, String), String> _tokens = {};

  /// Requests answered here, until the agent stops waiting on them: a
  /// status change in between must not show them again.
  final Set<(String, String)> _answered = {};

  /// When each token first appeared, the popup's order.
  final Map<String, int> _since = {};
  int _nextToken = 0;

  /// What [sync] last said, as [start] may come before it.
  List<DmsQuestionNotice> _latest = const [];

  /// Writes and answers run one after another, in the order they came.
  Future<void> _queue = Future.value();
  String? _signature;

  @override
  void start() {
    if (_root == null || _started != null) return;
    _started = _prepare();
  }

  Future<void> _prepare() async {
    final answers = _answers!;
    try {
      await answers.create(recursive: true);
      await _clear();
      _watch = _watchAnswers(answers);
      _scan = Timer.periodic(scanInterval, (_) => _readAnswers());
      await _writeState();
    } on FileSystemException catch (error) {
      debugPrint('dms questions: $error');
    }
  }

  /// Removes what an earlier run left, so nothing stale shows or answers.
  Future<void> _clear() async {
    try {
      if (await _state!.exists()) await _state!.delete();
    } on FileSystemException {
      // Gone already.
    }
    try {
      await for (final entry in _answers!.list()) {
        if (entry is! File) continue;
        try {
          await entry.delete();
        } on FileSystemException {
          // Gone already.
        }
      }
    } on FileSystemException {
      // No folder to clear.
    }
    _signature = null;
  }

  StreamSubscription<FileSystemEvent>? _watchAnswers(Directory answers) {
    try {
      return answers.watch().listen((_) => _readSoon(), onError: (Object _) {});
    } on Object {
      // No watching here; the timer alone finds them.
      return null;
    }
  }

  void _readSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 20), _readAnswers);
  }

  @override
  void sync(List<DmsQuestionNotice> notices) {
    if (_root == null || _disposed) return;
    final asked = <(String, String)>{};
    final kept = <DmsQuestionNotice>[];
    final wanted = <String>{};
    for (final notice in notices) {
      final key = (notice.threadId, notice.requestId);
      asked.add(key);
      if (_answered.contains(key)) continue;
      kept.add(notice);
      final token = _tokens.putIfAbsent(key, () => 'q${_nextToken++}');
      wanted.add(token);
      _live[token] = notice;
      _since.putIfAbsent(token, () => DateTime.now().millisecondsSinceEpoch);
    }
    _answered.removeWhere((key) => !asked.contains(key));
    _latest = List.unmodifiable(kept);
    for (final token in _live.keys.toList()) {
      if (wanted.contains(token)) continue;
      _live.remove(token);
      _since.remove(token);
    }
    _tokens.removeWhere((key, token) => !wanted.contains(token));
    _queue = _queue
        .then((_) => _writeState())
        .catchError((Object error) => debugPrint('dms questions: $error'));
  }

  Future<void> _writeState() async {
    if (_disposed || _root == null) return;
    final questions = <Map<String, Object?>>[];
    for (final notice in _latest) {
      final token = _tokens[(notice.threadId, notice.requestId)];
      if (token == null) continue;
      questions.add(_encode(token, notice));
    }
    final state = jsonEncode({'v': 1, 'questions': questions});
    if (state == _signature && await _state!.exists()) return;
    _signature = state;
    await writeFileAtomically(_state!, state);
  }

  Map<String, Object?> _encode(String token, DmsQuestionNotice notice) => {
    'token': token,
    'thread': notice.threadTitle,
    'project': notice.project,
    'request': notice.requestId,
    'title': notice.title,
    'pop': notice.pop,
    'at': _since[token] ?? 0,
    'questions': [
      for (final question in notice.questions)
        {
          'prompt': question.prompt,
          if (question.header.isNotEmpty) 'header': question.header,
          'options': [
            for (final option in question.options)
              {
                'label': option.label,
                if (option.description.isNotEmpty)
                  'description': option.description,
                'preview': ?option.preview,
              },
          ],
          if (question.allowMultiple) 'multiple': true,
          if (question.allowOther) 'other': true,
          'otherLabel': ?question.otherLabel,
        },
    ],
  };

  Future<void> _readAnswers() async {
    if (_reading || _disposed) return;
    final answers = _answers;
    if (answers == null) return;
    _reading = true;
    try {
      final List<FileSystemEntity> entries;
      try {
        entries = await answers.list().toList();
      } on FileSystemException {
        return;
      }
      for (final entry in entries) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        await _takeAnswer(entry);
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> _takeAnswer(File file) async {
    final name = file.path.split(Platform.pathSeparator).last;
    final token = name.substring(0, name.length - '.json'.length);
    final notice = _live[token];
    if (notice == null) {
      // Not waited on any more: an answer no agent takes.
      await _delete(file);
      return;
    }
    Map<String, Object?>? json;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) json = decoded;
    } on Object {
      // Half-written or not JSON: it comes again, or is no answer.
    }
    final answer = json == null ? null : _decode(notice, json);
    if (answer == null) {
      await _delete(file);
      return;
    }
    // One answer each: the card goes as this one is applied.
    _live.remove(token);
    _since.remove(token);
    _answered.add((notice.threadId, notice.requestId));
    _tokens.removeWhere((key, value) => value == token);
    _latest = List.unmodifiable([
      for (final other in _latest)
        if (!identical(other, notice)) other,
    ]);
    try {
      notice.answer(answer);
    } on Object catch (error) {
      // The agent went as the answer came: nothing waits on it.
      debugPrint('dms questions: $error');
    }
    await _delete(file);
    _queue = _queue
        .then((_) => _writeState())
        .catchError((Object error) => debugPrint('dms questions: $error'));
  }

  /// What the user picked, a list for each question the request asked:
  /// labels, or words of their own.
  InteractionAnswer? _decode(
    DmsQuestionNotice notice,
    Map<String, Object?> json,
  ) {
    if (json['skipped'] == true) {
      return const QuestionAnswer([], skipped: true);
    }
    final raw = json['picks'];
    if (raw is! List) return null;
    return QuestionAnswer([
      for (var i = 0; i < notice.questions.length; i++)
        [
          if (i < raw.length && raw[i] is List)
            for (final pick in raw[i] as List)
              if (pick is String && pick.trim().isNotEmpty) pick.trim(),
        ],
    ]);
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Gone already.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scan?.cancel();
    _debounce?.cancel();
    unawaited(_watch?.cancel());
    _watch = null;
    unawaited(_queue.whenComplete(_removeState));
  }

  Future<void> _removeState() async {
    final state = _state;
    if (state == null) return;
    try {
      if (await state.exists()) await state.delete();
    } on FileSystemException {
      // Gone already.
    }
    // Nothing reads an answer once the app has quit.
    try {
      await for (final entry in _answers!.list()) {
        if (entry is! File) continue;
        await _delete(entry);
      }
    } on FileSystemException {
      // No folder to clear.
    }
  }
}
