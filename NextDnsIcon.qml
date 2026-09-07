import QtQuick
import qs.Commons
import qs.Ui

// A shield with a check inside: the filtering-resolver idea, in the same
// monochrome stroked weight as Omarchy's built-in bar glyphs. Drawn rather
// than taken from a font because nf-md-shield-check loses its check at 11px,
// and Qt's SVG rendering is unreliable at bar-icon sizes.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool crossed: false
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: canvas.requestPaint()
  onIconSizeChanged: canvas.requestPaint()
  onCrossedChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var s = Math.min(width, height)
      var cx = width / 2
      var cy = height / 2
      var w = s * 0.62
      var h = s * 0.74

      var left = cx - w / 2
      var right = cx + w / 2
      var top = cy - h / 2
      var bottom = cy + h / 2
      // Where the straight sides give way to the taper. Below this the shield
      // reads as a shield; above it, as a rectangle.
      var shoulder = top + h * 0.44

      ctx.strokeStyle = root.color
      ctx.lineWidth = Math.max(1.1, s * 0.11)
      ctx.lineJoin = "round"
      ctx.lineCap = "round"

      ctx.beginPath()
      ctx.moveTo(left, top)
      ctx.lineTo(right, top)
      ctx.lineTo(right, shoulder)
      ctx.quadraticCurveTo(right, bottom - h * 0.12, cx, bottom)
      ctx.quadraticCurveTo(left, bottom - h * 0.12, left, shoulder)
      ctx.closePath()
      ctx.stroke()

      // The check is what separates this from a generic shield, but at bar size
      // it collides with the strike-through and both turn to mud. Drop it when
      // struck; the strike alone already says "off".
      if (!root.crossed) {
        ctx.beginPath()
        ctx.lineWidth = Math.max(1.0, s * 0.10)
        ctx.moveTo(cx - w * 0.24, cy - h * 0.02)
        ctx.lineTo(cx - w * 0.04, cy + h * 0.15)
        ctx.lineTo(cx + w * 0.26, cy - h * 0.20)
        ctx.stroke()
      }
    }
  }

  // Same struck-through convention as the Wi-Fi, Tailscale and WireGuard marks.
  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
