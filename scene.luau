--!strict
-- The drawing vocabulary both readers lower a file to, plus the SVG writer
-- that draws it.
--
-- Tern mounts an `image/svg+xml` blob as real SVG elements, so the output
-- here must stay inside what its renderer draws: `path`, `rect`, `text`,
-- `g transform`, `opacity` and stroke dash arrays (measured against 0.8.4).
-- It drops `<ellipse>` and `<polyline>`, so ellipses are emitted as two arc
-- subpaths and every stroke is a path.

local M = {}

export type Style = {
	stroke: string?,
	fill: string?,
	fill_opacity: number?,
	width: number?,
	dash: string?,
	opacity: number?,
}

export type Shape = {
	kind: string, -- "rect" | "ellipse" | "poly" | "text"
	x: number?, y: number?, w: number?, h: number?, rx: number?,
	pts: { { number } }?, -- poly: absolute points
	closed: boolean?,
	smooth: boolean?,
	lines: { string }?, -- text
	size: number?,
	color: string?,
	anchor: string?, -- text: "start" | "middle" | "end"
	weight: string?,
	family: string?,
	angle: number?, -- degrees clockwise, about the shape's centre
	style: Style?,
}

local HEX = "^#%x%x%x%x%x%x$"

--- Whether `c` is a colour this writer can put in a paint attribute.
function M.color(c: any): string?
	if type(c) ~= "string" then
		return nil
	end
	local lower = string.lower(c)
	if string.match(lower, HEX) ~= nil then
		return lower
	end
	return nil
end

