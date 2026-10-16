--!strict
-- The window half: a plain open of a `.excalidraw` or `.tldraw` file goes to
-- the Canvas Viewer block instead of the editor, unless the palette command
-- "Toggle canvas preview for .excalidraw and .tldraw opens" turned that off.
-- An open that asks for a line or column still goes to the editor, and
-- "Open with › Canvas Viewer" works whichever way the switch is set.

local ROUTE_KEY = "route_canvas"

local function enabled(): boolean
	-- Absent means on. `tern.kv` is one store for every window, so a toggle in
	-- one window applies in the others at once.
	return tern.kv.get(ROUTE_KEY) ~= false
end

local function claims(path: string): boolean
	local ext = string.lower(string.match(path, "%.[^./]+$") or "")
	return ext == ".excalidraw" or ext == ".tldraw"
end

tern.command({
	id = "toggle_route",
	title = "Toggle canvas preview for .excalidraw and .tldraw opens",
	icon = "image",
	run = function(cx: WindowCx)
		local on = not enabled()
		tern.kv.set(ROUTE_KEY, on)
		if on then
			cx:toast("success", "Canvas files open in Canvas Viewer", "From the Files pane and the palette")
		else
			cx:toast("info", "Canvas files open in the editor", "Open with › Canvas Viewer still works")
		end
	end,
})

tern.route.open(function(req: OpenRequest, _cx: WindowCx): RouteDecision?
	if not enabled() then
		return nil
	end
	if req.line ~= nil then
		return nil
	end
	if not claims(req.path) then
		return nil
	end
	return { block = "canvas-viewer.view", args = { req.path } }
end)