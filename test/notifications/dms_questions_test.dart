import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/notifications/dms_questions.dart';
import 'package:baocode/notifications/dms_questions_io.dart';

DmsQuestionNotice _notice({
  String threadId = 'agent-0',
  String threadTitle = 'Rate limit per API key',
  String requestId = 'request-0',
  String title = 'Claude has a question',
  bool pop = true,
  void Function(InteractionAnswer answer)? answer,
}) => DmsQuestionNotice(
  threadId: threadId,
  threadTitle: threadTitle,
  project: 'baocode',
  requestId: requestId,
  title: title,
  questions: const [
    Question(
      prompt: '输入框的高度策略用哪一种？',
      header: '高度策略',
      options: [
        QuestionOption('随内容自动增高，最多 8 行', description: '最符合直觉'),
        QuestionOption('固定 3 行，超出滚动'),
      ],
    ),
    Question(
      prompt: '需要支持哪些快捷输入？',
      header: '快捷输入',
      allowMultiple: true,
      options: [QuestionOption('@ 提及文件'), QuestionOption('/ 命令')],
    ),
  ],
  pop: pop,
  answer: answer ?? (_) {},
);

List<Map<String, Object?>> _questions(File state) {
  final decoded = jsonDecode(state.readAsStringSync()) as Map<String, Object?>;
  return [
    for (final question in decoded['questions'] as List)
      (question as Map).cast<String, Object?>(),
  ];
}

Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for the bridge');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory root;
  late File state;
  late Directory answers;
  late DmsQuestionBridge bridge;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dms_questions');
    state = File('${root.path}/state.json');
    answers = Directory('${root.path}/answers');
    bridge = DmsQuestionBridge(
      root: root,
      scanInterval: const Duration(milliseconds: 20),
    )..start();
  });

  tearDown(() {
    bridge.dispose();
    root.deleteSync(recursive: true);
  });

  test('knows whether the DMS plugin is loaded', () {
    expect(bridge.available, isFalse, reason: 'no plugin has said hello');
    final presence = File('${root.path}/plugin')..writeAsStringSync('1234');
    expect(bridge.available, isTrue);
    presence.setLastModifiedSync(
      DateTime.now().subtract(const Duration(minutes: 2)),
    );
    expect(bridge.available, isFalse, reason: 'a heartbeat long gone');
  });

  test('publishes questions and applies the answer written for one', () async {
    final applied = <InteractionAnswer>[];
    bridge.sync([
      _notice(answer: applied.add),
      _notice(
        threadId: 'agent-1',
        threadTitle: 'Sticky user message',
        requestId: 'request-1',
      ),
    ]);

    await _until(() => state.existsSync() && _questions(state).length == 2);
    final first = _questions(state).first;
    final token = first['token'] as String;
    expect(first['thread'], 'Rate limit per API key');
    expect(first['project'], 'baocode');
    expect(first['request'], 'request-0');
    expect(first['title'], 'Claude has a question');
    expect(first['pop'], isTrue);
    final asked = (first['questions'] as List).cast<Map>();
    expect(asked, hasLength(2));
    expect(asked.first['prompt'], '输入框的高度策略用哪一种？');
    expect(asked.first['header'], '高度策略');
    expect(asked.first['other'], isTrue);
    final options = (asked.first['options'] as List).cast<Map>();
    expect(options.first['label'], '随内容自动增高，最多 8 行');
    expect(options.first['description'], '最符合直觉');
    expect(asked.last['multiple'], isTrue);

    File('${answers.path}/$token.json').writeAsStringSync(
      jsonEncode({
        'token': token,
        'picks': [
          ['固定 3 行，超出滚动'],
          ['@ 提及文件', '/ 命令'],
        ],
        'skipped': false,
      }),
    );

    await _until(() => applied.isNotEmpty);
    final answer = applied.single as QuestionAnswer;
    expect(answer.skipped, isFalse);
    expect(answer.picks, [
      ['固定 3 行，超出滚动'],
      ['@ 提及文件', '/ 命令'],
    ]);
    await _until(() => !File('${answers.path}/$token.json').existsSync());
    // Answered: the card goes, and the other waits on.
    await _until(() {
      final questions = _questions(state);
      return questions.length == 1 && questions.single['token'] != token;
    });
  });

  test('takes a request skipped in DMS', () async {
    final applied = <InteractionAnswer>[];
    bridge.sync([_notice(answer: applied.add)]);
    await _until(() => state.existsSync() && _questions(state).length == 1);
    final token = _questions(state).single['token'] as String;

    File('${answers.path}/$token.json')
        .writeAsStringSync(jsonEncode({'token': token, 'skipped': true}));

    await _until(() => applied.isNotEmpty);
    expect((applied.single as QuestionAnswer).skipped, isTrue);
  });

  test('pads answers with a question left unanswered', () async {
    final applied = <InteractionAnswer>[];
    bridge.sync([_notice(answer: applied.add)]);
    await _until(() => state.existsSync() && _questions(state).length == 1);
    final token = _questions(state).single['token'] as String;

    File('${answers.path}/$token.json').writeAsStringSync(
      jsonEncode({
        'token': token,
        'picks': [
          ['可拖拽调整高度'],
        ],
      }),
    );

    await _until(() => applied.isNotEmpty);
    expect((applied.single as QuestionAnswer).picks, [
      ['可拖拽调整高度'],
      <String>[],
    ]);
  });

  test('forgets an answer for nothing it shows', () async {
    final applied = <InteractionAnswer>[];
    bridge.sync([_notice(answer: applied.add)]);
    await _until(() => answers.existsSync());
    final stray = File('${answers.path}/never-shown.json')
      ..writeAsStringSync(jsonEncode({'picks': []}));

    await _until(() => !stray.existsSync());
    expect(applied, isEmpty);
  });

  test('shows nothing once the agent goes, and clears on dispose', () async {
    bridge.sync([_notice()]);
    await _until(() => state.existsSync() && _questions(state).length == 1);

    bridge.sync(const []);
    await _until(() => _questions(state).isEmpty);

    bridge.dispose();
    await _until(() => !state.existsSync());
  });
}
