import QtQuick
import QtQuick.Controls as QQC
import qs.Commons

Column {
  id: root

  property string label: ""
  property int value: 0
  property int from: 0
  property int to: 100
  property int stepSize: 1
  property color labelColor: Color.foreground
  property color valueColor: Color.foreground
  property color accent: Color.accent

  // `live` fires continuously while dragging, for instant visual feedback
  // with no persistence cost. `modified` fires once, on release, and is the
  // signal that should trigger writing the value to disk.
  signal live(int value)
  signal modified(int value)

  spacing: Style.spacing.labelGap

  Text {
    text: root.label
    color: root.labelColor
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Row {
    width: parent.width
    spacing: Style.spacing.rowGap

    QQC.Slider {
      id: slider
      width: parent.width - readout.width - Style.spacing.rowGap
      implicitHeight: Style.space(20)
      from: root.from
      to: root.to
      stepSize: root.stepSize
      value: root.value

      // Guard against a spurious `moved`/`pressedChanged` at creation (seen
      // when a popup materializes with the pointer already resting over the
      // track) by requiring an actual press before either signal counts.
      property bool armed: false

      onPressedChanged: {
        if (pressed) armed = true
        else if (armed) {
          armed = false
          root.modified(Math.round(value))
        }
      }
      onMoved: if (armed) root.live(Math.round(value))

      background: Item {
        x: slider.leftPadding
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        width: slider.availableWidth
        height: Style.space(5)

        Rectangle {
          anchors.fill: parent
          radius: height / 2
          color: Util.alpha(root.labelColor, 0.35)
        }

        Rectangle {
          width: Math.max(height, slider.visualPosition * parent.width)
          height: parent.height
          radius: height / 2
          color: root.accent
        }
      }

      handle: Rectangle {
        x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        width: Style.space(13)
        height: width
        radius: width / 2
        color: root.accent
        scale: slider.pressed ? 1.25 : (sliderHover.hovered ? 1.1 : 1.0)

        Behavior on scale {
          NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
        }

        HoverHandler {
          id: sliderHover
        }
      }
    }

    Text {
      id: readout
      width: Style.space(28)
      text: String(slider.value.toFixed(0))
      horizontalAlignment: Text.AlignRight
      color: root.valueColor
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: slider.verticalCenter
    }
  }
}