--- A number as SVG wants it: at most two decimals, no trailing zeros, and
--- never the float artifacts a raw `tostring` would leave in the file.
local function num(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "0"
	end
	local r = math.floor(n * 100 + 0.5) / 100
	if r == 0 then
		return "0"
	end
	if r == math.floor(r) then
		return string.format("%d", r)
	end
	return (string.format("%.2f", r):gsub("%.?0+$", ""))
end

M.num = num

--- SVG text for `s`, with the characters that would end an attribute or tag
--- escaped. Control characters are dropped: they cannot appear in XML at all.
function M.esc(s: string): string
	local out = string.gsub(s, "[%z\1-\8\11\12\14-\31]", "")
	out = string.gsub(out, "&", "&amp;")
	out = string.gsub(out, "<", "&lt;")
	out = string.gsub(out, ">", "&gt;")
	out = string.gsub(out, '"', "&quot;")
	return (string.gsub(out, "'", "&#39;"))
end

local DASHES: { [string]: string } = {
	dashed = "8 8",
	dotted = "2 6",
	draw = "12 10",
}

--- The paint attributes a style contributes.
local function paints(style: Style?): string
	local s = style or {}
	local out = {}
	if s.stroke ~= nil then
		table.insert(out, 'stroke="' .. s.stroke .. '"')
		table.insert(out, 'stroke-width="' .. num(s.width or 1) .. '"')
		table.insert(out, 'stroke-linecap="round"')
		table.insert(out, 'stroke-linejoin="round"')
		local dash = if s.dash ~= nil then DASHES[s.dash] else nil
		if dash ~= nil then
			table.insert(out, 'stroke-dasharray="' .. dash .. '"')
		end
	else
		table.insert(out, 'stroke="none"')
	end
	if s.fill ~= nil and s.fill ~= "none" then
		table.insert(out, 'fill="' .. s.fill .. '"')
		local alpha = s.fill_opacity
		if alpha ~= nil and alpha < 1 then
			table.insert(out, 'fill-opacity="' .. num(alpha) .. '"')
		end
	else
		table.insert(out, 'fill="none"')
	end
	return " " .. table.concat(out, " ")
end

--- A closed path for a box that reads as an ellipse: two arcs, the only
--- ellipse the renderer draws.
local function ellipse_path(x: number, y: number, w: number, h: number): string
	local rx, ry = w / 2, h / 2
	local cx, cy = x + rx, y + ry
	return string.format(
		"M%s,%s a%s,%s 0 1 0 %s,0 a%s,%s 0 1 0 -%s,0 Z",
		num(cx),
		num(y),
		num(rx),
		num(ry),
		num(w),
		num(rx),
		num(ry),
		num(w)
	)
end

--- A path through `pts`, softened through the midpoints of each segment when
--- `smooth` is set (freehand strokes and splines).
local function poly_path(pts: { { number } }, closed: boolean?, smooth: boolean?): string
	if #pts == 0 then
		return ""
	end
	local out = { "M" .. num(pts[1][1]) .. "," .. num(pts[1][2]) }
	if not smooth or #pts < 3 then
		for i = 2, #pts do
			table.insert(out, "L" .. num(pts[i][1]) .. "," .. num(pts[i][2]))
		end
	else
		for i = 2, #pts - 1 do
			local mx = (pts[i][1] + pts[i + 1][1]) / 2
			local my = (pts[i][2] + pts[i + 1][2]) / 2
			table.insert(out, "Q" .. num(pts[i][1]) .. "," .. num(pts[i][2]) .. " " .. num(mx) .. "," .. num(my))
		end
		local last = pts[#pts]
		table.insert(out, "L" .. num(last[1]) .. "," .. num(last[2]))
	end
	if closed == true then
		table.insert(out, "Z")
	end
	return table.concat(out, " ")
end

local FALLBACK_FAMILY = "sans-serif"

local function text_nodes(shape: Shape): { string }
	local lines = shape.lines or {}
	local size = shape.size or 16
	local anchor = shape.anchor or "start"
	local weight = shape.weight
	local family = shape.family or FALLBACK_FAMILY
	local color = shape.color or "#1e1e1e"
	local box_x = shape.x or 0
	local box_w = shape.w or 0
	local box_y = shape.y or 0
	local box_h = shape.h or (#lines * size * 1.25)
	local x = box_x
	if anchor == "middle" then
		x = box_x + box_w / 2
	elseif anchor == "end" then
		x = box_x + box_w
	end
	local line_height = size * 1.25
	local total = #lines * line_height
	local top = box_y + (box_h - total) / 2
	local nodes = {}
	for i, line in ipairs(lines) do
		if line ~= "" then
			local baseline = top + (i - 1) * line_height + size * 0.8
			local attrs = {
				'x="' .. num(x) .. '"',
				'y="' .. num(baseline) .. '"',
				'font-size="' .. num(size) .. '"',
				'font-family="' .. M.esc(family) .. '"',
				'fill="' .. color .. '"',
				'text-anchor="' .. anchor .. '"',
			}
			if weight ~= nil then
				table.insert(attrs, 'font-weight="' .. M.esc(weight) .. '"')
			end
			table.insert(nodes, "<text " .. table.concat(attrs, " ") .. ">" .. M.esc(line) .. "</text>")
		end
	end
	return nodes
end

--- The SVG for one shape, or "" for one that draws nothing.
local function shape_svg(shape: Shape): string
	local body = {}
	if shape.kind == "rect" then
		local attrs = {
			'x="' .. num(shape.x or 0) .. '"',
			'y="' .. num(shape.y or 0) .. '"',
			'width="' .. num(math.max(shape.w or 0, 0)) .. '"',
			'height="' .. num(math.max(shape.h or 0, 0)) .. '"',
		}
		if shape.rx ~= nil and (shape.rx :: number) > 0 then
			table.insert(attrs, 'rx="' .. num(shape.rx :: number) .. '"')
		end
		table.insert(body, "<rect " .. table.concat(attrs, " ") .. paints(shape.style) .. "/>")
	elseif shape.kind == "ellipse" then
		local d = ellipse_path(shape.x or 0, shape.y or 0, shape.w or 0, shape.h or 0)
		table.insert(body, '<path d="' .. d .. '"' .. paints(shape.style) .. "/>")
	elseif shape.kind == "poly" then
		local pts = shape.pts or {}
		if #pts == 1 then
			-- A single point is a dot: the same circle, tiny.
			pts = { { pts[1][1], pts[1][2] }, { pts[1][1] + 0.01, pts[1][2] } }
		end
		local d = poly_path(pts, shape.closed, shape.smooth)
		if d ~= "" then
			local style = shape.style
			if shape.closed == true and (style == nil or style.fill == nil) then
				style = table.clone(style or {})
				style.fill = "none"
			end
			table.insert(body, '<path d="' .. d .. '"' .. paints(style) .. "/>")
		end
	elseif shape.kind == "text" then
		local nodes = text_nodes(shape)
		-- A background box, when the source drew one (a label on a shape).
		local style = shape.style
		if style ~= nil and (style.fill ~= nil or style.stroke ~= nil) then
			local box = {
				kind = "rect",
				x = shape.x,
				y = shape.y,
				w = shape.w,
				h = shape.h,
				style = style,
			}
			table.insert(body, shape_svg(box))
		end
		for _, node in ipairs(nodes) do
			table.insert(body, node)
		end
	end
	if #body == 0 then
		return ""
	end
	local angle = shape.angle
	local inner = table.concat(body, "")
	if angle == nil or angle == 0 then
		return inner
	end
	local cx = (shape.x or 0) + (shape.w or 0) / 2
	local cy = (shape.y or 0) + (shape.h or 0) / 2
	return '<g transform="rotate(' .. num(angle :: number) .. " " .. num(cx) .. " " .. num(cy) .. ')">' .. inner .. "</g>"
end

--- Roughly how wide `lines` draw at `size`, for shapes that carry no box.
local function text_width(lines: { string }, size: number): number
	local widest = 0
	for _, line in ipairs(lines) do
		widest = math.max(widest, #line)
	end
	return widest * size * 0.6
end

--- The box that holds every shape, with `pad` cells of margin. nil when there
--- is nothing to draw.
function M.bounds(shapes: { Shape }, pad: number?): ({ number }?, number)
	local margin = pad or 16
	local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
	local drawn = 0
	local function take(x: number, y: number, w: number, h: number)
		drawn += 1
		minx, miny = math.min(minx, x), math.min(miny, y)
		maxx, maxy = math.max(maxx, x + w), math.max(maxy, y + h)
	end
	for _, shape in ipairs(shapes) do
		local kind = shape.kind
		if kind == "text" then
			local lines = shape.lines or {}
			if #lines > 0 then
				local size = shape.size or 16
				local w = shape.w
				if w == nil or w == 0 then
					w = text_width(lines, size)
				end
				local h = shape.h
				if h == nil or h == 0 then
					h = #lines * size * 1.25
				end
				take(shape.x or 0, shape.y or 0, w, h)
			end
		elseif kind == "poly" then
			local pts = shape.pts or {}
			local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
			for _, p in ipairs(pts) do
				x1, y1 = math.min(x1, p[1]), math.min(y1, p[2])
				x2, y2 = math.max(x2, p[1]), math.max(y2, p[2])
			end
			if x1 < math.huge then
				local w = math.max(x2 - x1, 1)
				local h = math.max(y2 - y1, 1)
				take(x1 - (shape.style and shape.style.width or 1), y1 - (shape.style and shape.style.width or 1), w, h)
			end
		else
			take(shape.x or 0, shape.y or 0, shape.w or 0, shape.h or 0)
		end
	end
	if drawn == 0 then
		return nil
	end
	return { minx - margin, miny - margin, maxx - minx + margin * 2, maxy - miny + margin * 2 }, drawn
end

--- The document: `shapes` drawn onto a transparent page of the given box.
function M.render(shapes: { Shape }, box: { number }, background: string?): string
	local parts = {
		string.format(
			'<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="%s %s %s %s">',
			num(box[3]),
			num(box[4]),
			num(box[1]),
			num(box[2]),
			num(box[3]),
			num(box[4])
		),
	}
	if background ~= nil and background ~= "transparent" then
		table.insert(
			parts,
			string.format(
				'<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>',
				num(box[1]),
				num(box[2]),
				num(box[3]),
				num(box[4]),
				background
			)
		)
	end
	for _, shape in ipairs(shapes) do
		local svg = shape_svg(shape)
		if svg ~= "" then
			table.insert(parts, svg)
		end
	end
	table.insert(parts, "</svg>")
	return table.concat(parts)
end

return M