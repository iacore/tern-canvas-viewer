--!strict
-- Reads an Excalidraw scene (the `.excalidraw` JSON `exportToFile` writes)
-- into the shared drawing vocabulary.
--
-- Element fields follow `packages/element/src/types.ts` of excalidraw/excalidraw:
-- `type`, `x`, `y`, `width`, `height`, `angle` (radians), `strokeColor`,
-- `backgroundColor`, `fillStyle`, `strokeWidth`, `strokeStyle`, `roundness`,
-- `opacity`, `isDeleted`, plus the per-type fields — `points`, `polygon` and
-- `startArrowhead`/`endArrowhead` on a line or arrow, `points`/`pressures` on a
-- free draw, `text`/`fontSize`/`fontFamily`/`textAlign` on text, `fileId` on an
-- image and `name` on a frame. Artwork the block cannot draw (an embedded
-- image, an embed, an iframe) is boxed and counted instead of dropped.

local scene = require("./scene")

local M = {}

export type Info = {
	shapes: { scene.Shape },
	background: string?,
	count: number,
	notes: { string },
}

-- Font family numbers (packages/common/src/constants.ts, FONT_FAMILY) to the
-- families a terminal can be relied on to have. Virgil, Excalifont and Lilita
-- One are hand-drawn faces with no terminal equivalent, so they fall back.
local FONTS: { [number]: string } = {
	[1] = "sans-serif", -- Virgil
	[2] = "sans-serif", -- Helvetica
	[3] = "ui-monospace, monospace", -- Cascadia
	[5] = "sans-serif", -- Excalifont
	[6] = "sans-serif", -- Nunito
	[7] = "sans-serif", -- Lilita One
	[8] = "ui-monospace, monospace", -- Comic Shanns
	[9] = "sans-serif", -- Liberation Sans
	[10] = "sans-serif", -- Assistant
}

local ANCHORS: { [string]: string } = {
	left = "start",
	center = "middle",
	right = "end",
}

local function number(v: any, fallback: number): number
	local n = tonumber(v)
	if n == nil then
		return fallback
	end
	return n
end

local function style_of(el: { [string]: any }): scene.Style
	local fill = scene.color(el.backgroundColor)
	local fill_opacity: number? = nil
	if fill ~= nil then
		-- Only a solid fill is painted colour. Hachure, cross-hatch and zigzag
		-- are hatch patterns this writer cannot hatch, so they come through as
		-- a lighter wash of the same colour.
		fill_opacity = if el.fillStyle == "solid" then 1 else 0.35
	end
	local dash: string? = nil
	if el.strokeStyle == "dashed" or el.strokeStyle == "dotted" then
		dash = el.strokeStyle
	end
	return {
		stroke = scene.color(el.strokeColor),
		fill = fill,
		fill_opacity = fill_opacity,
		width = number(el.strokeWidth, 1),
		dash = dash,
		opacity = number(el.opacity, 100) / 100,
	}
end

local function corner_radius(el: { [string]: any }, w: number, h: number): number?
	local r = el.roundness
	if type(r) ~= "table" then
		return nil
	end
	if tonumber(r.type) == 3 then
		-- ADAPTIVE_RADIUS: a fixed radius, capped by the short side.
		return math.min(number(r.value, 32), math.min(w, h) / 2)
	end
	-- LEGACY and PROPORTIONAL_RADIUS: a quarter of the short side.
	return math.min(w, h) * 0.25
end

local function absolute_points(el: { [string]: any }): { { number } }
	local pts = {}
	local raw = el.points
	if type(raw) == "table" then
		for _, p in ipairs(raw) do
			if type(p) == "table" then
				table.insert(pts, { number(el.x, 0) + number(p[1], 0), number(el.y, 0) + number(p[2], 0) })
			end
		end
	end
	return pts
end

