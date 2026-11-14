import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

// Bar pill: hidden (and taking no space) unless an agent waits on an
// answer. Click opens the same popup the daemon opens by itself.
PluginComponent {
    id: root

    property var popoutService: null

    readonly property var daemon: pluginService?.pluginDaemonInstances?.[pluginId] ?? null
    readonly property int count: daemon ? daemon.count : 0
    readonly property bool shown: count > 0
    readonly property color iconColor: Theme.primary

    onShownChanged: setVisibilityOverride(shown)
    Component.onCompleted: setVisibilityOverride(shown)

    pillClickAction: function () {
        if (root.daemon)
            root.daemon.openPopup();
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "forum"
                size: root.iconSize
                color: root.iconColor
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.count > 99 ? "99+" : root.count
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS

            DIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "forum"
                size: root.iconSize
                color: root.iconColor
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.count > 99 ? "99+" : root.count
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
            }
        }
    }
}