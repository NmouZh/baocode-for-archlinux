import QtQuick
import qs.Common
import qs.DCommon.Widgets

// One request waiting, all its questions, and the answer to send. Two
// states on top of waiting: answered here (marked, no second answer), and
// not delivered (the answer file could not be written, offer it again).
Rectangle {
    id: card

    property var daemon: null
    property var notice: null

    readonly property bool handled: card.daemon && card.notice ? !!card.daemon.handled[card.notice.token] : false
    readonly property bool failed: card.daemon && card.notice ? !!card.daemon.failed[card.notice.token] : false
    readonly property bool answered: handled && !failed
    readonly property bool ready: card.daemon && card.notice ? card.daemon.canSubmit(card.notice) : false

    width: parent ? parent.width : 0
    implicitHeight: body.implicitHeight + Theme.spacingL * 2
    radius: Theme.cornerRadiusM
    color: Theme.surfaceContainerHigh
    border.width: 1
    border.color: failed ? Theme.error : Theme.outlineVariant
    opacity: answered ? 0.72 : 1

    function submit() {
        if (card.daemon && card.notice)
            card.daemon.submit(card.notice);
    }

    function skip() {
        if (card.daemon && card.notice)
            card.daemon.skip(card.notice);
    }

    function focusInput() {
        if (questions.itemAt(0))
            questions.itemAt(0).focusField();
    }

    function focusNextEmpty() {
        for (var i = 0; i < questions.count; i++) {
            var question = questions.itemAt(i);
            if (!question || question.isAnswered())
                continue;
            if (question.focusField())
                return;
        }
    }

    Column {
        id: body
        x: Theme.spacingL
        y: Theme.spacingL
        width: card.width - Theme.spacingL * 2
        spacing: Theme.spacingM

        Item {
            width: parent.width
            implicitHeight: Math.max(titles.implicitHeight, stateChip.height)

            Column {
                id: titles
                width: parent.width - (stateChip.visible ? stateChip.width + Theme.spacingS : 0)
                spacing: 2

                StyledText {
                    width: parent.width
                    text: card.notice ? card.notice.title : ""
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    width: parent.width
                    text: {
                        if (!card.notice)
                            return "";
                        var parts = [card.notice.thread, card.notice.project].filter(function (part) {
                            return part !== "";
                        });
                        return parts.join(" · ");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                id: stateChip
                visible: card.handled
                anchors.right: parent.right
                anchors.top: parent.top
                height: stateText.implicitHeight + 6
                width: stateIcon.width + stateText.implicitWidth + Theme.spacingS + Theme.spacingXS * 2
                radius: height / 2
                color: card.failed ? Theme.errorContainer : Theme.primaryContainer

                DIcon {
                    id: stateIcon
                    x: Theme.spacingXS + 2
                    anchors.verticalCenter: parent.verticalCenter
                    name: card.failed ? "error_outline" : "check"
                    size: 12
                    color: card.failed ? Theme.onErrorContainer : Theme.onPrimaryContainer
                }

                StyledText {
                    id: stateText
                    anchors.left: stateIcon.right
                    anchors.leftMargin: Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.failed ? "未送达" : "已处理"
                    font.pixelSize: Theme.fontSizeSmall
                    color: card.failed ? Theme.onErrorContainer : Theme.onPrimaryContainer
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outlineVariant
        }

        Repeater {
            id: questions
            model: card.notice ? card.notice.questions : []

            delegate: Column {
                id: questionBlock

                required property int index
                required property var modelData

                width: body.width
                spacing: Theme.spacingS

                function isAnswered() {
                    if (!card.daemon || !card.notice)
                        return false;
                    return card.daemon.textFor(card.notice.token, index).trim() !== ""
                        || card.daemon.picksFor(card.notice.token, index).length > 0;
                }

                function focusField() {
                    if (!field.item)
                        return false;
                    field.item.forceActiveFocus();
                    return true;
                }

                Rectangle {
                    visible: questionBlock.modelData.header !== ""
                    height: headerText.implicitHeight + 6
                    width: headerText.implicitWidth + Theme.spacingM
                    radius: height / 2
                    color: Theme.surfaceContainerHighest

                    StyledText {
                        id: headerText
                        anchors.centerIn: parent
                        text: questionBlock.modelData.header
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }

                StyledText {
                    width: parent.width
                    text: questionBlock.modelData.prompt
                        + (questionBlock.modelData.multiple ? "（可多选）" : "")
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeMedium + 1
                    color: Theme.surfaceText
                }

                Repeater {
                    model: questionBlock.modelData.options

                    delegate: Rectangle {
                        id: option

                        required property int index
                        required property var modelData

                        readonly property bool selected: card.daemon && card.notice
                            ? card.daemon.isPicked(card.notice.token, questionBlock.index, modelData.label)
                            : false

                        width: questionBlock.width
                        implicitHeight: optionBody.implicitHeight + Theme.spacingS * 2
                        radius: Theme.cornerRadiusS
                        color: option.selected
                            ? Theme.primaryContainer
                            : optionArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"
                        border.width: option.selected ? 1 : 0
                        border.color: Theme.primary

                        MouseArea {
                            id: optionArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !card.answered
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!card.daemon || !card.notice)
                                    return;
                                card.daemon.togglePick(
                                    card.notice.token,
                                    questionBlock.index,
                                    option.modelData.label,
                                    questionBlock.modelData.multiple
                                );
                            }
                        }

                        Row {
                            id: optionBody
                            x: Theme.spacingS
                            y: Theme.spacingS
                            width: option.width - Theme.spacingS * 2
                            spacing: Theme.spacingS

                            Rectangle {
                                width: 18
                                height: 18
                                radius: questionBlock.modelData.multiple ? 4 : 9
                                anchors.verticalCenter: parent.verticalCenter
                                color: option.selected ? Theme.primary : "transparent"
                                border.width: 1
                                border.color: option.selected ? Theme.primary : Theme.outline

                                DIcon {
                                    visible: option.selected
                                    anchors.centerIn: parent
                                    name: "check"
                                    size: 12
                                    color: Theme.onPrimary
                                }
                            }

                            Column {
                                width: parent.width - 18 - Theme.spacingS
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    text: option.modelData.label
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    visible: option.modelData.description !== ""
                                        && option.modelData.description !== option.modelData.label
                                    width: parent.width
                                    text: option.modelData.description
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }
                }

                Loader {
                    id: field
                    width: parent.width
                    active: questionBlock.modelData.other

                    sourceComponent: DTextField {
                        placeholderText: questionBlock.modelData.otherLabel !== ""
                            ? questionBlock.modelData.otherLabel
                            : "输入自己的回答…"

                        readOnly: card.answered
                        showClearButton: !card.answered

                        Component.onCompleted: {
                            if (!card.daemon || !card.notice)
                                return;
                            var saved = card.daemon.textFor(card.notice.token, questionBlock.index);
                            if (saved !== "")
                                text = saved;
                        }

                        onTextEdited: {
                            if (!card.daemon || !card.notice)
                                return;
                            card.daemon.setText(card.notice.token, questionBlock.index, text);
                        }

                        onAccepted: {
                            if (card.ready)
                                card.submit();
                            else
                                card.focusNextEmpty();
                        }
                    }
                }
            }
        }

        Item {
            width: parent.width
            implicitHeight: actions.implicitHeight

            Row {
                id: statusRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - actions.width - Theme.spacingM
                spacing: Theme.spacingXS

                DIcon {
                    visible: card.handled || card.failed
                    anchors.verticalCenter: parent.verticalCenter
                    name: card.failed ? "error_outline" : "check_circle"
                    size: 14
                    color: card.failed ? Theme.error : Theme.primary
                }

                StyledText {
                    width: parent.width - (card.handled || card.failed ? 18 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.failed
                        ? "回答没有送达 BaoCode，请重试"
                        : card.answered ? "已提交，等待 BaoCode 接收…" : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: card.failed ? Theme.error : Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            Row {
                id: actions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                DButton {
                    text: "跳过"
                    variant: "text"
                    enabled: !card.answered
                    onClicked: card.skip()
                }

                DButton {
                    text: card.answered ? "已提交" : card.failed ? "重试" : "提交回答"
                    iconName: card.failed ? "refresh" : ""
                    enabled: !card.answered && card.ready
                    onClicked: card.submit()
                }
            }
        }
    }
}