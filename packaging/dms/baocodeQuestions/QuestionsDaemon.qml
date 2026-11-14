import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Services

// Reads what BaoCode's agents ask from the runtime folder the app writes
// ($XDG_RUNTIME_DIR/baocode/questions/state.json), shows it in a popup, and
// writes each answer where the app picks it up
// (answers/<token>.json). The app owns the questions; this plugin only
// shows and answers them. See lib/notifications/dms_questions_io.dart.
PluginComponent {
    id: root

    property var popoutService: null
    // The popup's surface namespace; PluginPopout reads it from here.
    layerNamespacePlugin: "baocodeQuestions"

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string stateDir: root.runtimeDir !== "" ? root.runtimeDir + "/baocode/questions" : ""
    readonly property string statePath: root.stateDir !== "" ? root.stateDir + "/state.json" : ""
    readonly property string answerDir: root.stateDir !== "" ? root.stateDir + "/answers" : ""

    // What the app published, one entry per request waiting: token, thread,
    // project, request, title, pop, at, questions[].
    property var pending: []
    // Tokens answered here, with when: shown as handled until the app stops
    // waiting on them.
    property var handled: ({})
    // Tokens whose answer could not be written.
    property var failed: ({})
    // Tokens whose arrival was already shown, so nothing pops twice.
    property var announced: ({})
    // What was typed or picked here, per token: { picks: {q: [label]},
    // text: {q: "..."} }. Kept across state refreshes.
    property var drafts: ({})
    // Answers are written one at a time.
    property var writeQueue: []
    property var writing: null
    // The last state.json read, so an unchanged poll changes nothing.
    property string lastState: ""
    // Raised when the popup opens, for the panel to focus its first field.
    property int focusTick: 0

    readonly property int count: {
        var n = 0;
        for (var i = 0; i < root.pending.length; i++)
            if (!root.handled[root.pending[i].token])
                n++;
        return n;
    }
    readonly property bool allHandled: root.pending.length > 0 && root.count === 0

    // ---- Reading what the app asks -----------------------------------------------

    FileView {
        id: stateView
        path: root.statePath
        watchChanges: true
        // No state file is the normal case, not a warning every second.
        printErrors: false

        onLoaded: root._readState(text())
        onLoadFailed: error => root._readState("")
    }

    // Watching catches writes that replace the file; the poll catches the
    // rest, and the state changes only when the app says so.
    Timer {
        interval: 1000
        repeat: true
        running: root.statePath !== ""
        onTriggered: stateView.reload()
    }

    function _readState(raw) {
        if (raw === root.lastState)
            return;
        root.lastState = raw;
        root._applyState(raw);
    }

    function _applyState(raw) {
        var list = [];
        if (raw !== "") {
            try {
                var doc = JSON.parse(raw);
                if (doc && Array.isArray(doc.questions)) {
                    for (var i = 0; i < doc.questions.length; i++) {
                        var q = doc.questions[i];
                        if (q && typeof q.token === "string" && q.token !== "" && Array.isArray(q.questions))
                            list.push(root._clean(q));
                    }
                }
            } catch (e) {
                console.warn("baocodeQuestions: unreadable state:", e.message);
            }
        }
        // Forget marks and drafts for what the app no longer waits on.
        var live = ({});
        for (var j = 0; j < list.length; j++)
            live[list[j].token] = true;
        root.handled = root._onlyLive(root.handled, live);
        root.failed = root._onlyLive(root.failed, live);
        root.announced = root._onlyLive(root.announced, live);
        root.drafts = root._onlyLive(root.drafts, live);
        root.pending = list;

        if (list.length === 0) {
            if (popup.shouldBeVisible)
                popup.close();
            return;
        }
        root._maybeOpen();
    }

    function _clean(q) {
        var questions = [];
        for (var i = 0; i < q.questions.length; i++) {
            var question = q.questions[i];
            if (!question)
                continue;
            var options = [];
            if (Array.isArray(question.options)) {
                for (var j = 0; j < question.options.length; j++) {
                    var option = question.options[j];
                    if (option && typeof option.label === "string" && option.label !== "")
                        options.push({
                            label: option.label,
                            description: typeof option.description === "string" ? option.description : "",
                            preview: typeof option.preview === "string" ? option.preview : ""
                        });
                }
            }
            questions.push({
                prompt: typeof question.prompt === "string" ? question.prompt : "",
                header: typeof question.header === "string" ? question.header : "",
                options: options,
                multiple: question.multiple === true,
                // The app only writes other when the agent allows it; no
                // options at all leaves words the only answer.
                other: question.other === true || options.length === 0,
                otherLabel: typeof question.otherLabel === "string" ? question.otherLabel : ""
            });
        }
        return {
            token: q.token,
            thread: typeof q.thread === "string" ? q.thread : "",
            project: typeof q.project === "string" ? q.project : "",
            request: typeof q.request === "string" ? q.request : "",
            title: typeof q.title === "string" && q.title !== "" ? q.title : "BaoCode 有问题要问你",
            pop: q.pop !== false,
            at: typeof q.at === "number" ? q.at : 0,
            questions: questions
        };
    }

    function _onlyLive(map, live) {
        var kept = ({});
        for (var key in map)
            if (live[key])
                kept[key] = map[key];
        return kept;
    }

    // ---- Opening the popup -------------------------------------------------------

    function _maybeOpen() {
        if (root.statePath === "" || root.pending.length === 0)
            return;
        // Do Not Disturb: the pill still counts, but nothing comes in front.
        if (SessionData.doNotDisturb)
            return;
        var shouldOpen = false;
        var next = Object.assign({}, root.announced);
        for (var i = 0; i < root.pending.length; i++) {
            var q = root.pending[i];
            if (next[q.token] || root.handled[q.token])
                continue;
            next[q.token] = true;
            if (q.pop)
                shouldOpen = true;
        }
        root.announced = next;
        if (shouldOpen)
            root.openPopup();
    }

    function openPopup() {
        if (root.pending.length === 0)
            return;
        var screen = CompositorService.getFocusedScreen();
        if (!screen)
            return;
        popup.screen = screen;
        root._place(screen);
        root.focusTick++;
        if (popup.shouldBeVisible) {
            popup.updateSurfacePosition();
            return;
        }
        PopoutManager.requestPopout(popup, undefined, "baocodeQuestions");
    }

    // A popup of its own, centered on the focused screen: the widget pill
    // only opens it.
    PluginPopout {
        id: popup
        pluginId: root.pluginId
        contentWidth: 560
        contentHeight: 420
        pluginContent: Component {
            QuestionsPanel {
                daemon: root
            }
        }
    }

    function _place(screen) {
        if (!screen)
            return;
        var height = popup.contentHeight > 0 ? popup.contentHeight : 420;
        // DPopout centers the popup on triggerX; triggerY is its top edge
        // for the top edge of the screen.
        var x = Math.round(screen.width / 2);
        var y = Math.round((screen.height - height) / 2);
        popup.setTriggerPosition(x, y, 0, "center", screen, 0, 0, 4, null, null);
    }

    // The panel's height shows once it is laid out: center it then.
    Connections {
        target: popup
        function onContentHeightChanged() {
            if (!popup.shouldBeVisible)
                return;
            Qt.callLater(function () {
                root._place(popup.screen);
                popup.updateSurfacePosition();
            });
        }
    }

    // ---- Answering ---------------------------------------------------------------

    function draft(token) {
        if (!root.drafts[token])
            root.drafts[token] = { picks: ({}), text: ({}) };
        return root.drafts[token];
    }

    function picksFor(token, question) {
        var d = root.drafts[token];
        return d && d.picks[question] ? d.picks[question] : [];
    }

    function textFor(token, question) {
        var d = root.drafts[token];
        return d && d.text[question] !== undefined ? d.text[question] : "";
    }

    function isPicked(token, question, label) {
        return root.picksFor(token, question).indexOf(label) >= 0;
    }

    function togglePick(token, question, label, multiple) {
        if (root.handled[token] && !root.failed[token])
            return;
        var d = root.draft(token);
        var current = root.picksFor(token, question);
        var next;
        if (multiple) {
            next = current.indexOf(label) >= 0
                ? current.filter(function (picked) { return picked !== label; })
                : current.concat([label]);
        } else {
            next = current.indexOf(label) >= 0 ? [] : [label];
        }
        var picks = Object.assign({}, d.picks);
        picks[question] = next;
        var updated = Object.assign({}, root.drafts);
        updated[token] = { picks: picks, text: d.text };
        root.drafts = updated;
    }

    function setText(token, question, value) {
        if (root.handled[token] && !root.failed[token])
            return;
        var d = root.draft(token);
        var text = Object.assign({}, d.text);
        text[question] = value;
        var updated = Object.assign({}, root.drafts);
        updated[token] = { picks: d.picks, text: text };
        root.drafts = updated;
    }

    function canSubmit(notice) {
        for (var i = 0; i < notice.questions.length; i++) {
            if (root.textFor(notice.token, i).trim() === "" && root.picksFor(notice.token, i).length === 0)
                return false;
        }
        return true;
    }

    function answerPicks(notice) {
        var answer = [];
        for (var i = 0; i < notice.questions.length; i++) {
            var picked = root.picksFor(notice.token, i).slice();
            var text = root.textFor(notice.token, i).trim();
            if (text === "") {
                answer.push(picked);
            } else if (notice.questions[i].multiple) {
                if (picked.indexOf(text) < 0)
                    picked.push(text);
                answer.push(picked);
            } else {
                // Words of their own are the "Other" choice, alone.
                answer.push([text]);
            }
        }
        return answer;
    }

    function submit(notice) {
        if (!root.canSubmit(notice))
            return;
        root._send(notice, root.answerPicks(notice), false);
    }

    function skip(notice) {
        root._send(notice, [], true);
    }

    function _send(notice, picks, skipped) {
        if (root.handled[notice.token] && !root.failed[notice.token])
            return;
        var handled = Object.assign({}, root.handled);
        handled[notice.token] = Date.now();
        root.handled = handled;
        if (root.failed[notice.token]) {
            var failed = Object.assign({}, root.failed);
            delete failed[notice.token];
            root.failed = failed;
        }
        root.writeQueue = root.writeQueue.concat([{
            token: notice.token,
            json: JSON.stringify({
                token: notice.token,
                picks: picks,
                skipped: skipped
            })
        }]);
        root._pumpWrites();
    }

    // A short shell script writes the answer in one move, so the app never
    // reads half of it. The JSON rides in an environment variable, so
    // quotes and non-ASCII text need no escaping.
    Process {
        id: writer
        running: false
        command: ["sh", "-c", "mkdir -p \"$(dirname \"$BAOCODE_ANSWER_PATH\")\" && printf '%s' \"$BAOCODE_ANSWER\" > \"$BAOCODE_ANSWER_PATH.tmp\" && mv \"$BAOCODE_ANSWER_PATH.tmp\" \"$BAOCODE_ANSWER_PATH\""]
        onExited: exitCode => {
            var job = root.writing;
            root.writing = null;
            if (exitCode !== 0 && job) {
                var handled = Object.assign({}, root.handled);
                delete handled[job.token];
                root.handled = handled;
                var failed = Object.assign({}, root.failed);
                failed[job.token] = true;
                root.failed = failed;
                console.warn("baocodeQuestions: answer not written:", job.token, "code", exitCode);
            }
            root._pumpWrites();
        }
    }

    function _pumpWrites() {
        if (writer.running || root.writing || root.writeQueue.length === 0)
            return;
        var job = root.writeQueue[0];
        root.writeQueue = root.writeQueue.slice(1);
        root.writing = job;
        writer.environment = {
            "BAOCODE_ANSWER": job.json,
            "BAOCODE_ANSWER_PATH": root.answerDir + "/" + job.token + ".json"
        };
        writer.running = true;
    }

    // A question answered here stays marked until the app stops waiting on
    // it; if that never comes, the answer did not land: offer it again.
    Timer {
        interval: 1000
        repeat: true
        running: root.pending.length > 0
        onTriggered: {
            var now = Date.now();
            var changed = false;
            var handled = Object.assign({}, root.handled);
            var failed = Object.assign({}, root.failed);
            for (var token in handled) {
                if (now - handled[token] < 15000)
                    continue;
                var still = false;
                for (var i = 0; i < root.pending.length; i++)
                    if (root.pending[i].token === token)
                        still = true;
                if (!still)
                    continue;
                delete handled[token];
                failed[token] = true;
                changed = true;
            }
            if (changed) {
                root.handled = handled;
                root.failed = failed;
            }
        }
    }

    // `dms ipc call baocodeQuestions open`, `... status`
    IpcHandler {
        target: "baocodeQuestions"

        function open(): string {
            root.openPopup();
            return root.count + " waiting";
        }

        function status(): string {
            var tokens = [];
            for (var i = 0; i < root.pending.length; i++)
                tokens.push(root.pending[i].token);
            return JSON.stringify({ count: root.count, tokens: tokens });
        }
    }
}