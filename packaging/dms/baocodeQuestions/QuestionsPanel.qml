import QtQuick
import qs.Common
import qs.DCommon.Widgets

// The popup's content: every request waiting, each answerable on its own.
Item {
    id: panel

    property var daemon: null
    // Filled by PluginPopout, to close the popup.
    property var closePopout: null

    width: parent ? parent.width : 560
    implicitHeight: content.implicitHeight

    function focusFirst() {
        Qt.callLater(function () {
            if (cards.count === 0)
                return;
            var first = cards.itemAt(0);
            if (first)
                first.focusInput();
        });
    }

    Connections {
        target: panel.daemon

        function onFocusTickChanged() {
            panel.focusFirst();
        }
    }

    Component.onCompleted: {
        if (panel.daemon && panel.daemon.focusTick > 0)
            panel.focusFirst();
    }

    Column {
        id: content
        width: panel.width
        spacing: Theme.spacingM

        Item {
            width: parent.width
            implicitHeight: Math.max(headerRow.implicitHeight, closeButton.height)

            Row {
                id: headerRow
                width: parent.width - closeButton.width - Theme.spacingS
                spacing: Theme.spacingM

                Rectangle {
                    width: 40
                    height: 40
                    radius: 20
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.primaryContainer

                    DIcon {
                        anchors.centerIn: parent
                        name: "forum"
                        size: 22
                        color: Theme.onPrimaryContainer
                    }
                }

                Column {
                    width: parent.width - 40 - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: "BaoCode 的问题"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width
                        text: {
                            if (!panel.daemon || panel.daemon.pending.length === 0)
                                return "没有待回答的问题";
                            if (panel.daemon.count === 0)
                                return "都已提交，等待 BaoCode 接收…";
                            return panel.daemon.count + " 个待回答 · 回答会直接送到 BaoCode";
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }
            }

            DIconButton {
                id: closeButton
                anchors.right: parent.right
                anchors.top: parent.top
                iconName: "close"
                tooltipText: "关闭"
                onClicked: {
                    if (panel.closePopout)
                        panel.closePopout();
                }
            }
        }

        DFlickable {
            id: scroller
            width: parent.width
            visible: cards.count > 0
            height: Math.min(cardsColumn.implicitHeight, 430)
            contentWidth: width
            contentHeight: cardsColumn.implicitHeight
            clip: true

            Column {
                id: cardsColumn
                width: scroller.width
                spacing: Theme.spacingM

                Repeater {
                    id: cards
                    model: panel.daemon ? panel.daemon.pending : []

                    delegate: QuestionCard {
                        width: cardsColumn.width
                        daemon: panel.daemon
                        notice: modelData
                    }
                }
            }
        }

        StyledText {
            visible: cards.count === 0
            width: parent.width
            text: "没有待回答的问题。"
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceVariantText
        }

        StyledText {
            width: parent.width
            text: "Enter 提交 · Esc 关闭 · 也可以稍后点状态栏上的问答图标"
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
        }
    }
}