--- The head an arrow carries at `tip`, pointing away from `from`.
local function head_shape(kind: string, tip: { number }, from: { number }, width: number, color: string?): scene.Shape?
	local stroke = color or "#1e1e1e"
	local dx, dy = tip[1] - from[1], tip[2] - from[2]
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then
		return nil
	end
	local ux, uy = dx / len, dy / len
	local size = math.max(width * 3.5, 7)
	-- A point `back` behind the tip and `side` to its right, along the shaft.
	local function at(back: number, side: number): { number }
		return { tip[1] - ux * back - uy * side, tip[2] - uy * back + ux * side }
	end
	if kind == "bar" or string.sub(kind, 1, 8) == "crowfoot" then
		return { kind = "poly", pts = { at(0, size * 0.6), at(0, -size * 0.6) }, style = { stroke = stroke, width = width } }
	end
	if kind == "arrow" then
		-- The open head: two strokes meeting at the tip.
		return {
			kind = "poly",
			pts = { at(size, size * 0.5), at(0, 0), at(size, -size * 0.5) },
			style = { stroke = stroke, width = width },
		}
	end
	if kind == "circle" or kind == "circle_outline" then
		local style: scene.Style = { width = width }
		if kind == "circle" then
			style.fill = stroke
		else
			style.stroke = stroke
		end
		return { kind = "ellipse", x = tip[1] - size * 0.5, y = tip[2] - size * 0.5, w = size, h = size, style = style }
	end
	if kind == "diamond" or kind == "diamond_outline" then
		local style: scene.Style = { width = width }
		if kind == "diamond" then
			style.fill = stroke
		else
			style.stroke = stroke
		end
		return {
			kind = "poly",
			pts = { at(size, 0), at(size * 0.5, size * 0.5), at(0, 0), at(size * 0.5, -size * 0.5) },
			closed = true,
			style = style,
		}
	end
	if kind == "triangle_outline" then
		return {
			kind = "poly",
			pts = { at(size, size * 0.5), at(0, 0), at(size, -size * 0.5) },
			closed = true,
			style = { stroke = stroke, width = width, fill = "none" },
		}
	end
	-- "triangle", and anything newer this reader does not know.
	return {
		kind = "poly",
		pts = { at(size, size * 0.5), at(0, 0), at(size, -size * 0.5) },
		closed = true,
		style = { fill = stroke, stroke = stroke, width = width },
	}
end

--- A boxed notice where a shape cannot be drawn, with its label under it.
local function add_placeholder(shapes: { scene.Shape }, el: { [string]: any }, label: string)
	local x, y = number(el.x, 0), number(el.y, 0)
	local w, h = number(el.width, 0), number(el.height, 0)
	table.insert(shapes, {
		kind = "rect",
		x = x,
		y = y,
		w = w,
		h = h,
		rx = 4,
		angle = math.deg(number(el.angle, 0)),
		style = { stroke = "#adb5bd", width = 1, dash = "dashed", fill = "#f1f3f5", fill_opacity = 0.5 },
	})
	if w > 8 and h > 8 then
		table.insert(shapes, {
			kind = "text",
			x = x,
			y = y,
			w = w,
			h = h,
			lines = { label },
			size = 13,
			color = "#868e96",
			anchor = "middle",
		})
	end
end

local function text_shape(el: { [string]: any }): scene.Shape?
	local raw = el.text
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local lines = {}
	for line in string.gmatch(raw .. "\n", "([^\n]*)\n") do
		table.insert(lines, line)
	end
	return {
		kind = "text",
		x = number(el.x, 0),
		y = number(el.y, 0),
		w = number(el.width, 0),
		h = number(el.height, 0),
		lines = lines,
		size = number(el.fontSize, 20),
		color = scene.color(el.strokeColor) or "#1e1e1e",
		anchor = ANCHORS[tostring(el.textAlign)] or "start",
		family = FONTS[number(el.fontFamily, 5)] or "sans-serif",
	}
end

