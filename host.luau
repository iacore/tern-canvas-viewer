--!strict
-- The `view` block: one canvas file drawn as an SVG image.
--
-- The file is read here, in the host half, so the block works wherever the
-- pane runs (the daemon, a window, the web client); Tern draws the image.
-- Keys: r reloads from disk, o opens the file as text, y copies its path.
-- A file that changes on disk is picked up on its own while the block is open.

local scene = require("./scene")
local excalidraw = require("./excalidraw")
local tldraw = require("./tldraw")

local ui = tern.ui

-- A scene above this is refused: parsing and drawing run inside one 2-second
-- host call.
local MAX_BYTES = 8 * 1024 * 1024
-- Tern mounts an SVG blob of at most 256 KiB.
local MAX_SVG = 250 * 1024
-- Files up to this are re-read to notice an edit on disk.
local WATCH_BYTES = 1024 * 1024
local WATCH_MS = 2000

type Problem = { title: string, text: string }

type State = {
	cx: BlockCx,
	path: string?,
	name: string,
	format: string,
	shapes: { scene.Shape },
	background: string?,
	box: { number }?,
	count: number,
	notes: { string },
	blob: string?,
	bytes: number,
	watched: boolean,
	text: string?,
	problem: Problem?,
}

local function suffix(path: string): string
	return string.lower(string.match(path, "%.[^./]+$") or "")
end

local function base_name(path: string): string
	return string.match(path, "[^/]+$") or path
end

--- Reads `path` as a scene. The extension picks the reader; when the file
--- names no format this understands, the document itself decides.
local function read_scene(path: string, text: string): (excalidraw.Info?, Problem?)
	local ext = suffix(path)
	local loaders = {}
	if ext == ".tldraw" then
		table.insert(loaders, tldraw)
	end
	if ext == ".excalidraw" then
		table.insert(loaders, excalidraw)
	end
	if #loaders == 0 then
		table.insert(loaders, excalidraw)
		table.insert(loaders, tldraw)
	end
	local messages: { string } = {}
	for _, loader in ipairs(loaders) do
		local info, err = loader.load(text)
		if info ~= nil then
			return info, nil
		end
		if err ~= nil then
			table.insert(messages, err)
		end
	end
	return nil, { title = "Cannot read this file", text = table.concat(messages, "; ") }
end

--- The SVG for `info`, trimmed to Tern's blob limit if it does not fit.
local function render_svg(info: excalidraw.Info, box: { number }): (string, number)
	local all = info.shapes
	local svg = scene.render(all, box, info.background)
	if #svg <= MAX_SVG then
		return svg, #all
	end
	-- Too large: draw the front of the scene only, and say how much is left.
	local low, high = 1, #all
	while low < high do
		local mid = math.floor((low + high) / 2)
		local partial = scene.bounds({ table.unpack(all, 1, mid) }, 16)
		local attempt = if partial == nil then "" else scene.render({ table.unpack(all, 1, mid) }, box, info.background)
		if #attempt <= MAX_SVG then
			low = mid + 1
		else
			high = mid
		end
	end
	local kept = math.max(low - 1, 1)
	return scene.render({ table.unpack(all, 1, kept) }, box, info.background), kept
end

local function build(state: State, text: string): ()
	local info, problem = read_scene(state.path or "", text)
	if info == nil then
		state.problem = problem
		state.shapes = {}
		return
	end
	local box = scene.bounds(info.shapes, 16)
	if box == nil then
		state.problem = { title = "Nothing to draw", text = "the file holds no shapes" }
		return
	end
	local svg, kept = render_svg(info, box)
	if kept < #info.shapes then
		table.insert(
			info.notes,
			string.format(
				"%d of %d shapes drawn: the rest does not fit Tern's SVG limit",
				kept,
				#info.shapes
			)
		)
	end
	state.problem = nil
	state.shapes = info.shapes
	state.background = info.background
	state.box = box
	state.count = info.count
	state.notes = info.notes
	state.blob = state.cx:blob(svg, "image/svg+xml")
end

local function reload(state: State): boolean
	local path = state.path
	if path == nil then
		return false
	end
	local ok, text = pcall(tern.fs.read, path, MAX_BYTES)
	if not ok then
		state.problem = { title = "Cannot read " .. base_name(path), text = tostring(text) }
		state.watched = false
		return false
	end
	local bytes = #(text :: string)
	state.bytes = bytes
	state.watched = bytes <= WATCH_BYTES
	state.text = if state.watched then text :: string else nil
	build(state, text :: string)
	return true
end

--- Whether the pane still runs: a block that ended is gone from the list.
local function running(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function watch(state: State, cx: BlockCx): ()
	if not state.watched or state.path == nil then
		return
	end
	-- The whole text, so an edit that keeps the length still reloads.
	local last = state.text or ""
	local function poll()
		if not running(cx.pane) or not state.watched then
			return
		end
		local path = state.path
		if path ~= nil then
			local ok, text = pcall(tern.fs.read, path, WATCH_BYTES)
			if ok and type(text) == "string" and text ~= last then
				last = text
				if reload(state) then
					cx:render()
				end
			end
		end
		tern.timer(WATCH_MS, poll)
	end
	tern.timer(WATCH_MS, poll)
end

local def: BlockDef<State> = {
	init = function(cx, args, _saved)
		local path = args[1]
		local state: State = {
			cx = cx,
			path = path,
			name = if path == nil then "Canvas Viewer" else base_name(path),
			format = if path == nil then "" else string.upper(string.sub(suffix(path), 2)),
			shapes = {},
			count = 0,
			notes = {},
			bytes = 0,
			watched = false,
		}
		if path == nil then
			state.problem = {
				title = "Canvas Viewer needs a file",
				text = "open a .excalidraw or .tldraw file from the Files pane, the palette, or `tern open`",
			}
			return state
		end
		if reload(state) then
			watch(state, cx)
		end
		return state
	end,
	title = function(state)
		return state.name
	end,
	view = function(state, cx)
		if state.problem ~= nil then
			local problem = state.problem :: Problem
			return {
				main = ui.col({
					ui.card(problem.title, {
						ui.text({ ui.span(problem.text, "muted") }),
					}),
				}),
			}
		end
		local box = state.box or { 0, 0, 0, 0 }
		local dock = ui.row({
			ui.text({
				ui.span(state.format, "strong"),
				ui.span(" · " .. tostring(state.count) .. " shapes"),
				ui.span(string.format(" · %d×%d", math.floor(box[3]), math.floor(box[4])), "muted"),
				ui.span(" · r reload", "muted"),
				ui.span(" · o open as text", "muted"),
				ui.span(" · y copy path", "muted"),
			}),
		})
		local main = {
			ui.node("image", { blob = state.blob, alt = state.name, w = box[3], h = box[4], role = "canvas-viewer.drawing" }),
		}
		for _, note in ipairs(state.notes) do
			table.insert(main, ui.text({ ui.span(note, "warning") }))
		end
		return { main = ui.col(main), dock = dock }
	end,
	key = function(state, key, cx)
		local name = key.name
		if name == "r" then
			reload(state)
			return true
		end
		if name == "o" and state.path ~= nil then
			cx:open(state.path :: string)
			return false
		end
		if name == "y" and state.path ~= nil then
			cx:copy(state.path :: string)
			cx:toast("success", "Path copied", state.path :: string)
			return false
		end
		return false
	end,
}

tern.block.define("view", def)