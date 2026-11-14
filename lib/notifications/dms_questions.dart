import '../kernel/kernel_types.dart';
import 'dms_questions_stub.dart'
    if (dart.library.io) 'dms_questions_io.dart'
    as platform;

/// One question an agent waits on, as DMS's popup shows it.
class DmsQuestionNotice {
  const DmsQuestionNotice({
    required this.threadId,
    required this.threadTitle,
    required this.project,
    required this.requestId,
    required this.title,
    required this.questions,
    required this.pop,
    required this.answer,
  });

  /// The agent, by the id its notifications use.
  final String threadId;

  /// The agent's title, as the sidebar has it.
  final String threadTitle;

  /// The folder it works in.
  final String project;

  final String requestId;

  /// The request's title, e.g. "Claude has a question".
  final String title;

  final List<Question> questions;

  /// Whether DMS should open its popup for this now: the window is not in
  /// front of it, or notifications always show.
  final bool pop;

  /// Applies what the user wrote in DMS, as the answer the agent waits on.
  final void Function(InteractionAnswer answer) answer;
}

/// Shows the agents' questions in DMS, and brings back the answers written
/// there (see packaging/dms/baocodeQuestions).
abstract interface class DmsQuestionPresenter {
  /// This machine's; none on the web, where no DMS runs.
  static DmsQuestionPresenter? current() =>
      platform.currentDmsQuestionPresenter();

  /// Whether DMS's plugin is loaded and will show what is published: the
  /// popup is then the notification, and the system's own would be a second
  /// one behind it. False when no plugin is there to show anything.
  bool get available;

  /// Prepares what the DMS plugin reads; once for the app.
  void start();

  /// Publishes what agents wait on now, replacing what was published.
  void sync(List<DmsQuestionNotice> notices);

  void dispose();
}
