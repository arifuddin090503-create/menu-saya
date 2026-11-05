--[[
	Growblox — WindUI script
	celineasher/growblox
 
	Features: auto collect, auto mine (hold-to-break, name filter, single/multi),
	fly, noclip, speed.
 
	Load:
		loadstring(game:HttpGet("https://raw.githubusercontent.com/celineasher/growblox/main/growblox.lua"))()
 
	Window toggle: RightShift
 
	------------------------------------------------------------------
	AUTO MINE — READ THIS
	------------------------------------------------------------------
	The block-breaking internals could not be verified against a live
	client. Everything that depends on unknown game internals is
	isolated in worldTiles() / tileId() / blockName() / detectMinePath()
	/ breakTile() and marked -- UNVERIFIED.
 
	If Auto Mine does nothing or errors on first run, press the
	"Mine Diagnostics" button and read the console. That output tells
	us which guessed field name is wrong, and the fix is localised to
	the TILE_FIELDS / TILE_ID_FIELDS tables at the top of the mine
	section.
	------------------------------------------------------------------
 
	FIX LOG (auto collect):
	- Forward declarations: FlyToggle / AutoToggle / MineToggle / notify /
	  setAutoMine / getPos are now declared at the top, so functions defined
	  earlier no longer see nil globals.
	- pickDrop uses pairs() instead of ipairs(), so it also works when
	  dropList() returns a table keyed by uid (Status showed "Drops: N" but
	  auto collect found nothing).
	- Drops with non-number x/y are skipped instead of throwing an error that
	  silently turned Auto Collect off.
	- Un-armed drops no longer cause an endless step-back loop; after a few
	  attempts the drop is skipped.
	- If the collect loop errors, the reason is printed and shown in a notify.
	- Target = the dropped item nearest to the player (straight-line
	  distance), re-checked every tick so a closer drop takes over.
]]
 
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local RS = game:GetService("ReplicatedStorage")
 
if _G.GrowbloxLoaded and _G.GrowbloxLoaded.Destroy then
	pcall(_G.GrowbloxLoaded.Destroy)
end
_G.GrowbloxLoaded = nil
 
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
local ItemDB = require(RS.Shared.ItemDB)
 
local state = {
	running = true,
	autoCollect = false,
	fly = false,
	noclip = false,
	speed = false,
	speedMult = 1.8,
	range = 80,
 
	autoMine = false,
	mineSingle = false,
	mineFilter = "",
	mineRadius = 40,
	mineHold = 1.5,
	mineDelay = 0.15,
 
	speedApplied = false,
}
 
local world
local renderFn
local solidAt
local solidOriginal
local posIndex
local posLastCalibration = 0
local calibrating = false
 
-- FIX: forward declarations (these were used before their `local` line,
-- so they resolved to nil globals).
local AutoToggle, MineToggle, FlyToggle, NoclipToggle, SpeedToggle, StatusParagraph
local notify, setAutoMine, getPos
 
-- ==================================================================
-- WORLD DISCOVERY (verified — same technique as the original script)
-- ==================================================================
 
local function getWorld()
	if world then
		local ok = pcall(function()
			return world.name
		end)
		if ok then
			return world
		end
	end
	world = nil
	for _, obj in pairs(getgc(true)) do
		if type(obj) == "table" and rawget(obj, "dropList") and rawget(obj, "fg") and rawget(obj, "goTo") then
			world = obj
			return world
		end
	end
end
 
local function getRender()
	if renderFn then
		return renderFn
	end
	local w = getWorld()
	if not w then
		return nil
	end
	local best, bestSize = nil, 0
	for _, obj in pairs(getgc(true)) do
		if type(obj) == "function" then
			local ok, ups = pcall(getupvalues, obj)
			if ok and #ups > bestSize then
				local has = false
				for _, u in pairs(ups) do
					if u == w then
						has = true
						break
					end
				end
				if has then
					best, bestSize = obj, #ups
				end
			end
		end
	end
	if best then
		renderFn = best
	end
	return renderFn
