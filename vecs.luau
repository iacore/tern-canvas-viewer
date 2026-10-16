--!strict
-- Decodes the base64 point stream a tldraw free-draw segment stores
-- (`b64Vecs`, packages/tlschema/src/misc/b64Vecs.ts): the first point as
-- Float32 little-endian (two or three of them), every point after it as
-- little-endian Float16 deltas that accumulate into absolute positions.
--
-- Luau's `buffer` reads host floats with its own endianness rules and has no
-- Float16 read, so both widths are decoded here from the bytes.

local M = {}

local function f32(s: string, i: number): number
	local b0, b1, b2, b3 = string.byte(s, i, i + 3)
	if b3 == nil then
		return 0
	end
	local sign = if b3 >= 128 then -1 else 1
	local exp = (b3 % 128) * 2 + math.floor(b2 / 128)
	local frac = (b2 % 128) * 65536 + b1 * 256 + b0
	if exp == 0 then
		return sign * frac * 2 ^ -149
	end
	if exp == 255 then
		return if frac == 0 then sign * math.huge else 0 / 0
	end
	return sign * (1 + frac / 8388608) * 2 ^ (exp - 127)
end

local function f16(s: string, i: number): number
	local b0, b1 = string.byte(s, i, i + 1)
	if b1 == nil then
		return 0
	end
	local bits = b0 + b1 * 256
	local sign = if bits >= 32768 then -1 else 1
	local exp = math.floor((bits % 32768) / 1024)
	local frac = bits % 1024
	if exp == 0 then
		return sign * frac * (2 ^ -14 / 1024)
	end
	if exp == 31 then
		return if frac == 0 then sign * math.huge else 0 / 0
	end
	return sign * (1 + frac / 1024) * 2 ^ (exp - 15)
end

export type Point = { x: number, y: number, z: number }

--- Points of one encoded segment; `dim` is the segment's own `dim` field
--- (2 for x/y only, anything else for x/y/z).
function M.decode_points(encoded: string, dim: any): { Point }
	local points: { Point } = {}
	if type(encoded) ~= "string" or encoded == "" then
		return points
	end
	local ok, bytes = pcall(tern.base64.decode, encoded)
	if not ok or #bytes < 4 then
		return points
	end
	local two_d = tonumber(dim) == 2
	local first = if two_d then 8 else 12
	if #bytes < first then
		return points
	end
	local x, y = f32(bytes, 1), f32(bytes, 5)
	local z = if two_d then 0.5 else f32(bytes, 9)
	table.insert(points, { x = x, y = y, z = z })
	local step = if two_d then 4 else 6
	local at = first + 1
	while at + step - 1 <= #bytes do
		x += f16(bytes, at)
		y += f16(bytes, at + 2)
		if not two_d then
			z += f16(bytes, at + 4)
		end
		table.insert(points, { x = x, y = y, z = z })
		at += step
	end
	return points
end

return M