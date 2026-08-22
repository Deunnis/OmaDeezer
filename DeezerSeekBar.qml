import QtQuick
import QtQuick.Controls as QQC
import qs.Commons

Column {
  id: root

  property real position: 0
  property real duration: 0
  property bool seekable: true
  property color trackColor: Color.foreground
  property color labelColor: Color.foreground
  property color accent: Color.accent

  signal seek(real seconds)

  function formatTime(value) {
    var n = Math.max(0, Math.round(value))
    var m = Math.floor(n / 60)
    var s = n % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  spacing: Style.spacing.labelGap

  QQC.Slider {
    id: slider
    width: parent.width
    implicitHeight: Style.space(18)
    from: 0
    to: Math.max(root.duration, 0.001)
    value: root.position
    enabled: root.seekable

    // Same guard as DeezerSlider: require an actual press before a
    // pressedChanged transition counts, so a popup materializing with the
    // pointer already over the track can't fire a phantom seek.
    property bool armed: false

    onPressedChanged: {
      if (pressed) armed = true
      else if (armed) {
        armed = false
        root.seek(value)
      }
    }

    background: Item {
      x: slider.leftPadding
      y: slider.topPadding + slider.availableHeight / 2 - height / 2
      width: slider.availableWidth
      height: Style.space(4)

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Util.alpha(root.trackColor, 0.35)
      }

      Rectangle {
        width: Math.max(height, slider.visualPosition * parent.width)
        height: parent.height
        radius: height / 2
        color: root.accent
        opacity: root.seekable ? 1.0 : 0.5
      }
    }

    handle: Rectangle {
      x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
      y: slider.topPadding + slider.availableHeight / 2 - height / 2
      width: Style.space(11)
      height: width
      radius: width / 2
      color: root.accent
      opacity: root.seekable ? 1.0 : 0.5
      scale: slider.pressed ? 1.3 : (seekHover.hovered ? 1.15 : 1.0)

      Behavior on scale {
        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
      }

      HoverHandler {
        id: seekHover
      }
    }
  }

  Item {
    width: parent.width
    height: posLabel.implicitHeight

    Text {
      id: posLabel
      anchors.left: parent.left
      text: root.formatTime(slider.pressed ? slider.value : root.position)
      color: root.labelColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: parent.right
      text: root.formatTime(root.duration)
      color: root.labelColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
