import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "daan.deezer"

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: findDeezerPlayer()
  readonly property bool active: player !== null
  readonly property bool hasTrack: active && (player.trackTitle || player.trackArtist)
  readonly property string playIcon: active && player.isPlaying ? "󰏤" : "󰐊"
  readonly property string title: plainText(active ? (player.trackTitle || "") : "")
  readonly property string artist: plainText(active ? (player.trackArtist || "") : "")
  readonly property string album: plainText(active && player.trackAlbum ? player.trackAlbum : "")
  readonly property string artUrl: safeArtUrl(active && player.trackArtUrl ? player.trackArtUrl : "")
  // Art is downloaded ourselves into a private cache file rather than handed
  // straight to Image.source: a HEAD Content-Length check doesn't bind the
  // actual GET (the server or a redirect hop can still return a larger or
  // chunked body), so curl's own --max-filesize enforces the cap during the
  // real transfer into a file only this widget writes, and only a
  // size-reverified local file is ever exposed to Image.source.
  property string verifiedArtUrl: ""
  readonly property int maxArtBytes: 8 * 1024 * 1024
  readonly property string artCacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy/io.github.omadeezer/art"
  property bool artCacheReady: false
  // The single art Process trio (mktemp -> curl -> stat) is reused
  // sequentially rather than spawned per track change, so these track which
  // url the in-flight chain belongs to rather than relying on process
  // identity - see artStageFinished() for why that distinction matters.
  property string wantedArtUrl: ""
  property string runningArtUrl: ""
  property string verifiedForUrl: ""
  property string activeTempPath: ""
  property string lastGoodArtPath: ""
  readonly property bool canSeek: active && player.canSeek && player.positionSupported
  readonly property bool showSeekBar: active && player.positionSupported && player.lengthSupported
  readonly property real trackDuration: active && player.lengthSupported ? player.length : 0
  readonly property bool shuffleSupported: active && player.shuffleSupported
  readonly property bool shuffleOn: active && player.shuffle
  readonly property bool loopSupported: active && player.loopSupported
  readonly property int loopState: active ? player.loopState : MprisLoopState.None
  property bool popupOpen: false
  property bool settingsOpen: false

  function toggleShuffle() {
    if (shuffleSupported) player.shuffle = !player.shuffle
  }

  // off → repeat playlist → repeat this song → off
  function cycleLoop() {
    if (!loopSupported) return
    player.loopState = loopState === MprisLoopState.None ? MprisLoopState.Playlist
      : loopState === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None
  }

  readonly property string loopIconName: loopState === MprisLoopState.Track ? "media-playlist-repeat-song-symbolic"
    : loopState === MprisLoopState.Playlist ? "media-playlist-repeat-symbolic" : "media-playlist-no-repeat-symbolic"
  readonly property string loopTooltip: loopState === MprisLoopState.Track ? "Repeat: current song"
    : loopState === MprisLoopState.Playlist ? "Repeat: playlist" : "Repeat: off"

  // MPRIS metadata comes from whatever local player claims the "deezer"
  // identity/desktop-entry, so treat title/artist/album as untrusted text.
  // Every Text item we render it in is forced to Text.PlainText below,
  // which alone is enough to stop markup interpretation there - but the
  // shared bar tooltip defaults to AutoText and we can't change that from
  // here, so strip the angle brackets that its rich-text sniffing keys off
  // of. Plain characters like "&" are left untouched (real artist names
  // use them) since HTML-escaping them would only matter if something
  // downstream decoded entities, which nothing here does.
  function plainText(s) {
    return String(s || "").replace(/[<>]/g, "")
  }

  // The real Deezer app serves art from its own CDN over https (verified
  // live via busctl: cdn-images.dzcdn.net) and never sends file:// URLs,
  // so file:// is rejected outright rather than trusted - a rogue
  // "deezer"-identified local process could otherwise point this at an
  // arbitrary local path. Scope https to Deezer's actual CDN domain
  // (anchored, so a suffix like "dzcdn.net.evil.com" or userinfo tricks
  // like "dzcdn.net@evil.com" can't sneak past it).
  function safeArtUrl(url) {
    var s = String(url || "").trim()
    return /^https:\/\/([a-z0-9-]+\.)*dzcdn\.net\//i.test(s) ? s : ""
  }

  // Downloads the candidate art URL into a fresh, exclusively-created local
  // file (curl's own --max-filesize aborts the transfer itself if it grows
  // past the cap, unlike a HEAD Content-Length check) and only lets the
  // Image element see the local file once its on-disk size is reverified.
  // Fails closed at every step: not ready yet, or a missing dir/mktemp/curl/
  // stat failure, or an oversized result, all leave verifiedArtUrl empty,
  // which falls back to the placeholder icon.
  onArtUrlChanged: {
    wantedArtUrl = artUrl
    if (wantedArtUrl !== verifiedForUrl) verifiedArtUrl = ""
    else if (verifiedArtUrl) return // already showing verified art for this exact url
    if (mktempProc.running || artDownloadProc.running || artStatProc.running) {
      // A chain for the previous url is still in flight. Terminate it and
      // let artStageFinished() notice the mismatch once it actually stops -
      // see the comment there for why this can't just be raced past.
      if (mktempProc.running) mktempProc.running = false
      if (artDownloadProc.running) artDownloadProc.running = false
      if (artStatProc.running) artStatProc.running = false
    } else {
      startArtDownload()
    }
  }

  function startArtDownload() {
    if (runningArtUrl || !wantedArtUrl || !artCacheReady) return
    runningArtUrl = wantedArtUrl
    mktempProc.command = ["mktemp", artCacheDir + "/art-XXXXXX"]
    mktempProc.running = true
  }

  // mktemp/curl/stat are a single reused Process trio, not one spawned per
  // track change, so a stage's onExited can't just compare "is this url
  // still current" against a property that a newer call may have already
  // overwritten by the time a *terminated* old process's exited() fires
  // (QProcess still emits it on termination). runningArtUrl is instead only
  // ever cleared here, at actual completion, so this comparison is safe;
  // a mismatch means the chain that just finished was cancelled mid-flight
  // and its result must be discarded, with a fresh chain started for
  // whatever url is current now.
  function artStageFinished() {
    var forUrl = runningArtUrl
    runningArtUrl = ""
    return forUrl === wantedArtUrl
  }

  function rmCacheFile(path) {
    if (!path) return
    artCleanupProc.command = ["rm", "-f", "--", path]
    artCleanupProc.running = true
  }

  Process { id: artCleanupProc }

  // Wiped and recreated on every widget startup so files left by a prior,
  // possibly ungracefully-killed session never linger, and so a pre-existing
  // symlink at this path can't redirect our writes elsewhere.
  Process {
    id: artCacheInitProc
    command: ["sh", "-c", "rm -rf -- \"$0\" && mkdir -p -- \"$0\"", root.artCacheDir]
    onExited: function(code) {
      if (!root) return
      root.artCacheReady = true
      root.startArtDownload()
    }
  }

  Process {
    id: mktempProc
    stdout: StdioCollector { id: mktempOut; waitForEnd: true }
    onExited: function(code) {
      if (!root) return
      var path = String(mktempOut.text || "").trim()
      if (!root.artStageFinished()) { root.rmCacheFile(path); root.startArtDownload(); return }
      if (code !== 0 || !path) { root.verifiedArtUrl = ""; root.startArtDownload(); return }
      root.activeTempPath = path
      root.runningArtUrl = root.wantedArtUrl
      // No -L: the art host is anchored to *.dzcdn.net above, and following
      // a redirect would hand that trust to whatever host it points at.
      artDownloadProc.command = ["curl", "-fsS", "--max-time", "20", "--proto", "=https",
        "--max-filesize", String(root.maxArtBytes), "--output", path, root.wantedArtUrl]
      artDownloadProc.running = true
    }
  }

  Process {
    id: artDownloadProc
    onExited: function(code) {
      if (!root) return
      var path = root.activeTempPath
      root.activeTempPath = ""
      if (!root.artStageFinished()) { root.rmCacheFile(path); root.startArtDownload(); return }
      if (code !== 0) { root.rmCacheFile(path); root.verifiedArtUrl = ""; root.startArtDownload(); return }
      root.activeTempPath = path
      root.runningArtUrl = root.wantedArtUrl
      artStatProc.command = ["stat", "-c", "%s", path]
      artStatProc.running = true
    }
  }

  Process {
    id: artStatProc
    stdout: StdioCollector { id: artStatOut; waitForEnd: true }
    onExited: function(code) {
      if (!root) return
      var path = root.activeTempPath
      root.activeTempPath = ""
      var matched = root.artStageFinished()
      var size = parseInt(String(artStatOut.text || "").trim(), 10)
      if (matched && code === 0 && !isNaN(size) && size > 0 && size <= root.maxArtBytes) {
        if (root.lastGoodArtPath && root.lastGoodArtPath !== path) root.rmCacheFile(root.lastGoodArtPath)
        root.lastGoodArtPath = path
        root.verifiedForUrl = root.wantedArtUrl
        root.verifiedArtUrl = "file://" + path
      } else {
        root.rmCacheFile(path)
        if (matched) root.verifiedArtUrl = ""
      }
      if (!matched) root.startArtDownload()
    }
  }

  function findDeezerPlayer() {
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      var entry = (p.desktopEntry || "").toLowerCase()
      var identity = (p.identity || "").toLowerCase()
      if (entry.indexOf("deezer") !== -1 || identity.indexOf("deezer") !== -1) return p
    }
    return null
  }

  function close() {
    popupOpen = false
    settingsOpen = false
  }

  // MPRIS doesn't push position updates on its own; this is Quickshell's
  // documented way to make a bound UI (the seek bar) refresh anyway.
  Timer {
    interval: 1000
    repeat: true
    running: root.active && root.player.isPlaying && root.popupOpen
    onTriggered: root.player.positionChanged()
  }

  // Every icon choice is a real icon-theme lookup, tinted white via the same
  // technique the tray uses for its own icons (render offscreen, colorize).
  // "logo" is the real multi-color app icon; "text" replaces the bar content
  // entirely instead of showing an icon.
  readonly property var iconChoices: [
    { key: "logo", label: "Deezer logo", iconName: "deezer-desktop", symbolic: false },
    { key: "headphones", label: "Headphones", iconName: "audio-headphones-symbolic", symbolic: true },
    { key: "note", label: "Music note", iconName: "music-note-symbolic", symbolic: true },
    { key: "speaker", label: "Speaker", iconName: "audio-speakers-symbolic", symbolic: true },
    { key: "playlist", label: "Playlist", iconName: "playlist-symbolic", symbolic: true },
    { key: "text", label: "Title + artist" }
  ]
  readonly property string settingIconChoice: {
    var v = setting("icon", "logo")
    for (var i = 0; i < iconChoices.length; i++) if (iconChoices[i].key === v) return v
    return "logo"
  }
  readonly property var currentIconChoice: {
    for (var i = 0; i < iconChoices.length; i++) if (iconChoices[i].key === settingIconChoice) return iconChoices[i]
    return iconChoices[0]
  }
  readonly property bool iconIsText: settingIconChoice === "text"
  // Text mode only replaces the bar; header/placeholder fall back to the logo.
  readonly property var imageIconChoice: iconIsText ? iconChoices[0] : currentIconChoice
  readonly property bool iconIsSymbolic: imageIconChoice.symbolic === true
  readonly property string currentIconSource: Quickshell.iconPath(imageIconChoice.iconName, true)

  // Renders normally when the icon carries its own colors, or offscreen +
  // recolored flat when it's a symbolic icon meant to be tinted.
  component DeezerIcon: Item {
    id: iconRoot
    required property bool symbolic
    required property string source
    required property color tint
    property real opacity01: 1.0

    Behavior on opacity01 {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      NumberAnimation { duration: 160 }
    }

    Image {
      id: iconImage
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      // Sync decode: Quickshell's image://icon provider drops concurrent
      // async requests more often than not, leaving icons stuck loading.
      asynchronous: false
      source: iconRoot.source
      sourceSize.width: Math.round(width * Screen.devicePixelRatio)
      sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      visible: !iconRoot.symbolic
      layer.enabled: iconRoot.symbolic
      opacity: iconRoot.opacity01
    }

    MultiEffect {
      anchors.fill: iconImage
      source: iconImage
      visible: iconRoot.symbolic
      colorization: 1.0
      colorizationColor: iconRoot.tint
      brightness: 1.0 // colorization alone still leans on source shading; this forces a flat tint
      opacity: iconRoot.opacity01
    }
  }

  // Small icon-only toggle button, shared by shuffle and repeat.
  component DeezerToggleButton: BorderSurface {
    id: toggleRoot
    required property string iconName
    property bool highlighted: false
    property color highlightColor: root.accentColor2
    property bool supported: true
    property string tooltip: ""
    signal activated()

    width: Style.space(28)
    height: Style.space(28)
    radius: root.tileRadius
    color: highlighted ? Style.selectedFillFor(root.bar.foreground, highlightColor) : "transparent"
    borderSpec: Border.none()
    opacity: supported ? 1.0 : 0.4

    DeezerIcon {
      anchors.centerIn: parent
      width: Style.font.body
      height: Style.font.body
      symbolic: true
      source: Quickshell.iconPath(toggleRoot.iconName, true)
      tint: "white"
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: toggleRoot.supported ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: toggleRoot.activated()
      onEntered: if (root.bar) root.bar.showTooltip(toggleRoot, toggleRoot.tooltip)
      onExited: if (root.bar) root.bar.hideTooltip(toggleRoot)
    }
  }

  // Dominant colors of the current wallpaper, most common first. Every
  // accent in the popup pulls from this instead of the theme's static
  // Color.accent, and re-extracts whenever the wallpaper changes.
  readonly property var backgroundService: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.background") : null
  readonly property string backgroundPath: backgroundService ? backgroundService.currentBackground : ""
  property var paletteColors: []

  // Raw histogram colors are often shadow-black or highlight-white; keep the
  // hue but clamp lightness/saturation into a legible band.
  function legibleAccent(c) {
    var l = Math.max(0.42, Math.min(0.72, c.hslLightness))
    var s = Math.max(c.hslSaturation, 0.35)
    return Qt.hsla(c.hslHue, s, l, 1.0)
  }

  readonly property color accentColor: paletteColors.length > 0 ? legibleAccent(paletteColors[0]) : Color.accent
  readonly property color accentColor2: paletteColors.length > 1 ? legibleAccent(paletteColors[1]) : accentColor
  readonly property color accentColor3: paletteColors.length > 2 ? legibleAccent(paletteColors[2]) : accentColor2

  // Text brightness flips to stay legible whether the popup background ends
  // up dark or light (transparency/tint can push it either way).
  readonly property real popupBgLightness: popup ? popup.backgroundColor.hslLightness : 0.15
  readonly property bool darkPopupBg: popupBgLightness < 0.5

  function textTone(weight, hue) {
    var h = hue === undefined ? accentColor.hslHue : hue
    var light = darkPopupBg
      ? (weight === 1 ? 0.94 : weight === 2 ? 0.82 : 0.68)
      : (weight === 1 ? 0.12 : weight === 2 ? 0.24 : 0.36)
    return Qt.hsla(h, 0.18, light, 1.0)
  }

  readonly property color textPrimary: textTone(1)
  readonly property color textSecondary: textTone(2)
  readonly property color textTertiary: textTone(3)
  readonly property color textMuted: Qt.hsla(0, 0.03, darkPopupBg ? 0.62 : 0.42, 1.0)

  // For an icon on a solid accent-filled surface (the play button).
  function contrastOn(bg) {
    return bg.hslLightness > 0.58 ? Qt.hsla(0, 0, 0.08, 1) : Qt.hsla(0, 0, 0.98, 1)
  }

  function extractPalette() {
    if (!backgroundPath) return
    paletteProc.command = ["magick", backgroundPath, "-resize", "150x150", "-colors", "5", "+dither", "-depth", "8", "-format", "%c", "histogram:info:-"]
    paletteProc.running = true
  }

  function parsePalette(text) {
    var lines = String(text || "").split("\n")
    var entries = []
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*(\d+):\s*\([^)]*\)\s*(#[0-9A-Fa-f]{6,8})/)
      if (m) entries.push({ count: parseInt(m[1], 10), hex: m[2].substring(0, 7) })
    }
    entries.sort(function(a, b) { return b.count - a.count })
    var seen = {}
    var result = []
    for (var j = 0; j < entries.length && result.length < 5; j++) {
      if (seen[entries[j].hex]) continue
      seen[entries[j].hex] = true
      result.push(Qt.color(entries[j].hex))
    }
    if (result.length > 0) paletteColors = result
  }

  Process {
    id: paletteProc
    stdout: StdioCollector {
      id: paletteOutput
      onStreamFinished: root.parsePalette(paletteOutput.text)
    }
  }

  onBackgroundPathChanged: extractPalette()

  // The 4 tunable popup settings: key, label, and slider range. Single
  // source of truth for the settings sliders, relive(), and resetSettings().
  readonly property var sliderDefs: [
    { key: "blur", label: "Blur", from: 0, to: 100, def: 40 },
    { key: "transparency", label: "Transparency", from: 0, to: 100, def: 40 },
    { key: "borderWidth", label: "Outline thickness", from: 0, to: 6, def: 2 },
    { key: "cornerRadius", label: "Corner roundness", from: 0, to: 20, def: 2 }
  ]

  function liveKey(key) { return "live" + key.charAt(0).toUpperCase() + key.slice(1) }
  function settingKey(key) { return "setting" + key.charAt(0).toUpperCase() + key.slice(1) }

  readonly property int settingBlur: clampInt(setting("blur", 40), 40, 0, 100)
  readonly property int settingTransparency: clampInt(setting("transparency", 40), 40, 0, 100)
  readonly property int settingBorderWidth: clampInt(setting("borderWidth", 2), 2, 0, 6)
  readonly property int settingCornerRadius: clampInt(setting("cornerRadius", 2), 2, 0, 20)

  // Mirrors of the persisted settings, updated continuously while a slider
  // drags (for instant visual feedback with no disk writes) and re-bound to
  // the persisted value once the drag commits.
  property int liveBlur: settingBlur
  property int liveTransparency: settingTransparency
  property int liveBorderWidth: settingBorderWidth
  property int liveCornerRadius: settingCornerRadius

  // Inner chrome (art frame, icon tiles, toggle buttons) keeps its own small
  // rounding always, independent of the corner-roundness slider - that slider
  // only reshapes the popup card itself, so small elements never get pushed
  // toward looking circular at the slider's higher end.
  readonly property int tileRadius: Style.space(4)

  function relive(key) {
    var lk = liveKey(key), sk = settingKey(key)
    root[lk] = Qt.binding(function() { return root[sk] })
  }

  function clampInt(value, fallback, min, max) {
    var n = Number(value)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, Math.round(n)))
  }

  function persist(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) {
      if (k !== "id") entry[k] = root.settings[k]
    }
    entry[key] = value
    root.settings = entry
    root.settingsDirty = true
    root.relive(key)
  }

  function resetSettings() {
    var entry = { id: root.moduleName, icon: "logo" }
    for (var i = 0; i < sliderDefs.length; i++) entry[sliderDefs[i].key] = sliderDefs[i].def
    root.settings = entry
    root.settingsDirty = true
    for (var j = 0; j < sliderDefs.length; j++) root.relive(sliderDefs[j].key)
  }

  // No per-plugin reload primitive exists, only this shell-wide one — the
  // "did you turn it off and on again" fix if state ever gets stuck.
  function reloadPlugin() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.reloadPlugins === "function")
      root.bar.shell.reloadPlugins()
  }

  function applyBlur() {
    var size = Math.round(root.liveBlur / 100 * 20)
    blurProc.command = ["hyprctl", "eval", "hl.config({decoration={blur={size=" + size + "}}})"]
    blurProc.running = true
  }

  Process {
    id: blurProc
  }

  onLiveBlurChanged: applyBlur()
  Component.onCompleted: {
    applyBlur()
    extractPalette()
    artCacheInitProc.running = true
    debugOpenTimer.start()
  }
  Timer { id: debugOpenTimer; interval: 600; onTriggered: root.popupOpen = true }

  // A shell.json write reloads the plugin registry shell-wide (not just this
  // widget), which tears down and recreates this Item mid-interaction -
  // closing the popup, since a fresh instance starts with popupOpen: false.
  // Writing on every slider release/click was doing that constantly. Instead,
  // settings changes only update local/live state immediately (still fully
  // responsive) and the actual disk write is deferred until the popup closes,
  // so the reload happens after there's nothing visible left to interrupt.
  property bool settingsDirty: false
  onPopupOpenChanged: if (!popupOpen) flushSettings()
  Component.onDestruction: {
    flushSettings()
    if (mktempProc.running) mktempProc.running = false
    if (artDownloadProc.running) artDownloadProc.running = false
    if (artStatProc.running) artStatProc.running = false
    rmCacheFile(activeTempPath)
    rmCacheFile(lastGoodArtPath)
  }

  function flushSettings() {
    if (!root.settingsDirty) return
    root.settingsDirty = false
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  readonly property real maxBarTextWidth: Style.space(180)

  visible: active
  implicitWidth: {
    if (!active) return 0
    if (iconIsText) return Math.min(maxBarTextWidth, barTextLabel.implicitWidth) + Style.space(10)
    return barSize
  }
  implicitHeight: barSize

  DeezerIcon {
    id: logo
    visible: !root.iconIsText
    anchors.centerIn: parent
    width: Style.space(12) // matches the tray's own icon size
    height: Style.space(12)
    symbolic: root.iconIsSymbolic
    source: root.currentIconSource
    tint: "white"
    opacity01: root.active && root.player.isPlaying ? 1.0 : 0.55
  }

  Item {
    id: barTextClip
    visible: root.iconIsText
    anchors.fill: parent
    clip: true

    Text {
      id: barTextLabel
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.title ? (root.title + (root.artist ? "  ·  " + root.artist : "")) : "Deezer"
      color: root.bar.barForeground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      opacity: root.active && root.player.isPlaying ? 1.0 : 0.55

      property bool needsScroll: implicitWidth > barTextClip.width

      Behavior on opacity {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        NumberAnimation { duration: 160 }
      }

      NumberAnimation on x {
        running: barTextLabel.needsScroll && root.iconIsText && !root.bar.vertical
        loops: Animation.Infinite
        duration: Math.max(6000, barTextLabel.implicitWidth * 25)
        from: barTextClip.width
        to: -barTextLabel.implicitWidth
        easing.type: Easing.Linear
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton

    onClicked: {
      if (!root.active) return
      root.popupOpen = !root.popupOpen
      if (!root.popupOpen) root.settingsOpen = false
    }

    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasTrack ? (root.title + (root.artist ? " — " + root.artist : "")) : "Deezer")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  DeezerPopup {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)
    backgroundAlpha: 1 - root.liveTransparency / 100
    cornerRadius: Style.space(root.liveCornerRadius)
    borderWidth: Style.space(root.liveBorderWidth)
    backgroundColor: Qt.tint(Util.alpha(Color.popups.background, backgroundAlpha), Util.alpha(root.accentColor, 0.12))
    borderColor: Qt.tint(Color.popups.border, Util.alpha(root.accentColor, 0.35))

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.spacing.lg

      Item {
        width: parent.width
        height: Math.max(headerLogo.height, headerTitle.height, headerStatus.height, gearButton.height)

        Row {
          id: headerLeft
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md

          DeezerIcon {
            id: headerLogo
            width: Style.font.icon
            height: Style.font.icon
            anchors.verticalCenter: parent.verticalCenter
            symbolic: root.iconIsSymbolic
            source: root.currentIconSource
            tint: "white"
          }

          Text {
            id: headerTitle
            text: "Deezer"
            anchors.verticalCenter: parent.verticalCenter
            color: root.textPrimary
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
        }

        Text {
          id: headerStatus
          anchors.right: gearButton.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          text: root.active ? (root.player.isPlaying ? "Playing" : "Paused") : "Not running"
          color: root.active && root.player.isPlaying ? root.textSecondary : root.textMuted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          id: gearButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: String.fromCodePoint(0xF0493)
          tooltipText: root.settingsOpen ? "Back" : "Widget settings"
          foreground: root.bar.foreground
          accent: root.accentColor2
          selected: root.settingsOpen
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.body
          onClicked: root.settingsOpen = !root.settingsOpen
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
      }

      Row {
        visible: !root.settingsOpen
        spacing: Style.spacing.xl
        width: parent.width

        BorderSurface {
          id: artFrame
          width: Style.space(68)
          height: Style.space(68)
          radius: root.tileRadius
          color: Style.normalFillFor(root.bar.foreground, root.accentColor)
          borderSpec: Border.flat(
            root.active && root.player.isPlaying ? root.accentColor : Style.normalBorderFor(root.bar.foreground, root.accentColor),
            popup.borderWidth)

          // Accent-tinted glow while playing, as a "now playing" cue.
          layer.enabled: root.active && root.player.isPlaying
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: root.accentColor
            shadowBlur: 0.7
            shadowOpacity: 0.5
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 0
          }

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.verifiedArtUrl
            sourceSize.width: Style.space(136)
            sourceSize.height: Style.space(136)
            visible: source !== ""
          }

          DeezerIcon {
            anchors.centerIn: parent
            width: Style.space(28)
            height: Style.space(28)
            symbolic: root.iconIsSymbolic
            source: root.currentIconSource
            tint: "white"
            opacity01: 0.5
            visible: root.verifiedArtUrl === ""
          }
        }

        Column {
          spacing: Style.spacing.labelGap
          width: parent.width - Style.space(68) - Style.spacing.xl
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: root.title || "Nothing playing"
            color: root.textPrimary
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.artist
            color: root.textSecondary
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            textFormat: Text.PlainText
            text: root.album
            color: root.textTertiary
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      DeezerSeekBar {
        width: parent.width
        visible: !root.settingsOpen && root.showSeekBar
        position: root.active ? root.player.position : 0
        duration: root.trackDuration
        seekable: root.canSeek
        trackColor: root.textTertiary
        labelColor: root.textTertiary
        accent: root.accentColor
        onSeek: function(seconds) { if (root.canSeek) root.player.position = seconds }
      }

      Row {
        visible: !root.settingsOpen
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.md

        DeezerToggleButton {
          iconName: "media-playlist-shuffle-symbolic"
          highlighted: root.shuffleOn
          highlightColor: root.accentColor3
          supported: root.shuffleSupported
          tooltip: root.shuffleOn ? "Shuffle on" : "Shuffle off"
          onActivated: root.toggleShuffle()
        }

        Button {
          iconText: "󰒮"
          foreground: root.bar.foreground
          accent: root.accentColor3
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.active && root.player.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.active && root.player.canGoPrevious) root.player.previous()
        }

        BorderSurface {
          id: playButton
          readonly property bool playEnabled: root.active && (root.player.canTogglePlaying || root.player.canPlay || root.player.canPause)

          width: Style.space(38)
          height: Style.space(38)
          radius: width / 2
          color: root.accentColor
          borderSpec: Border.none()
          opacity: playEnabled ? 1.0 : 0.4
          scale: playMouseArea.pressed ? 0.92 : (playMouseArea.containsMouse ? 1.05 : 1.0)

          Behavior on scale {
            NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
          }

          Text {
            anchors.centerIn: parent
            // Optical centering: the play triangle reads left-of-center otherwise.
            anchors.horizontalCenterOffset: root.active && root.player.isPlaying ? 0 : Style.space(1)
            text: root.playIcon
            color: root.contrastOn(root.accentColor)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.iconLarge
          }

          MouseArea {
            id: playMouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: playButton.playEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              if (!root.active) return
              if (root.player.canTogglePlaying) root.player.togglePlaying()
              else if (root.player.isPlaying && root.player.canPause) root.player.pause()
              else if (!root.player.isPlaying && root.player.canPlay) root.player.play()
            }
          }
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar.foreground
          accent: root.accentColor3
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.active && root.player.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.active && root.player.canGoNext) root.player.next()
        }

        DeezerToggleButton {
          iconName: root.loopIconName
          highlighted: root.loopState !== MprisLoopState.None
          highlightColor: root.accentColor2
          supported: root.loopSupported
          tooltip: root.loopTooltip
          onActivated: root.cycleLoop()
        }
      }

      Column {
        visible: root.settingsOpen
        width: parent.width
        spacing: Style.spacing.lg

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Text {
            text: "Icon"
            color: root.textTertiary
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.spacing.md

            Repeater {
              model: root.iconChoices

              BorderSurface {
                id: iconTile
                required property var modelData
                readonly property bool chosen: root.settingIconChoice === modelData.key

                width: Style.space(36)
                height: Style.space(36)
                radius: root.tileRadius
                color: chosen ? Style.selectedFillFor(root.bar.foreground, root.accentColor) : Style.normalFillFor(root.bar.foreground, root.accentColor)
                borderSpec: chosen
                  ? Border.flat(root.accentColor, Style.space(2))
                  : Border.controlSpec("normal", root.bar.foreground, root.accentColor)

                DeezerIcon {
                  visible: iconTile.modelData.key !== "text"
                  anchors.centerIn: parent
                  width: Style.space(20)
                  height: Style.space(20)
                  symbolic: iconTile.modelData.symbolic === true
                  source: Quickshell.iconPath(iconTile.modelData.iconName, true)
                  tint: "white"
                }

                Text {
                  visible: iconTile.modelData.key === "text"
                  anchors.centerIn: parent
                  text: "Aa"
                  color: "white"
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.persist("icon", iconTile.modelData.key)
                  onEntered: if (root.bar) root.bar.showTooltip(iconTile, iconTile.modelData.label)
                  onExited: if (root.bar) root.bar.hideTooltip(iconTile)
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Repeater {
          model: root.sliderDefs

          DeezerSlider {
            id: sliderDelegate
            required property var modelData

            width: parent.width
            label: modelData.label
            labelColor: root.textTertiary
            valueColor: root.textSecondary
            accent: root.accentColor
            from: modelData.from
            to: modelData.to
            value: root[root.liveKey(modelData.key)]
            onLive: function(value) { root[root.liveKey(sliderDelegate.modelData.key)] = value }
            onModified: function(value) { root.persist(sliderDelegate.modelData.key, value) }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Button {
          width: parent.width
          radius: root.tileRadius
          text: "Reset to defaults"
          tooltipText: "Icon, blur, transparency, outline, and corner roundness back to their defaults"
          bordered: true
          foreground: root.textSecondary
          accent: root.accentColor
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.resetSettings()
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Button {
          width: parent.width
          radius: root.tileRadius
          text: "Reload plugin"
          iconText: String.fromCodePoint(0xF0450)
          tooltipText: "Fully reload if something looks stuck"
          bordered: true
          foreground: root.textSecondary
          accent: root.accentColor
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.reloadPlugin()
        }
      }
    }
  }
}
