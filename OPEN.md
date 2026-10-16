# Open items

Known gaps in Canvas Viewer, newest first. The README's **Limits** section says
what a reader sees; this file says what is left to do.

- **Embedded images are boxes.** Excalidraw stores them as base64 in the file's
  `files`; tldraw stores them in asset records. Neither is decoded. Drawing one
  would need either a raster `image` blob per picture (Tern decodes PNG, JPEG,
  GIF and WebP up to 4096 px a side) or an `<image href="data:…">` inside the
  SVG, which the 256 KiB blob limit makes unusable beyond a thumbnail.
- **Text is not clipped to its container.** An Excalidraw label wider than its
  container spills over the edge; a bound text element is drawn at its own
  `width`, not clipped to the container's box. `<clipPath>` support in Tern's
  SVG renderer has not been measured.
- **Hatching is a wash.** `hachure`, `cross-hatch` and `zigzag` fills (and
  tldraw's `pattern`) draw as the fill colour at low opacity.
- **Excalidraw's roughness is ignored.** Every stroke is smooth; the hand-drawn
  jitter `roughness > 0` asks for is not reproduced.
- **tldraw arrow bindings are ignored.** Endpoints come from `props.start` and
  `props.end`; a `binding` record that moved an end onto a shape's edge is not
  applied, so a bound arrow can stop at the point the file last stored.
- **tldraw elbow arrows are drawn as bent arcs.** `kind: "elbow"` and
  `elbowMidPoint` are not honoured.
- **tldraw `highlight` is drawn as `draw`.** Its highlighter width and opacity
  are not tuned.
- **A dark-theme tldraw drawing renders in the light palette.** The file does
  not record the theme it was drawn in; there is no switch to pick one.
- **A native whiteboard could hold these scenes instead of a picture.** Tern
  0.8.4 exposes an undocumented window-only `cx.whiteboard` (`open`, `read`,
  `edit`) over the canvas blocks of kind `canvas`, with shapes for rect,
  ellipse, diamond, triangle, text, arrow, line, polygon, curve, ink,
  highlight, image and group. Converting a scene into whiteboard edits would
  make these files editable in Tern and give an export path back out. The API
  is not in the published book, so it may change under the plugin.
- **No automated test run.** `tests/sample.excalidraw` and
  `tests/sample.tldraw` are rendered by hand through a linked plugin and a
  headless Tern window; nothing asserts the output yet.