end
 
local function getSolidAt()
	if solidAt then
		return solidAt
	end
	local w = getWorld()
	if not w then
		return nil
	end
	for _, f in pairs(getgc(true)) do
		if type(f) == "function" then
			local ok, ups = pcall(getupvalues, f)
			if ok and #ups == 2 then
				local hasWorld, hasItemDB = false, false
				for _, u in pairs(ups) do
					if u == w then
						hasWorld = true
					end
					if u == ItemDB then
						hasItemDB = true
					end
				end
				if hasWorld and hasItemDB then
					local ok2, negW = pcall(f, -1, 0)
					local ok3, negH = pcall(f, 0, -1)
					local ok4, bigW = pcall(f, w.w, 0)
					if ok2 and ok3 and ok4 and negW == true and bigW == true and negH == false then
						solidAt = f
						return f
					end
				end
			end
		end
	end
end
 
local function getCandidates()
	local r = getRender()
	local w = getWorld()
	if not (r and w) then
		return {}
	end
	local ok, ups = pcall(getupvalues, r)
	if not ok then
		return {}
	end
	local list = {}
	for i, v in pairs(ups) do
		local ny = ups[i + 1]
		if type(v) == "number" and type(ny) == "number" then
			if v >= 0.3 and v <= w.w - 0.3 and ny >= 0.95 and ny <= w.h then
				list[#list + 1] = { i = i, x = v, y = ny }
			end
		end
	end
	table.sort(list, function(a, b)
		return a.i < b.i
	end)
	return list
end
 
local function readPos()
	local r = getRender()
	if not (r and posIndex) then
		return nil
	end
	local ok, ups = pcall(getupvalues, r)
	if not ok then
		return nil
	end
	local x, y = ups[posIndex], ups[posIndex + 1]
	if type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	return x, y
end
 
-- ==================================================================
-- AUTO MINE
-- ==================================================================
 
-- UNVERIFIED: candidate field names for the tile container on world.
local TILE_FIELDS = { "tiles", "blocks", "grid", "map", "tileData", "blockData" }
-- UNVERIFIED: candidate field names for a tile's block id.
local TILE_ID_FIELDS = { "id", "item", "block", "type", "itemId", "blockId" }
 
local function worldTiles()
	local w = getWorld()
	if not w then
		return nil, "no world"
	end
	for _, field in ipairs(TILE_FIELDS) do
		local ok, val = pcall(function()
			return w[field]
		end)
		if ok and type(val) == "table" then
			return val, "world." .. field
		end
	end
	return nil, "no tile field found"
end
 
local function tileId(tile)
	if type(tile) == "number" then
		return tile
	end
	if type(tile) ~= "table" then
		return nil
	end
	for _, field in ipairs(TILE_ID_FIELDS) do
		local v = tile[field]
		if type(v) == "number" then
			return v
		end
	end
	return nil
end
 
local function blockName(id)
	if not id then
		return nil
	end
	local ok, entry = pcall(function()
		return ItemDB[id]
	end)
	if ok and type(entry) == "table" then
		return entry.name or entry.Name or entry.displayName or entry.title
	end
	if ok and type(entry) == "string" then
		return entry
	end
	return nil
end
 
local function tileMatches(tile)
	if state.mineFilter == "" then
		return true
	end
	local id = tileId(tile)
	local name = blockName(id)
	if not name then
		return false
	end
	return string.find(string.lower(name), string.lower(state.mineFilter), 1, true) ~= nil
end
 
local function readTileDurability(tile)
	if type(tile) ~= "table" then
		return nil
	end
	for _, field in ipairs({ "durability", "health", "hp", "progress", "hits" }) do
		local v = tile[field]
		if type(v) == "number" then
			return v
		end
	end
	return nil
end
 
local mineFn
local function detectMinePath()
	if mineFn then
		return mineFn
	end
	local w = getWorld()
	if not w then
		return nil, "no world"
	end
	for _, f in pairs(getgc(true)) do
		if type(f) == "function" then
			local ok, ups = pcall(getupvalues, f)
			if ok and #ups >= 2 and #ups <= 6 then
				local hasWorld, hasItemDB = false, false
				for _, u in pairs(ups) do
					if u == w then
						hasWorld = true
					end
					if u == ItemDB then
						hasItemDB = true
					end
				end
				if hasWorld and hasItemDB and f ~= solidAt then
					mineFn = f
					return f
				end
			end
		end
	end
	return nil, "no mine function found"
end
 
local holding = false
local function setHold(on)
	if holding == on then
		return
	end
	holding = on
	pcall(function()
		VIM:SendMouseButtonEvent(0, 0, 0, on, game, 0)
	end)
end
 
local function breakTile(tile)
	local fn = detectMinePath()
	local id = tileId(tile)
 
	if fn and id then
		local startDur = readTileDurability(tile)
		local ok = pcall(fn, id)
		if ok then
			if startDur then
				local t0 = os.clock()
				while os.clock() - t0 < state.mineHold do
					task.wait(0.05)
					local nowDur = readTileDurability(tile)
					if nowDur and nowDur < startDur then
						return true
					end
					if nowDur == nil then
						break
					end
				end
			end
			return true
		end
	end
 
	setHold(true)
	local t0 = os.clock()
	local startDur = readTileDurability(tile)
	while os.clock() - t0 < state.mineHold do
		task.wait(0.05)
		if startDur then
			local nowDur = readTileDurability(tile)
			if nowDur and nowDur < startDur then
				break
			end
		end
	end
	setHold(false)
	return true
end
 
local function matchingTiles(px, py)
	local container = worldTiles()
	if not container then
		return {}
	end
	local out = {}
	for key, tile in pairs(container) do
		if tileMatches(tile) then
			local tx, ty
			if type(tile) == "table" then
				tx, ty = tile.x, tile.y
			end
			local dist
			if type(tx) == "number" and type(ty) == "number" then
				dist = math.abs(tx - px) + math.abs(ty - py) * 2
			end
			if not dist or dist <= state.mineRadius then
				out[#out + 1] = { key = key, tile = tile, dist = dist or 9999 }
			end
		end
	end
	table.sort(out, function(a, b)
		return a.dist < b.dist
	end)
	return out
end
 
local function stepMine()
	if not state.autoMine then
		setHold(false)
		return
	end
	local w = getWorld()
	if not (w and w.name ~= "") then
		setHold(false)
		return
	end
 
	local px, py = getPos()
	if not px then
		return
	end
 
	local tiles = matchingTiles(px, py)
	if #tiles == 0 then
		setHold(false)
		return
	end
 
	if state.mineSingle then
		breakTile(tiles[1].tile)
		setAutoMine(false)
		if MineToggle then
			pcall(function()
				MineToggle:Set(false)
			end)
		end
		notify("Single block mined")
		return
	end
 
	for _, entry in ipairs(tiles) do
		if not state.autoMine or not state.running then
			break
		end
		breakTile(entry.tile)
		task.wait(state.mineDelay)
	end
end
 
-- ==================================================================
-- MOVEMENT / COLLECT
-- ==================================================================
 
local held = {}
local function setKey(code, down)
	if held[code] == down then
		return
	end
	held[code] = down
	pcall(function()
		VIM:SendKeyEvent(down, code, false, game)
	end)
end
 
local function releaseKeys()
	for code, down in pairs(held) do
		if down then
			pcall(function()
				VIM:SendKeyEvent(false, code, false, game)
			end)
		end
		held[code] = nil
	end
end
 
local function tapJump()
	setKey(Enum.KeyCode.Space, true)
	task.delay(0.1, function()
		if state.running then
			setKey(Enum.KeyCode.Space, false)
		end
	end)
end
 
local function tryMove(dir)
	local before = {}
	for _, c in ipairs(getCandidates()) do
		before[c.i] = c.x
	end
	setKey(dir, true)
	task.wait(0.35)
	setKey(dir, false)
	task.wait(0.08)
	local changed = {}
	for _, c in ipairs(getCandidates()) do
		local b = before[c.i]
		if b and math.abs(b - c.x) > 0.02 then
			changed[#changed + 1] = c
		end
	end
	return changed
end
 
local function calibrate()
	if calibrating then
		return false
	end
	local w = getWorld()
	if not (w and w.name ~= "") then
		return false
	end
	local list = getCandidates()
	if #list == 0 then
		return false
	end
	calibrating = true
	local cx = readPos()
	local dir = Enum.KeyCode.Right
	local other = Enum.KeyCode.Left
	if cx and cx > w.w - 3 then
		dir, other = Enum.KeyCode.Left, Enum.KeyCode.Right
	end
	local changed = tryMove(dir)
	if #changed == 0 then
		tapJump()
		task.wait(0.2)
		changed = tryMove(dir)
	end
	if #changed == 0 then
		changed = tryMove(other)
	end
	calibrating = false
	if #changed == 0 then
		return false
	end
	table.sort(changed, function(a, b)
		return a.i > b.i
	end)
	posIndex = changed[1].i
	return true
end
 
-- FIX: assign to the forward-declared local instead of creating a new one.
getPos = function()
	local x, y = readPos()
	if x and y then
		return x, y
	end
	local now = os.clock()
	if now - posLastCalibration > 4 then
		posLastCalibration = now
		calibrate()
		x, y = readPos()
		if x and y then
			return x, y
		end
	end
end
 
local collect = {
	uid = nil,
	lastX = nil,
	lastProgress = 0,
	stuck = 0,
	lastJump = 0,
	targetAt = 0,
	skip = {},
	backoff = {}, -- FIX: per-drop counter for un-armed step-back attempts
}
 
local function activeDrops()
	local w = getWorld()
	if not (w and w.name ~= "") then
		return {}
	end
	local ok, list = pcall(function()
		return w.dropList()
	end)
	if not ok or type(list) ~= "table" then
		return {}
	end
	return list
end
 
local function pickDrop(px, py)
	local list = activeDrops()
	local now = os.clock()
	local best, bestScore
	-- FIX: pairs() instead of ipairs() so a uid-keyed dropList also works.
	for _, d in pairs(list) do
		-- FIX: skip malformed entries instead of erroring (which used to
		-- silently disable Auto Collect).
		if type(d) == "table" and type(d.x) == "number" and type(d.y) == "number" then
			if not d.pending and not d.taking and not d.flown then
				local key = d.uid
				local skipAt = key ~= nil and collect.skip[key] or nil
				if not skipAt or skipAt < now then
					-- FIX: real straight-line distance from the player, so the
					-- nearest drop is always picked first (the old score
					-- doubled vertical distance and skipped closer drops
					-- that were above or below the player).
					local ddx, ddy = d.x - px, d.y - py
					local score = math.sqrt(ddx * ddx + ddy * ddy)
					if score <= state.range and (not best or score < bestScore) then
						best, bestScore = d, score
					end
				end
			end
		end
	end
	-- FIX: drop expired skip entries so the table does not grow forever.
	for k, t in pairs(collect.skip) do
		if t < now then
			collect.skip[k] = nil
			collect.backoff[k] = nil
		end
	end
	return best
end
 
local function stopWalk()
	setKey(Enum.KeyCode.Left, false)
	setKey(Enum.KeyCode.Right, false)
end
 
local function skipTarget(target, now)
	if target.uid ~= nil then
		collect.skip[target.uid] = now + 10
	end
	collect.uid = nil
	collect.stuck = 0
	stopWalk()
end
 
local function stepCollect()
	if not state.autoCollect then
		stopWalk()
		collect.uid = nil
		return
	end
	local w = getWorld()
	if not (w and w.name ~= "") then
		stopWalk()
		return
	end
	if state.fly then
		state.fly = false
		w.ghost = false
		if FlyToggle then
			pcall(function()
				FlyToggle:Set(false)
			end)
		end
	end
	local px, py = getPos()
	if not px then
		return
	end
	local target = pickDrop(px, py)
	if not target then
		stopWalk()
		collect.uid = nil
		return
	end
	if target.uid ~= collect.uid or collect.uid == nil then
		collect.uid = target.uid
		collect.lastX = px
		collect.lastProgress = os.clock()
		collect.stuck = 0
		collect.targetAt = os.clock()
	end
	local dx, dy = target.x - px, target.y - py
	if target.armed == false and target.id ~= 112 and math.abs(dx) < 1.0 then
		-- FIX: count attempts; the old code reset collect.uid every time, so
		-- the 8s timeout never fired and the player stepped back forever.
		local key = target.uid
		if key ~= nil then
			collect.backoff[key] = (collect.backoff[key] or 0) + 1
			if collect.backoff[key] > 6 then
				skipTarget(target, os.clock())
				return
			end
		end
		stopWalk()
		local away, toward
		if dx >= 0 then
			away, toward = Enum.KeyCode.Left, Enum.KeyCode.Right
		else
			away, toward = Enum.KeyCode.Right, Enum.KeyCode.Left
		end
		setKey(toward, false)
		setKey(away, true)
		task.wait(0.25)
		setKey(away, false)
		return
	end
	local moving = false
	if dx > 0.08 then
		setKey(Enum.KeyCode.Left, false)
		setKey(Enum.KeyCode.Right, true)
		moving = true
	elseif dx < -0.08 then
		setKey(Enum.KeyCode.Right, false)
		setKey(Enum.KeyCode.Left, true)
		moving = true
	else
		stopWalk()
	end
	local now = os.clock()
	if dy < -1.05 and now - collect.lastJump > 0.5 then
		collect.lastJump = now
		tapJump()
	end
	if moving then
		local last = collect.lastX or px
		if math.abs(px - last) < 0.02 then
			if now - collect.lastProgress > 0.5 then
				collect.lastProgress = now
				collect.stuck = collect.stuck + 1
				if collect.stuck <= 4 then
					tapJump()
				else
					skipTarget(target, now)
					return
				end
			end
		else
			collect.lastX = px
			collect.lastProgress = now
			collect.stuck = 0
		end
	else
		collect.lastX = px
		collect.lastProgress = now
	end
	if now - collect.targetAt > 8 then
		skipTarget(target, now)
	end
end
 
-- ==================================================================
-- TOGGLES
-- ==================================================================
 
-- FIX: assign to the forward-declared local.
notify = function(content, title)
	pcall(function()
		WindUI:Notify({
			Title = title or "Growblox",
			Content = content,
			Icon = "sprout",
			Duration = 3,
		})
	end)
end
 
local function setFly(on)
	state.fly = on
	local w = getWorld()
	if w then
		w.ghost = on
	end
	if on and state.autoCollect then
		state.autoCollect = false
		releaseKeys()
		if AutoToggle then
			pcall(function()
				AutoToggle:Set(false)
			end)
		end
	end
end
 
local function setAutoCollect(on)
	if on and state.fly then
		state.fly = false
		local w = getWorld()
		if w then
			w.ghost = false
		end
		if FlyToggle then
			pcall(function()
				FlyToggle:Set(false)
			end)
		end
	end
	state.autoCollect = on
	collect.uid = nil
	collect.skip = {}
	collect.backoff = {}
	if not on then
		releaseKeys()
	end
end
 
-- FIX: assign to the forward-declared local.
setAutoMine = function(on)
	state.autoMine = on
	if not on then
		setHold(false)
	end
end
 
local function setNoclip(on)
	state.noclip = on
	local f = getSolidAt()
	if on then
		if f then
			if not solidOriginal then
				solidOriginal = hookfunction(f, function()
					return false
				end)
			else
				hookfunction(f, function()
					return false
				end)
			end
			notify("Noclip enabled")
		else
			state.noclip = false
			if NoclipToggle then
				pcall(function()
					NoclipToggle:Set(false)
				end)
			end
			notify("Noclip is not available yet")
		end
	elseif f and solidOriginal then
		hookfunction(f, solidOriginal)
		notify("Noclip disabled")
	end
end
 
local function applySpeed()
	local w = getWorld()
	if not w then
		return
	end
	if state.speed and not state.fly then
		w.speedScale = state.speedMult
		state.speedApplied = true
	elseif state.speedApplied then
		w.speedScale = 1
		state.speedApplied = false
	end
end
 
local function setSpeed(on)
	state.speed = on
	applySpeed()
end
 
local function cleanup()
	state.running = false
	state.autoCollect = false
	state.autoMine = false
	setHold(false)
	releaseKeys()
	local w = getWorld()
	if w then
		pcall(function()
			w.ghost = false
		end)
		if state.speedApplied then
			pcall(function()
				w.speedScale = 1
			end)
		end
	end
	if solidAt and solidOriginal then
		pcall(function()
			hookfunction(solidAt, solidOriginal)
		end)
	end
end
 
-- ==================================================================
-- UI
-- ==================================================================
 
local Window = WindUI:CreateWindow({
	Title = "Growblox",
	Author = "celineasher/growblox",
	Icon = "sprout",
	Folder = "Growblox",
	ToggleKey = Enum.KeyCode.RightShift,
	Theme = "Dark",
	Transparent = true,
	Resizable = true,
	Size = UDim2.fromOffset(560, 460),
})
 
local MainTab = Window:Tab({ Title = "Main", Icon = "gamepad-2" })
local FarmSection = MainTab:Section({ Title = "Auto Farm" })
 
AutoToggle = FarmSection:Toggle({
	Title = "Auto Collect",
	Desc = "Walk to nearby drops and pick them up",
	Value = false,
	Callback = function(value)
		setAutoCollect(value)
		notify(value and "Auto collect enabled" or "Auto collect disabled")
	end,
})
 
FarmSection:Space()
FarmSection:Slider({
	Title = "Collect Range",
	Desc = "Maximum distance in tiles",
	Step = 5,
	Value = { Min = 10, Max = 200, Default = 80 },
	Callback = function(value)
		state.range = value
	end,
})
 
local MineSection = MainTab:Section({ Title = "Auto Mine" })
 
MineToggle = MineSection:Toggle({
	Title = "Auto Mine",
	Desc = "Hold-to-break matching blocks in range",
	Value = false,
	Callback = function(value)
		setAutoMine(value)
		notify(value and "Auto mine enabled" or "Auto mine disabled")
	end,
})
 
MineSection:Space()
MineSection:Input({
	Title = "Block Filter",
	Desc = "Only mine blocks whose name contains this (blank = any)",
	Value = "",
	Placeholder = "e.g. Stone",
	Callback = function(value)
		state.mineFilter = value or ""
	end,
})
 
MineSection:Space()
MineSection:Toggle({
	Title = "Single Block Mode",
	Desc = "Mine one block then stop (off = mine all in range)",
	Value = false,
	Callback = function(value)
		state.mineSingle = value
	end,
})
 
MineSection:Space()
MineSection:Slider({
	Title = "Mine Radius",
	Desc = "Maximum distance in tiles",
	Step = 5,
	Value = { Min = 5, Max = 120, Default = 40 },
	Callback = function(value)
		state.mineRadius = value
	end,
})
 
MineSection:Space()
MineSection:Slider({
	Title = "Hold Time",
	Desc = "Max seconds to hold per block before moving on",
	Step = 0.1,
	Value = { Min = 0.3, Max = 5, Default = 1.5 },
	Callback = function(value)
		state.mineHold = value
	end,
})
 
MineSection:Space()
MineSection:Slider({
	Title = "Block Delay",
	Desc = "Pause between blocks in multi mode",
	Step = 0.05,
	Value = { Min = 0, Max = 1, Default = 0.15 },
	Callback = function(value)
		state.mineDelay = value
	end,
})
 
local MoveSection = MainTab:Section({ Title = "Movement" })
 
FlyToggle = MoveSection:Toggle({
	Title = "Fly",
	Desc = "Ghost flight with arrow keys, Space and Down",
	Value = false,
	Callback = function(value)
		setFly(value)
		notify(value and "Fly enabled" or "Fly disabled")
	end,
})
 
MoveSection:Space()
NoclipToggle = MoveSection:Toggle({
	Title = "Noclip",
	Desc = "Walk through walls",
	Value = false,
	Callback = function(value)
		setNoclip(value)
	end,
})
 
MoveSection:Space()
SpeedToggle = MoveSection:Toggle({
	Title = "Speed Boost",
	Desc = "Multiplies walking speed",
	Value = false,
	Callback = function(value)
		setSpeed(value)
		notify(value and "Speed enabled" or "Speed disabled")
	end,
})
 
MoveSection:Space()
MoveSection:Slider({
	Title = "Speed Multiplier",
	Desc = "Values above 1.8 may trigger anti-cheat",
	Step = 0.1,
	Value = { Min = 1, Max = 3, Default = 1.8 },
	Callback = function(value)
		state.speedMult = value
		applySpeed()
	end,
})
 
local ActionSection = MainTab:Section({ Title = "Actions" })
 
ActionSection:Button({
	Title = "Reset Movement",
	Desc = "Turn off fly, speed and noclip",
	Callback = function()
		setFly(false)
		setSpeed(false)
		setNoclip(false)
		local w = getWorld()
		if w then
			w.ghost = false
			w.speedScale = 1
		end
		state.speedApplied = false
		releaseKeys()
		pcall(function()
			FlyToggle:Set(false)
		end)
		pcall(function()
			SpeedToggle:Set(false)
		end)
		pcall(function()
			NoclipToggle:Set(false)
		end)
		notify("Movement reset")
	end,
})
 
ActionSection:Space()
ActionSection:Button({
	Title = "Mine Diagnostics",
	Desc = "Dump what auto mine found (check console)",
	Callback = function()
		local w = getWorld()
		print("[Growblox] world:", w ~= nil)
		if w then
			print("[Growblox] world.name:", w.name)
			print("[Growblox] world.w, world.h:", w.w, w.h)
		end
		local container, where = worldTiles()
		print("[Growblox] tile container:", container ~= nil, where)
		if container then
			local n = 0
			for k, v in pairs(container) do
				n = n + 1
				if n <= 5 then
					print("[Growblox] sample tile", k, "type=" .. type(v), "id=" .. tostring(tileId(v)), "name=" .. tostring(blockName(tileId(v))))
				end
			end
			print("[Growblox] total tiles:", n)
		end
		local fn, err = detectMinePath()
		print("[Growblox] mine function:", fn ~= nil, err)
		notify("Diagnostics printed to console")
	end,
})
 
ActionSection:Space()
ActionSection:Button({
	Title = "Unload Script",
	Color = Color3.fromHex("#ff4830"),
	Callback = function()
		cleanup()
		_G.GrowbloxLoaded = nil
		pcall(function()
			Window:Destroy()
		end)
	end,
})
 
local InfoTab = Window:Tab({ Title = "Info", Icon = "info" })
local InfoSection = InfoTab:Section({ Title = "Status" })
 
StatusParagraph = InfoSection:Paragraph({
	Title = "Status",
	Desc = "Loading...",
})
 
InfoSection:Space()
InfoSection:Paragraph({
	Title = "Auto Mine",
	Desc = "Set a block name filter (blank mines anything), pick single or multi mode, then enable. Multi mines every matching block in radius, nearest first. Use Mine Diagnostics if it does nothing.",
})
 
InfoSection:Space()
InfoSection:Paragraph({
	Title = "Fly",
	Desc = "Uses the game's ghost mode. Move with arrow keys, fly up with Space or Up, and down with Down. Auto Collect turns Fly off.",
})
 
InfoSection:Space()
InfoSection:Paragraph({
	Title = "Warnings",
	Desc = "Speed above 1.8x and Noclip can trigger the game's anti-cheat. Use moderate values and enable them only when needed.",
})
 
-- ==================================================================
-- LOOPS
-- ==================================================================
 
task.spawn(function()
	while state.running do
		task.wait(0.05)
		if not state.running then
			break
		end
		local ok, err = pcall(stepCollect)
		if not ok then
			-- FIX: report the error instead of silently turning off.
			warn("[Growblox] auto collect error: " .. tostring(err))
			setAutoCollect(false)
			if AutoToggle then
				pcall(function()
					AutoToggle:Set(false)
				end)
			end
			notify("Auto collect stopped: " .. tostring(err))
		end
	end
end)
 
task.spawn(function()
	while state.running do
		task.wait(0.1)
		if not state.running then
			break
		end
		if state.autoMine then
			local ok, err = pcall(stepMine)
			if not ok then
				warn("[Growblox] auto mine error: " .. tostring(err))
				setAutoMine(false)
				if MineToggle then
					pcall(function()
						MineToggle:Set(false)
					end)
				end
				notify("Auto mine stopped: internal error")
			end
		end
	end
end)
 
task.spawn(function()
	while state.running do
		task.wait(0.5)
		if not state.running then
			break
		end
		local w = getWorld()
		local worldName = w and w.name ~= "" and w.name or "Menu"
		local drops = 0
		if w and w.name ~= "" then
			local ok, list = pcall(function()
				return w.dropList()
			end)
			if ok and type(list) == "table" then
				for _ in pairs(list) do
					drops = drops + 1
				end
			end
		end
		local px, py = readPos()
		local posText = px and string.format("%.1f, %.1f", px, py) or "not calibrated"
		local speedText = state.speed and string.format(" (%.1fx)", state.speedMult) or ""
		local text = string.format(
			"World: %s\nDrops: %d\nPosition: %s\n\nAuto Collect: %s\nAuto Mine: %s\nFly: %s\nNoclip: %s\nSpeed: %s%s",
			worldName,
			drops,
			posText,
			state.autoCollect and "ON" or "OFF",
			state.autoMine and (state.mineSingle and "ON (single)" or "ON (multi)") or "OFF",
			state.fly and "ON" or "OFF",
			state.noclip and "ON" or "OFF",
			state.speed and "ON" or "OFF",
			speedText
		)
		pcall(function()
			StatusParagraph:SetDesc(text)
		end)
		applySpeed()
	end
end)
 
_G.GrowbloxLoaded = {
	Destroy = function()
		cleanup()
		pcall(function()
			Window:Destroy()
		end)
	end,
	state = state,
	getWorld = getWorld,
	getRender = getRender,
	getCandidates = getCandidates,
	getSolidAt = getSolidAt,
	calibrate = calibrate,
	readPos = readPos,
	getPos = getPos,
	worldTiles = worldTiles,
	tileId = tileId,
	blockName = blockName,
	detectMinePath = detectMinePath,
	setFly = setFly,
	setNoclip = setNoclip,
	setSpeed = setSpeed,
	setAutoCollect = setAutoCollect,
	setAutoMine = setAutoMine,
	applySpeed = applySpeed,
}
 
notify("Loaded. Press RightShift to open.")
 