--- Parses the file's text; nil and a message when it is not a scene.
function M.load(text: string): (Info?, string?)
	local ok, doc = pcall(tern.json.decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "the file is not JSON"
	end
	if type(doc.elements) ~= "table" then
		return nil, "the file has no `elements`: not an Excalidraw scene"
	end
	local shapes: { scene.Shape } = {}
	local notes: { string } = {}
	local images, others, hatched = 0, 0, 0
	local count = 0
	for _, el in ipairs(doc.elements) do
		if type(el) == "table" and el.isDeleted ~= true and el.type ~= "selection" then
			local kind = tostring(el.type)
			local style = style_of(el)
			count += 1
			if el.fillStyle ~= "solid" and scene.color(el.backgroundColor) ~= nil then
				hatched += 1
			end
			if kind == "rectangle" or kind == "stickynote" then
				local w, h = number(el.width, 0), number(el.height, 0)
				table.insert(shapes, {
					kind = "rect",
					x = number(el.x, 0),
					y = number(el.y, 0),
					w = w,
					h = h,
					rx = corner_radius(el, w, h),
					angle = math.deg(number(el.angle, 0)),
					style = style,
				})
			elseif kind == "ellipse" then
				table.insert(shapes, {
					kind = "ellipse",
					x = number(el.x, 0),
					y = number(el.y, 0),
					w = number(el.width, 0),
					h = number(el.height, 0),
					angle = math.deg(number(el.angle, 0)),
					style = style,
				})
			elseif kind == "diamond" then
				local x, y = number(el.x, 0), number(el.y, 0)
				local w, h = number(el.width, 0), number(el.height, 0)
				table.insert(shapes, {
					kind = "poly",
					pts = { { x + w / 2, y }, { x + w, y + h / 2 }, { x + w / 2, y + h }, { x, y + h / 2 } },
					closed = true,
					x = x,
					y = y,
					w = w,
					h = h,
					angle = math.deg(number(el.angle, 0)),
					style = style,
				})
			elseif kind == "line" or kind == "arrow" then
				local pts = absolute_points(el)
				if #pts >= 2 then
					table.insert(shapes, {
						kind = "poly",
						pts = pts,
						closed = el.polygon == true,
						angle = math.deg(number(el.angle, 0)),
						style = style,
					})
					if kind == "arrow" then
						local width = number(el.strokeWidth, 1)
						if type(el.endArrowhead) == "string" and el.endArrowhead ~= "" then
							local head = head_shape(el.endArrowhead, pts[#pts], pts[#pts - 1], width, style.stroke)
							if head ~= nil then
								table.insert(shapes, head)
							end
						end
						if type(el.startArrowhead) == "string" and el.startArrowhead ~= "" then
							local head = head_shape(el.startArrowhead, pts[1], pts[2], width, style.stroke)
							if head ~= nil then
								table.insert(shapes, head)
							end
						end
					end
				end
			elseif kind == "freedraw" then
				local pts = absolute_points(el)
				if #pts >= 2 then
					table.insert(shapes, {
						kind = "poly",
						pts = pts,
						smooth = true,
						style = { stroke = style.stroke, width = math.max(style.width or 1, 1), opacity = style.opacity },
					})
				end
			elseif kind == "text" then
				local shape = text_shape(el)
				if shape ~= nil then
					table.insert(shapes, shape)
				end
			elseif kind == "frame" or kind == "magicframe" then
				table.insert(shapes, {
					kind = "rect",
					x = number(el.x, 0),
					y = number(el.y, 0),
					w = number(el.width, 0),
					h = number(el.height, 0),
					rx = 8,
					angle = math.deg(number(el.angle, 0)),
					style = { stroke = "#adb5bd", width = 1 },
				})
				if type(el.name) == "string" and el.name ~= "" then
					table.insert(shapes, {
						kind = "text",
						x = number(el.x, 0),
						y = number(el.y, 0) - 20,
						w = number(el.width, 0),
						h = 20,
						lines = { el.name },
						size = 13,
						color = "#868e96",
					})
				end
			elseif kind == "image" then
				images += 1
				add_placeholder(
					shapes,
					el,
					string.format("[image %d×%d]", math.floor(number(el.width, 0)), math.floor(number(el.height, 0)))
				)
			elseif kind == "embeddable" or kind == "iframe" then
				others += 1
				add_placeholder(shapes, el, "[" .. kind .. "]")
			else
				others += 1
				add_placeholder(shapes, el, "[" .. kind .. "]")
			end
		end
	end
	if #shapes == 0 then
		return nil, "the scene has no elements to draw"
	end
	if images > 0 then
		table.insert(notes, string.format("%d embedded image%s drawn as a box", images, if images == 1 then "" else "s"))
	end
	if others > 0 then
		table.insert(notes, string.format("%d element%s this block cannot draw", others, if others == 1 then "" else "s"))
	end
	if hatched > 0 then
		table.insert(notes, "hatched fills drawn as a light wash")
	end
	local background: string? = nil
	local app = doc.appState
	if type(app) == "table" then
		background = scene.color(app.viewBackgroundColor)
	end
	return { shapes = shapes, background = background, count = count, notes = notes }, nil
end

return M