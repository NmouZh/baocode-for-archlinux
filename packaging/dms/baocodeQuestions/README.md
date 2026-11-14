# BaoCode Questions for DMS

Shows the questions a BaoCode agent waits on in a DMS popup, and sends the
answer back without leaving the shell. The app publishes them in
`$XDG_RUNTIME_DIR/baocode/questions/state.json`; the plugin writes
`answers/<token>.json` next to it, where the app picks it up.

The app side is `lib/notifications/dms_questions_io.dart`; it is on Linux
only and needs a build that includes it.

## Install

```sh
mkdir -p ~/.config/dms/plugins
cp -r packaging/dms/baocodeQuestions ~/.config/dms/plugins/
dms ipc call plugins enable baocodeQuestions
```

After editing the plugin:

```sh
dms ipc call plugins reload baocodeQuestions
```

## Check

```sh
dms ipc call baocodeQuestions status   # {"count":N,"tokens":[...]}
dms ipc call baocodeQuestions open     # open the popup if something waits
```

The bar pill (`forum` icon with a count) appears only while an agent waits.
Set DND in DMS to keep the popup from opening by itself; the pill still counts.

## Behaviour

- One card per request waiting. A request's questions are shown together and
  are answered together, as the kernel expects one answer per request.
- Options, multi-select and free text; Enter submits the card when every
  question has an answer, and moves to the next empty field otherwise. For
  a single-answer question an option and free text are alternatives:
  picking one clears the other.
- While loaded, the plugin touches `plugin` next to `state.json` every
  10 seconds. The app reads that heartbeat and leaves out its own desktop
  notification for a question this popup shows, so it is not announced
  twice. A heartbeat 30 seconds old counts as gone: notifications return.
- A submitted card is marked **已处理** and is never popped again. If the app
  does not stop waiting on it within 15 s, it shows **未送达** with a retry.
- Answers are written whole (`state.json` style atomic replace), one at a
  time, with a short shell script. Non-ASCII text needs no escaping.
- Stale cards expire when the app removes them from `state.json`, including
  questions answered in the main window instead.