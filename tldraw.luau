--!strict
-- Reads a tldraw document (the `.tldraw` JSON `getSnapshot`/file save writes:
-- `tldrawFileFormatVersion` plus `records`) into the shared vocabulary.
--
-- Records follow tldraw's schema: a `page` record per page, `shape` records
-- with `type`, `x`, `y`, `rotation` (radians), `opacity`, `parentId` and an
-- `index` that orders them, and per-type `props`
-- (packages/tlschema/src/shapes/*.ts). `richText` holds a small ProseMirror
-- document; `draw` strokes and `scale`/`scaleX`/`scaleY` follow
-- packages/tlschema/src/misc/b64Vecs.ts, decoded in `vecs.luau`.
--
-- Colours are the light palette of `DEFAULT_THEME`
-- (packages/editor/src/lib/editor/managers/ThemeManager/defaultThemes.ts): a
-- file names colours, the theme decides what they look like, and a file does
-- not record which theme it was drawn in.

local scene = require("./scene")
local vecs = require("./vecs")

local M = {}

export type Info = {
	shapes: { scene.Shape },
	background: string?,
	count: number,
	notes: { string },
}

type Palette = { solid: string, semi: string, pattern: string, noteFill: string, frameStroke: string, frameFill: string }

local PALETTE: { [string]: Palette } = {
	black = {
		solid = "#1d1d1d",
		semi = "#e8e8e8",
		pattern = "#494949",
		noteFill = "#FCE19C",
		frameStroke = "#717171",
		frameFill = "#ffffff",
	},
	blue = {
		solid = "#4465e9",
		semi = "#dce1f8",
		pattern = "#6681ee",
		noteFill = "#8AA3FF",
		frameStroke = "#6681ec",
		frameFill = "#f9fafe",
	},
	green = {
		solid = "#099268",
		semi = "#d3e9e3",
		pattern = "#39a785",
		noteFill = "#6FC896",
		frameStroke = "#37a684",
		frameFill = "#f8fcfa",
	},
	grey = {
		solid = "#9fa8b2",
		semi = "#eceef0",
		pattern = "#bcc3c9",
		noteFill = "#C0CAD3",
		frameStroke = "#aaaaab",
		frameFill = "#fcfcfd",
	},
	["light-blue"] = {
		solid = "#4ba1f1",
		semi = "#ddedfa",
		pattern = "#6fbbf8",
		noteFill = "#9BC4FD",
		frameStroke = "#6cb2f3",
		frameFill = "#fafcff",
	},
	["light-green"] = {
		solid = "#4cb05e",
		semi = "#dbf0e0",
		pattern = "#65cb78",
		noteFill = "#98D08A",
		frameStroke = "#6dbe7c",
		frameFill = "#fafdfa",
	},
	["light-red"] = {
		solid = "#f87777",
		semi = "#f4dadb",
		pattern = "#fe9e9e",
		noteFill = "#F7A5A1",
		frameStroke = "#f89090",
		frameFill = "#fffbfb",
	},
	["light-violet"] = {
		solid = "#e085f4",
		semi = "#f5eafa",
		pattern = "#e9acf8",
		noteFill = "#DFB0F9",
		frameStroke = "#e59bf5",
		frameFill = "#fefbff",
	},
	orange = {
		solid = "#e16919",
		semi = "#f8e2d4",
		pattern = "#f78438",
		noteFill = "#FAA475",
		frameStroke = "#e68544",
		frameFill = "#fef9f6",
	},
	red = {
		solid = "#e03131",
		semi = "#f4dadb",
		pattern = "#e55959",
		noteFill = "#FC8282",
		frameStroke = "#e55757",
		frameFill = "#fef9f9",
	},
	violet = {
		solid = "#ae3ec9",
		semi = "#ecdcf2",
		pattern = "#bd63d3",
		noteFill = "#DB91FD",
		frameStroke = "#bc62d3",
		frameFill = "#fdf9fd",
	},
	yellow = {
		solid = "#f1ac4b",
		semi = "#f9f0e6",
		pattern = "#fecb92",
		noteFill = "#FED49A",
		frameStroke = "#f3bb6c",
		frameFill = "#fffdfa",
	},
	white = {
		solid = "#FFFFFF",
		semi = "#f5f5f5",
		pattern = "#f9f9f9",
		noteFill = "#FFFFFF",
		frameStroke = "#7d7d7d",
		frameFill = "#ffffff",
	},
}

-- tldraw's light canvas background (DEFAULT_THEME.colors.light.background).
local BACKGROUND = "#f8f8f8"

-- default-shape-constants.ts: stroke widths and font sizes, the latter as the
-- theme's 16px base times the per-size multiplier.
local STROKE: { [string]: number } = { s = 1, m = 1.75, l = 2.5, xl = 5 }
local FONT_SIZE: { [string]: number } = { s = 18, m = 24, l = 36, xl = 44 }
local LABEL_FONT_SIZE: { [string]: number } = { s = 18, m = 22, l = 26, xl = 32 }
local FONT_FAMILY: { [string]: string } = {
	draw = "sans-serif",
	sans = "sans-serif",
	serif = "serif",
	mono = "ui-monospace, monospace",
}
local SIZE_ORDER: { [string]: number } = { s = 1, m = 2, l = 3, xl = 4 }

local function number(v: any, fallback: number): number
	local n = tonumber(v)
	return if n == nil then fallback else n
end

local function palette(name: any): Palette
	return PALETTE[tostring(name)] or PALETTE.black
end

local function width_of(size: any): number
	return STROKE[tostring(size)] or STROKE.m
end

local function stroke_of(props: { [string]: any }): string
	return palette(props.color).solid
end

--- The fill a shape's `fill` style asks for: the palette variant the theme
--- paints with, or nothing at all.
local function fill_of(props: { [string]: any }, kind: string?): (string?, number?)
	local p = palette(props.color)
	local fill = tostring(props.fill)
	local variant = if kind == "note" then p.noteFill
		elseif fill == "semi" then p.semi
		elseif fill == "pattern" then p.pattern
		elseif fill == "solid" then p.solid
		else nil
	if variant == nil then
		return nil, nil
	end
	return variant, 1
end

local function dash_of(props: { [string]: any }): string?
	local dash = tostring(props.dash)
	if dash == "dashed" or dash == "dotted" then
		return dash
	end
	return nil
end

local function style_of(
	rec: { [string]: any },
	props: { [string]: any },
	kind: string?
): scene.Style
	local fill, fill_opacity = fill_of(props, kind)
	return {
		stroke = stroke_of(props),
		fill = fill,
		fill_opacity = fill_opacity,
		width = width_of(props.size),
		dash = dash_of(props),
		opacity = number(rec.opacity, 1),
	}
end

--- The plain text of a ProseMirror `richText` document, one string per
--- paragraph. Plain strings (older files) come back as they are.
local function rich_text(raw: any): { string }
	local doc: any = nil
	if type(raw) == "table" then
		-- A store snapshot keeps `richText` decoded.
		doc = raw
	elseif type(raw) == "string" and raw ~= "" then
		local ok, decoded = pcall(tern.json.decode, raw)
		doc = if ok then decoded else nil
		if doc == nil then
			return { raw }
		end
	end
	if type(doc) ~= "table" then
		return {}
	end
	local function collect(node: any, out: { string })
		if type(node) ~= "table" then
			return
		end
		if type(node.text) == "string" then
			table.insert(out, node.text)
		end
		if type(node.content) == "table" then
			for _, child in ipairs(node.content) do
				collect(child, out)
			end
		end
	end
	local lines = {}
	local content = doc.content
	if type(content) == "table" then
		for _, para in ipairs(content) do
			local parts: { string } = {}
			collect(para, parts)
			table.insert(lines, table.concat(parts))
		end
	end
	if #lines == 0 then
		return { raw }
	end
	return lines
end

local function text_node(
	rec: { [string]: any },
	lines: { string },
	x: number,
	y: number,
	w: number,
	h: number,
	size: number,
	props: { [string]: any },
	color: string,
	anchor: string
): scene.Shape?
	if #lines == 0 then
		return nil
	end
	return {
		kind = "text",
		x = x,
		y = y,
		w = w,
		h = h,
		lines = lines,
		size = size,
		color = color,
		anchor = anchor,
		family = FONT_FAMILY[tostring(props.font)] or "sans-serif",
		angle = math.deg(number(rec.rotation, 0)),
	}
end

local ANCHORS: { [string]: string } = {
	start = "start",
	["middle"] = "middle",
	["end"] = "end",
}

local function anchor_of(value: any): string
	return ANCHORS[tostring(value)] or "start"
end

--- Draws a label inside a box the way tldraw places it: `padding` on the
--- sides, aligned horizontally and vertically.
local function label_inside(
	shapes: { scene.Shape },
	rec: { [string]: any },
	props: { [string]: any },
	x: number,
	y: number,
	w: number,
	h: number,
	pad: number,
	font_sizes: { [string]: number }
)
	local lines = rich_text(props.richText)
	if #lines == 0 then
		return
	end
	local size = font_sizes[tostring(props.size)] or font_sizes.m
	local inner_x, inner_w = x + pad, math.max(w - pad * 2, 1)
	local inner_y, inner_h = y + pad, math.max(h - pad * 2, 1)
	local node = text_node(
		rec,
		lines,
		inner_x,
		inner_y,
		inner_w,
		inner_h,
		size,
		props,
		palette(props.labelColor).solid,
		anchor_of(props.align)
	)
	if node ~= nil then
		table.insert(shapes, node)
	end
end

--- One arrowhead at `tip`, pointing away from `from`.
local function arrowhead(
	kind: string,
	tip: { number },
	from: { number },
	color: string,
	width: number
): scene.Shape?
	local dx, dy = tip[1] - from[1], tip[2] - from[2]
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 or kind == "none" then
		return nil
	end
	local ux, uy = dx / len, dy / len
	local size = math.max(width * 4, 8)
	local function at(back: number, side: number): { number }
		return { tip[1] - ux * back - uy * side, tip[2] - uy * back + ux * side }
	end
	if kind == "triangle" then
		return {
			kind = "poly",
			pts = { at(size, size * 0.5), at(0, 0), at(size, -size * 0.5) },
			closed = true,
			style = { fill = color, stroke = color, width = width },
		}
	end
	if kind == "dot" then
		return {
			kind = "ellipse",
			x = tip[1] - size * 0.4,
			y = tip[2] - size * 0.4,
			w = size * 0.8,
			h = size * 0.8,
			style = { fill = color, stroke = color, width = width },
		}
	end
	if kind == "square" then
		return {
			kind = "poly",
			pts = { at(0, size * 0.35), at(size * 0.7, size * 0.35), at(size * 0.7, -size * 0.35), at(0, -size * 0.35) },
			closed = true,
			style = { fill = color, stroke = color, width = width },
		}
	end
	if kind == "pipe" then
		return { kind = "poly", pts = { at(0, size * 0.5), at(0, -size * 0.5) }, style = { stroke = color, width = width } }
	end
	if kind == "diamond" then
		return {
			kind = "poly",
			pts = { at(size, 0), at(size * 0.5, size * 0.4), at(0, 0), at(size * 0.5, -size * 0.4) },
			closed = true,
			style = { fill = color, stroke = color, width = width },
		}
	end
	-- "arrow", and anything else: the open head of two strokes.
	return {
		kind = "poly",
		pts = { at(size, size * 0.5), at(0, 0), at(size, -size * 0.5) },
		style = { stroke = color, width = width },
	}
end

--- A frame, note or image that cannot be drawn as itself.
local function placeholder(
	shapes: { scene.Shape },
	rec: { [string]: any },
	props: { [string]: any },
	x: number,
	y: number,
	w: number,
	h: number,
	label: string,
	stroke: string,
	fill: string?
)
	table.insert(shapes, {
		kind = "rect",
		x = x,
		y = y,
		w = w,
		h = h,
		rx = 4,
		angle = math.deg(number(rec.rotation, 0)),
		style = { stroke = stroke, width = 1, dash = "dashed", fill = fill, fill_opacity = if fill == nil then nil else 0.5 },
	})
	if w > 24 and h > 16 then
		table.insert(shapes, {
			kind = "text",
			x = x,
			y = y,
			w = w,
			h = h,
			lines = { label },
			size = 13,
			color = "#6b7280",
			anchor = "middle",
		})
	end
end

local GEO_POLY: { [string]: { { number } } } = {
	diamond = { { 0.5, 0 }, { 1, 0.5 }, { 0.5, 1 }, { 0, 0.5 } },
	triangle = { { 0.5, 0 }, { 1, 1 }, { 0, 1 } },
	trapezoid = { { 0.25, 0 }, { 0.75, 0 }, { 1, 1 }, { 0, 1 } },
	rhombus = { { 0.5, 0 }, { 1, 0.5 }, { 0.5, 1 }, { 0, 0.5 } },
	pentagon = { { 0.5, 0 }, { 1, 0.38 }, { 0.81, 1 }, { 0.19, 1 }, { 0, 0.38 } },
	hexagon = { { 0.25, 0 }, { 0.75, 0 }, { 1, 0.5 }, { 0.75, 1 }, { 0.25, 1 }, { 0, 0.5 } },
	octagon = {
		{ 0.3, 0 },
		{ 0.7, 0 },
		{ 1, 0.3 },
		{ 1, 0.7 },
		{ 0.7, 1 },
		{ 0.3, 1 },
		{ 0, 0.7 },
		{ 0, 0.3 },
	},
	["x-box"] = {
		{ 0, 0 },
		{ 1, 0 },
		{ 1, 1 },
		{ 0, 1 },
	},
	["check-box"] = {
		{ 0, 0 },
		{ 1, 0 },
		{ 1, 1 },
		{ 0, 1 },
	},
	star = {
		{ 0.5, 0 },
		{ 0.62, 0.36 },
		{ 1, 0.38 },
		{ 0.7, 0.62 },
		{ 0.81, 1 },
		{ 0.5, 0.76 },
		{ 0.19, 1 },
		{ 0.3, 0.62 },
		{ 0, 0.38 },
		{ 0.38, 0.36 },
	},
}

local function geo_shape(
	shapes: { scene.Shape },
	rec: { [string]: any },
	props: { [string]: any },
	x: number,
	y: number
): string
	local geo = tostring(props.geo)
	local w = number(props.w, 0)
	local h = number(props.h, 0) + number(props.growY, 0)
	local style = style_of(rec, props)
	local common = { x = x, y = y, w = w, h = h, angle = math.deg(number(rec.rotation, 0)), style = style }
	if geo == "ellipse" or geo == "oval" then
		table.insert(shapes, { kind = "ellipse", x = x, y = y, w = w, h = h, angle = common.angle, style = style })
	elseif GEO_POLY[geo] ~= nil then
		local pts = {}
		for _, unit in ipairs(GEO_POLY[geo]) do
			table.insert(pts, { x + unit[1] * w, y + unit[2] * h })
		end
		table.insert(shapes, { kind = "poly", pts = pts, closed = true, x = x, y = y, w = w, h = h, angle = common.angle, style = style })
	else
		table.insert(shapes, { kind = "rect", x = x, y = y, w = w, h = h, angle = common.angle, style = style })
	end
	label_inside(shapes, rec, props, x, y, w, h, 16, LABEL_FONT_SIZE)
	return geo
end

local function draw_shape(shapes: { scene.Shape }, rec: { [string]: any }, props: { [string]: any }, x: number, y: number)
	local scale_x = number(props.scaleX, 1)
	local scale_y = number(props.scaleY, 1)
	local width = width_of(props.size) * math.max(number(props.scale, 1), 1)
	local style: scene.Style = {
		stroke = stroke_of(props),
		width = width,
		dash = dash_of(props),
		opacity = number(rec.opacity, 1),
	}
	if props.isClosed == true then
		local fill = fill_of(props)
		style.fill = fill
		style.fill_opacity = if fill == nil then nil else 0.5
	end
	local segments = props.segments
	if type(segments) == "table" then
		for _, segment in ipairs(segments) do
			if type(segment) == "table" and type(segment.path) == "string" then
				local pts = {}
				for _, point in ipairs(vecs.decode_points(segment.path, segment.dim)) do
					table.insert(pts, { x + point.x * scale_x, y + point.y * scale_y })
				end
				if #pts == 1 then
					table.insert(pts, { pts[1][1] + 0.01, pts[1][2] })
				end
				if #pts >= 2 then
					table.insert(shapes, {
						kind = "poly",
						pts = pts,
						smooth = true,
						closed = props.isClosed == true,
						style = style,
					})
				end
			end
		end
	end
end

local function arrow_shape(shapes: { scene.Shape }, rec: { [string]: any }, props: { [string]: any }, x: number, y: number)
	local sx = x + number(props.start and props.start.x, 0)
	local sy = y + number(props.start and props.start.y, 0)
	local arrow_end = props["end"]
	local ex = x + number(arrow_end and arrow_end.x, 0)
	local ey = y + number(arrow_end and arrow_end.y, 0)
	local color = stroke_of(props)
	local width = width_of(props.size)
	local style: scene.Style = { stroke = color, width = width, dash = dash_of(props), opacity = number(rec.opacity, 1) }
	local bend = number(props.bend, 0)
	local pts: { { number } } = {}
	if bend == 0 then
		pts = { { sx, sy }, { ex, ey } }
	else
		-- tldraw draws a bent arrow as a quadratic curve whose control point
		-- sits `bend` px off the midpoint, on the left of start -> end.
		local mx, my = (sx + ex) / 2, (sy + ey) / 2
		local dx, dy = ex - sx, ey - sy
		local len = math.sqrt(dx * dx + dy * dy)
		local nx = if len == 0 then 0 else -dy / len
		local ny = if len == 0 then 0 else dx / len
		local cx, cy = mx + nx * bend * 2, my + ny * bend * 2
		for i = 0, 12 do
			local t = i / 12
			local u = 1 - t
			table.insert(pts, {
				u * u * sx + 2 * u * t * cx + t * t * ex,
				u * u * sy + 2 * u * t * cy + t * t * ey,
			})
		end
	end
	table.insert(shapes, { kind = "poly", pts = pts, smooth = bend ~= 0, style = style })
	-- Each head points along the shaft it ends: the neighbouring point.
	local head = arrowhead(tostring(props.arrowheadEnd), pts[#pts], pts[#pts - 1], color, width)
	if head ~= nil then
		table.insert(shapes, head)
	end
	local start_head = arrowhead(tostring(props.arrowheadStart), pts[1], pts[2], color, width)
	if start_head ~= nil then
		table.insert(shapes, start_head)
	end
	local lines = rich_text(props.richText)
	if #lines > 0 then
		table.insert(shapes, {
			kind = "text",
			x = math.min(sx, ex) - 60,
			y = (sy + ey) / 2 - 12,
			w = 120,
			h = 24,
			lines = lines,
			size = LABEL_FONT_SIZE[tostring(props.size)] or LABEL_FONT_SIZE.m,
			color = stroke_of(props),
			anchor = "middle",
			family = FONT_FAMILY[tostring(props.font)] or "sans-serif",
		})
	end
end

local function line_shape(shapes: { scene.Shape }, rec: { [string]: any }, props: { [string]: any }, x: number, y: number)
	local points = props.points
	if type(points) ~= "table" then
		return
	end
	local ordered = {}
	for _, point in pairs(points) do
		if type(point) == "table" then
			table.insert(ordered, point)
		end
	end
	table.sort(ordered, function(a, b)
		return tostring(a.index) < tostring(b.index)
	end)
	local pts = {}
	for _, point in ipairs(ordered) do
		table.insert(pts, { x + number(point.x, 0), y + number(point.y, 0) })
	end
	if #pts < 2 then
		return
	end
	table.insert(shapes, {
		kind = "poly",
		pts = pts,
		smooth = tostring(props.spline) == "cubic",
		style = {
			stroke = stroke_of(props),
			width = width_of(props.size),
			dash = dash_of(props),
			opacity = number(rec.opacity, 1),
		},
	})
end

local function shape_into(shapes: { scene.Shape }, rec: { [string]: any }, offset)
	local props = rec.props
	if type(props) ~= "table" then
		return "none"
	end
	local x = number(rec.x, 0) + offset.x
	local y = number(rec.y, 0) + offset.y
	local kind = tostring(rec.type)
	if kind == "geo" then
		return geo_shape(shapes, rec, props, x, y)
	elseif kind == "text" then
		local lines = rich_text(props.richText)
		local size = FONT_SIZE[tostring(props.size)] or FONT_SIZE.m
		local node = text_node(
			rec,
			lines,
			x,
			y,
			number(props.w, 0),
			#lines * size * 1.35,
			size,
			props,
			palette(props.color).solid,
			anchor_of(props.textAlign)
		)
		if node ~= nil then
			table.insert(shapes, node)
		end
	elseif kind == "note" then
		local w, h = 200, 200
		local fill = palette(props.color).noteFill
		table.insert(shapes, {
			kind = "rect",
			x = x,
			y = y,
			w = w,
			h = h,
			rx = 8,
			angle = math.deg(number(rec.rotation, 0)),
			style = { stroke = fill, width = 1, fill = fill },
		})
		local lines = rich_text(props.richText)
		if #lines > 0 then
			table.insert(shapes, {
				kind = "text",
				x = x + 16,
				y = y + 16,
				w = w - 32,
				h = h - 32,
				lines = lines,
				size = LABEL_FONT_SIZE[tostring(props.size)] or LABEL_FONT_SIZE.m,
				color = palette(props.color).solid,
				anchor = anchor_of(props.align),
				family = FONT_FAMILY[tostring(props.font)] or "sans-serif",
				angle = math.deg(number(rec.rotation, 0)),
			})
		end
	elseif kind == "draw" then
		draw_shape(shapes, rec, props, x, y)
	elseif kind == "highlight" then
		draw_shape(shapes, rec, props, x, y)
	elseif kind == "line" then
		line_shape(shapes, rec, props, x, y)
	elseif kind == "arrow" then
		arrow_shape(shapes, rec, props, x, y)
	elseif kind == "frame" then
		local p = palette(props.color)
		local w, h = number(props.w, 0), number(props.h, 0)
		table.insert(shapes, {
			kind = "rect",
			x = x,
			y = y,
			w = w,
			h = h,
			rx = 4,
			angle = math.deg(number(rec.rotation, 0)),
			style = { stroke = p.frameStroke, width = 1, fill = p.frameFill, fill_opacity = 1 },
		})
		if type(props.name) == "string" and props.name ~= "" then
			table.insert(shapes, {
				kind = "text",
				x = x,
				y = y - 20,
				w = w,
				h = 20,
				lines = { props.name },
				size = 13,
				color = p.solid,
			})
		end
		return "frame"
	elseif kind == "image" or kind == "video" or kind == "bookmark" or kind == "embed" then
		placeholder(
			shapes,
			rec,
			props,
			x,
			y,
			number(props.w, 0),
			number(props.h, 0),
			"[" .. kind .. "]",
			"#adb5bd",
			"#f1f3f5"
		)
	elseif kind == "group" then
		return "group"
	else
		placeholder(shapes, rec, props, x, y, number(props.w, 0), number(props.h, 0), "[" .. kind .. "]", "#adb5bd", nil)
		return "other"
	end
	return kind
end

--- Parses the file's text; nil and a message when it is not a tldraw document.
function M.load(text: string): (Info?, string?)
	local ok, doc = pcall(tern.json.decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "the file is not JSON"
	end
	if type(doc.records) ~= "table" then
		-- A store snapshot (`getSnapshot`) keeps its records in a map under
		-- `document.store` instead of the file format's `records` array.
		local store = doc.document
		if type(store) == "table" then
			store = store.store
		end
		if type(store) ~= "table" then
			return nil, "the file has no `records`: not a tldraw document"
		end
		local list = {}
		for _, rec in pairs(store) do
			table.insert(list, rec)
		end
		doc.records = list
	end
	local records = doc.records
	local by_id: { [string]: any } = {}
	local pages: { any } = {}
	for _, rec in ipairs(records) do
		if type(rec) == "table" and type(rec.id) == "string" then
			by_id[rec.id] = rec
			if rec.typeName == "page" then
				table.insert(pages, rec)
			end
		end
	end
	table.sort(pages, function(a, b)
		return tostring(a.index) < tostring(b.index)
	end)
	-- The page a shape sits on, following frames and groups up the chain.
	local function page_of(rec: any): string?
		local seen = 0
		while rec ~= nil and seen < 32 do
			local parent = rec.parentId
			if type(parent) ~= "string" then
				return nil
			end
			if string.sub(parent, 1, 5) == "page:" then
				return parent
			end
			rec = by_id[parent]
			seen += 1
		end
		return nil
	end
	-- The frame or group offsets a shape's coordinates are relative to.
	local function offset_of(rec: any): { x: number, y: number }
		local offset = { x = 0, y = 0 }
		local seen = 0
		local parent = rec.parentId
		while type(parent) == "string" and seen < 32 do
			local owner = by_id[parent]
			if owner == nil or owner.typeName ~= "shape" then
				break
			end
			offset.x += number(owner.x, 0)
			offset.y += number(owner.y, 0)
			parent = owner.parentId
			seen += 1
		end
		return offset
	end
	local shapes_by_page: { [string]: { any } } = {}
	for _, rec in ipairs(records) do
		if type(rec) == "table" and rec.typeName == "shape" and rec.type ~= "group" then
			local page = page_of(rec)
			if page ~= nil then
				local list = shapes_by_page[page]
				if list == nil then
					list = {}
					shapes_by_page[page] = list
				end
				table.insert(list, rec)
			end
		end
	end
	local notes: { string } = {}
	local count = 0
	local painted: { scene.Shape } = {}
	local drawn_pages = 0
	local offset_x = 0
	local function draw_page(page_id: string, title: string?)
		local list = shapes_by_page[page_id]
		if list == nil or #list == 0 then
			return
		end
		-- tldraw orders shapes on a page by their fractional `index`, with a
		-- child always drawn above the frame or group holding it; frames
		-- themselves sit beneath everything on the page. The order key is the
		-- chain of indexes from the page down, so a parent sorts before its
		-- children and siblings keep their index order.
		local function order_key(rec: any): string
			local parts: { string } = { tostring(rec.index) }
			local parent = rec.parentId
			local seen = 0
			while type(parent) == "string" and seen < 32 do
				local owner = by_id[parent]
				if owner == nil or owner.typeName ~= "shape" then
					break
				end
				table.insert(parts, 1, tostring(owner.index))
				parent = owner.parentId
				seen += 1
			end
			return table.concat(parts, "/")
		end
		local frames, others = {}, {}
		for _, rec in ipairs(list) do
			if rec.type == "frame" then
				table.insert(frames, rec)
			else
				table.insert(others, rec)
			end
		end
		for _, group in ipairs({ frames, others }) do
			table.sort(group, function(a, b)
				return order_key(a) < order_key(b)
			end)
		end
		local page_shapes: { scene.Shape } = {}
		for _, group in ipairs({ frames, others }) do
			for _, rec in ipairs(group) do
				shape_into(page_shapes, rec, offset_of(rec))
				count += 1
			end
		end
		if #page_shapes == 0 then
			return
		end
		local box = scene.bounds(page_shapes, 0)
		local shift = 0
		if box ~= nil then
			shift = offset_x - box[1]
		end
		for _, shape in ipairs(page_shapes) do
			if shape.kind == "poly" then
				for _, point in ipairs(shape.pts or {}) do
					point[1] += shift
				end
			else
				shape.x = (shape.x or 0) + shift
			end
			table.insert(painted, shape)
		end
		if title ~= nil then
			table.insert(painted, {
				kind = "text",
				x = offset_x,
				y = if box == nil then 0 else box[2] - 24,
				w = if box == nil then 0 else box[3],
				h = 20,
				lines = { title },
				size = 13,
				color = "#6b7280",
			})
		end
		offset_x += (if box == nil then 0 else box[3]) + 40
		drawn_pages += 1
	end
	if #pages > 0 then
		for index, page in ipairs(pages) do
			draw_page(page.id, if #pages > 1 then tostring(page.name) .. string.format(" (%d)", index) else nil)
		end
	else
		-- No page records: draw every shape as one canvas.
		local page_shapes: { scene.Shape } = {}
		for _, rec in ipairs(records) do
			if type(rec) == "table" and rec.typeName == "shape" and rec.type ~= "group" then
				shape_into(page_shapes, rec, offset_of(rec))
				count += 1
			end
		end
		for _, shape in ipairs(page_shapes) do
			table.insert(painted, shape)
		end
	end
	if #painted == 0 then
		return nil, "the document has no shapes to draw"
	end
	if drawn_pages > 1 then
		table.insert(notes, string.format("%d pages drawn side by side", drawn_pages))
	end
	return { shapes = painted, background = BACKGROUND, count = count, notes = notes }, nil
end

return M