--[[
	BOOTH SERVER — FULL REMADE VERSION (r45 / 2021 client)
	=====================================================
	WHERE:  ServerScriptService -> Script "Server"  (REPLACE the whole
	        existing booth/admin Server script with this file)

	This is the complete booth + staff panel server script from r45, with
	the image-log hook integrated into HandleChangeImage. Every image
	uploaded to a booth is now fired into ReplicatedStorage.AdminPanel
	.BoothImageLog, which AdminPanelServer records permanently.

	Everything else (booths, gamepasses, staff ranks, moderation commands,
	Adonis sync, reports) is byte-for-byte the original r45 script.

	The two companion scripts:
	  * AdminPanelServer.lua  (ServerScriptService) — permanent image log
	  * AdminPanelClient.lua  (StarterGui)          — Jarvis glass panel

	2021 compatible.
--]]

--[[
	Booth server script  (ServerScriptService)

	Original booth system by ywinfe and thugshaker.

	Written for Roblox/Luau 2021 and earlier:
	  * no task.*, no attributes, no string interpolation
	  * only wait(), tick(), pcall(), type()

	Gamepasses (all Pekora catalog assets, bought with PromptPurchase):
	  UPLOAD      set the image on the booth you claimed
	  BOOMBOX     grants a working boombox tool
	  PERMANENT   your image STAYS on that booth after you leave

	Permanent images are saved per booth (by index) in a DataStore, so they
	survive unclaim, disconnect and server restarts. The next player to claim
	that booth inherits the image, and can only replace it if they own UPLOAD.

	Requirements:
	  * ReplicatedStorage.RemoteEvent
	  * Workspace.Booths.<Booth>.Display.SurfaceGui.ImageLabel / .TextLabel
	    Workspace.Booths.<Booth>.Display.Attachment.ProximityPrompt
	    Workspace.Booths.<Booth>.Display.BoothOwner (ObjectValue)
	    Workspace.Booths.<Booth>.PartNamePlayer.SurfaceGui.TextLabel
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")

local RemoteEvent = ReplicatedStorage:WaitForChild("RemoteEvent")

-- Find-or-create. Never WaitForChild here: if the folder is missing the whole
-- script would hang forever and nothing would be claimable.
local Booths = Workspace:FindFirstChild("Booths")
if not Booths then
	Booths = Instance.new("Folder")
	Booths.Name = "Booths"
	Booths.Parent = Workspace
end

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

-- Shown on unclaimed booths and on any booth with no saved image.
local DEFAULT_IMAGE = "rbxassetid://821176"

local FILTER_TEXT = true -- set false if FilterStringAsync is unavailable
local MAX_TEXT_LENGTH = 120
local ACTION_COOLDOWN = 1 -- seconds between remote actions per player

local USE_DATASTORE = true -- false = permanent images last only this server
local DATASTORE_NAME = "BoothImages_v1"
local SAVE_RETRIES = 3

-------------------------------------------------------------------------------
-- Gamepasses
-------------------------------------------------------------------------------
--[[
	On Pekora, real game passes do not work, so passes are sold as catalog
	shirts. Every entry here is therefore an ASSET:

	    ownership -> MarketplaceService:PlayerOwnsAsset(Player, Id)
	    purchase  -> MarketplaceService:PromptPurchase(Player, Id)
	    finished  -> MarketplaceService.PromptPurchaseFinished

	IsGamePass is left in only in case Pekora ever fixes real passes; keep it
	false for /catalog/ links. Ids come straight from the URL:
	    https://www.pekora.zip/catalog/356360/Thugshaker-fan-shirt
	                                   ^^^^^^
--]]

--[[
	Icon is the picture shown on the shop card. Fill these in with an asset id
	when you have them, exactly like this:

	    Icon = "rbxassetid://123456789",

	Leave it as "" and the card draws a plain placeholder box instead, so the
	shop still looks right with no icons set.

	Price is only the label printed on the card. It does not charge anything;
	the real price is whatever the catalog item costs.
--]]

-- The three built in passes. These can never be deleted from the admin panel,
-- because UPLOAD / PERMANENT / BOOMBOX are wired into the booth logic.
local BUILTIN_PASSES = {
	UPLOAD = {
		Id = 356360,
		IsGamePass = false,
		Category = "Passes",
		Title = "Image Upload",
		Blurb = "Put your own image on the booth you claim.",
		Icon = "",
		Price = "Gamepass",
		Order = 1,
		Builtin = true,
	},
	PERMANENT = {
		Id = 353447,
		IsGamePass = false,
		Category = "Passes",
		Title = "Permanent Image",
		Blurb = "Your image stays on the booth after you leave.",
		Icon = "",
		Price = "Gamepass",
		Order = 2,
		Builtin = true,
	},
	BOOMBOX = {
		Id = 353454,
		IsGamePass = false,
		Category = "Passes",
		Title = "Boombox",
		Blurb = "Carry a boombox and play any audio ID.",
		Icon = "",
		Price = "Gamepass",
		Order = 3,
		Builtin = true,
	},
}

-- Live table: built ins plus anything added through the admin panel.
local PASSES = {}

-- Rebuilt whenever the pass list changes; never hand write these.
local SHOP_ORDER = {}
local ById = {}

-- Sidebar tabs, in order. A tab with nothing in it shows an empty message.
local SHOP_CATEGORIES = {"Passes", "Items"}

-------------------------------------------------------------------------------
-- Staff ranks
-------------------------------------------------------------------------------
--[[
	Three ranks, highest wins:

	    3  Owner   everything, and the only rank that can hand out Admin
	    2  Admin   everything except touching an Owner, can whitelist Mod/Admin
	    1  Mod     day to day moderation and the report queue
	    0  Player  no panel at all

	The Owner list is hard coded on purpose: it is the one thing that cannot
	be changed from inside the game, so nobody can promote themselves out of
	a mistake or lock the real owner out.

	Everyone else lives in a DataStore whitelist that staff edit from the
	panel, keyed by UserId. UserIds come straight off a profile URL:

	    https://www.pekora.zip/users/49603/profile
	                                 ^^^^^
	Names are only ever stored for display. Permission is always by UserId,
	so a rename can never silently grant or drop access.
--]]

local RANK_NONE = 0
local RANK_MOD = 1
local RANK_ADMIN = 2
local RANK_DEV = 3
local RANK_OWNER = 4

local RANK_NAME = {}
RANK_NAME[RANK_NONE] = "Player"
RANK_NAME[RANK_MOD] = "Mod"
RANK_NAME[RANK_ADMIN] = "Admin"
RANK_NAME[RANK_DEV] = "Developer"
RANK_NAME[RANK_OWNER] = "Owner"

--[[
	Developer sits above Admin and below Owner.

	Everything is compared with >= rather than against a specific number, so
	adding a rank in the middle needs no other change: a Developer inherits
	every Admin power automatically, and the "cannot promote to your own rank
	or above" rule keeps working without being told about the new one.

	The only thing Developer does NOT get is handing out Admin and above, which
	stays Owner-only, and being demoted by an Admin.
--]]

-- Hard coded, never editable in game.
local OWNERS = {
	[49603] = "thugshaker",
	[78857] = "qzc",
	[181869] = "ywinfe",
}

--[[
	Also hard coded. These are the people who built the place, so their rank
	comes from the script rather than the whitelist for the same reason the
	Owner's does: it cannot be revoked from inside the game, by anyone,
	including by each other.
--]]
local DEVELOPERS = {
    [18205] = "vxy",
}

-- Seeded into the whitelist the first time the place boots. After that the
-- saved list wins, so a demotion made in the panel is not undone by a restart.
-- Owners and Developers are not listed here; they come from the tables above.
local DEFAULT_STAFF = {}

-- Also let whoever owns the place in, so you are never locked out.
local ALLOW_PLACE_OWNER = true

local PASS_DATASTORE = "ShopPasses_v1"
local STAFF_DATASTORE = "StaffList_v2"
local BAN_DATASTORE = "Bans_v1"
local REPORT_DATASTORE = "Reports_v1"

-- Player-facing wording never names the shirts.
local PASS_WORD = "Gamepass"

local OWNERSHIP_CACHE_SECONDS = 30

-------------------------------------------------------------------------------
-- Avatar thumbnails
-------------------------------------------------------------------------------
--[[
	The panel greets whoever opened it with their own headshot, and the player
	list draws one per row.

	Asking the site directly from inside the game is blocked, so every request
	goes through the proxy instead. Same paths, different host:

	    https://koroneproxy.onrender.com/apisite/thumbnails/v1/users/avatar
	        ?userIds=49603&size=420x420&format=png
	    https://koroneproxy.onrender.com/apisite/avatar/v1/users/49603/avatar

	Both answer with JSON. Thumbnails come back as
	    {"data":[{"targetId":49603,"state":"Completed","imageUrl":"..."}]}

	Nothing here is load bearing: if HTTP is off, the proxy is asleep, or the
	JSON changes shape, the panel just falls back to the client's own
	GetUserThumbnailAsync and then to a plain initial, and every other feature
	carries on working.
--]]

local PROXY_BASE = "https://koroneproxy.onrender.com"
local THUMB_SIZE = "420x420"
local THUMB_CACHE_SECONDS = 900

local HeadshotCache = {} -- [userId] = {Url = string or false, Time = number}
local HeadshotBusy = {} -- [userId] = true while a request is in flight
local HttpWarned = false

local function HttpGetJson(url)
	local ok, res = pcall(function()
		return HttpService:GetAsync(url, true)
	end)
	if not ok then
		if not HttpWarned then
			HttpWarned = true
			warn("[Avatar] HTTP request failed, falling back to client thumbnails: " .. tostring(res))
		end
		return nil
	end

	local decoded
	local ok2, err = pcall(function()
		decoded = HttpService:JSONDecode(res)
	end)
	if not ok2 then
		warn("[Avatar] Could not read the proxy reply: " .. tostring(err))
		return nil
	end
	return decoded
end

-- Pulls the first usable imageUrl out of a thumbnails batch reply.
local function ReadThumbUrl(body)
	if type(body) ~= "table" then
		return nil
	end
	local data = body.data
	if type(data) ~= "table" then
		return nil
	end
	for _, row in pairs(data) do
		if type(row) == "table" and type(row.imageUrl) == "string" and row.imageUrl ~= "" then
			return row.imageUrl
		end
	end
	return nil
end

-- Yields. Always call from inside spawn().
local function FetchHeadshot(userId)
	local url = PROXY_BASE .. "/apisite/thumbnails/v1/users/avatar-headshot?userIds="
		.. tostring(userId) .. "&size=" .. THUMB_SIZE .. "&format=png"

	local found = ReadThumbUrl(HttpGetJson(url))

	if not found then
		-- Older builds of the proxy only carry the full body endpoint.
		url = PROXY_BASE .. "/apisite/thumbnails/v1/users/avatar?userIds="
			.. tostring(userId) .. "&size=" .. THUMB_SIZE .. "&format=png"
		found = ReadThumbUrl(HttpGetJson(url))
	end

	HeadshotCache[userId] = {Url = found or false, Time = tick()}
	return found
end

-- Non blocking. Hands back what is cached now, and refreshes in the
-- background so the next caller gets a real answer.
local function HeadshotFor(userId, onReady)
	userId = tonumber(userId)
	if not userId then
		return nil
	end

	local cached = HeadshotCache[userId]
	if cached and (tick() - cached.Time) < THUMB_CACHE_SECONDS then
		if cached.Url and onReady then
			onReady(cached.Url)
		end
		return cached.Url or nil
	end

	if not HeadshotBusy[userId] then
		HeadshotBusy[userId] = true
		spawn(function()
			local found = FetchHeadshot(userId)
			HeadshotBusy[userId] = nil
			if found and onReady then
				onReady(found)
			end
		end)
	end

	if cached then
		return cached.Url or nil
	end
	return nil
end

-- Avatar data for the player inspector: what the target is actually wearing.
-- Yields, so it is only ever called from a spawn().
local function FetchAvatarData(userId)
	local body = HttpGetJson(PROXY_BASE .. "/apisite/avatar/v1/users/" .. tostring(userId) .. "/avatar")
	if type(body) ~= "table" then
		return nil
	end

	local worn = 0
	if type(body.assets) == "table" then
		for _ in pairs(body.assets) do
			worn = worn + 1
		end
	end

	local scales = body.scales
	local height = nil
	if type(scales) == "table" then
		height = scales.height
	end

	return {
		Worn = worn,
		Type = body.playerAvatarType,
		Height = height,
	}
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local LastAction = {} -- [Player]           = tick() of last accepted action
local LastCheck = {} -- [Player]           = tick() of last passive refresh
local Ownership = {} -- [Player][Key]      = {Owns = bool, Time = number}
local BoothIndex = {} -- [Booth]            = stable number
local BoothImage = {} -- [Booth]            = saved image string or nil
local BoothDirty = {} -- [Booth]            = true when it needs saving

-- Moderation state. Filled in by the command section further down, read here
-- so the panel's player list can show a badge next to each name.
local Muted = {} -- [userId] = true
local Frozen = {} -- [userId] = true
local Godded = {} -- [userId] = true
local Invisible = {} -- [userId] = true
local ServerLocked = false
local DiscoRunning = false

local ImageStore = nil
if USE_DATASTORE then
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		ImageStore = res
	else
		warn("[Booth] DataStore unavailable, permanent images will not persist: " .. tostring(res))
	end
end

-------------------------------------------------------------------------------
-- Pass registry
-------------------------------------------------------------------------------

local PassStore = nil
if USE_DATASTORE then
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(PASS_DATASTORE)
	end)
	if ok then
		PassStore = res
	else
		warn("[Admin] Pass DataStore unavailable, custom passes will not persist.")
	end
end

-- Sorts the shop and refreshes the id lookup. Call after ANY change to PASSES.
local function RebuildPassIndex()
	SHOP_ORDER = {}
	for Key in pairs(PASSES) do
		SHOP_ORDER[#SHOP_ORDER + 1] = Key
	end

	table.sort(SHOP_ORDER, function(a, b)
		local pa, pb = PASSES[a], PASSES[b]
		local oa = pa.Order or 999
		local ob = pb.Order or 999
		if oa ~= ob then
			return oa < ob
		end
		return a < b
	end)

	ById = {}
	for Key, Pass in pairs(PASSES) do
		ById[Pass.Id] = Key
	end
end

local function ResetToBuiltins()
	PASSES = {}
	for Key, Pass in pairs(BUILTIN_PASSES) do
		local copy = {}
		for k, v in pairs(Pass) do
			copy[k] = v
		end
		PASSES[Key] = copy
	end
end

-- Only the custom ones are saved. Built ins always come from the script, so
-- editing them in code takes effect on the next boot.
local function SaveCustomPasses()
	if not PassStore then
		return false
	end

	local custom = {}
	for Key, Pass in pairs(PASSES) do
		if not Pass.Builtin then
			custom[Key] = {
				Id = Pass.Id,
				IsGamePass = Pass.IsGamePass and true or false,
				Category = Pass.Category,
				Title = Pass.Title,
				Blurb = Pass.Blurb,
				Icon = Pass.Icon,
				Price = Pass.Price,
				Order = Pass.Order,
			}
		end
	end

	local ok, err = pcall(function()
		PassStore:SetAsync("passes", custom)
	end)
	if not ok then
		warn("[Admin] Could not save passes: " .. tostring(err))
	end
	return ok
end

local function LoadCustomPasses()
	ResetToBuiltins()

	if PassStore then
		local ok, res = pcall(function()
			return PassStore:GetAsync("passes")
		end)
		if ok and type(res) == "table" then
			for Key, Pass in pairs(res) do
				-- Never let a saved entry shadow a built in.
				if type(Key) == "string" and not BUILTIN_PASSES[Key] and type(Pass) == "table"
					and type(Pass.Id) == "number" then
					PASSES[Key] = {
						Id = Pass.Id,
						IsGamePass = Pass.IsGamePass and true or false,
						Category = Pass.Category or "Passes",
						Title = Pass.Title or Key,
						Blurb = Pass.Blurb or "",
						Icon = Pass.Icon or "",
						Price = Pass.Price or "Gamepass",
						Order = Pass.Order or 100,
						Builtin = false,
					}
				end
			end
		elseif not ok then
			warn("[Admin] Could not load passes: " .. tostring(res))
		end
	end

	RebuildPassIndex()
end

LoadCustomPasses()

-------------------------------------------------------------------------------
-- Self healing
-------------------------------------------------------------------------------
--[[
	Booths only work if they live in Workspace.Booths, because that is the only
	place this script looks. Duplicating in Studio leaves them loose in
	Workspace (often still called "boothgood"), which silently breaks claiming.

	So instead of needing a Command Bar fix, the server sweeps Workspace on
	start, adopts anything that looks like a booth, and renames it. Nothing to
	run by hand, and it repairs itself every time the place boots.
--]]

-- Does this model have the parts a booth needs? Deliberately does NOT care
-- what it is called or where it currently lives.
local function LooksLikeBooth(m)
	if not m:IsA("Model") then
		return false
	end

	local d = m:FindFirstChild("Display")
	if not d then
		return false
	end
	if not d:FindFirstChild("BoothOwner") then
		return false
	end

	local sg = d:FindFirstChild("SurfaceGui")
	if not sg then
		return false
	end
	if not sg:FindFirstChild("ImageLabel") or not sg:FindFirstChild("TextLabel") then
		return false
	end

	local at = d:FindFirstChild("Attachment")
	if not at or not at:FindFirstChild("ProximityPrompt") then
		return false
	end

	return m:FindFirstChild("PartNamePlayer") ~= nil
end

local function CollectBooths()
	local adopted = 0

	for _, x in ipairs(Workspace:GetDescendants()) do
		if x ~= Booths and LooksLikeBooth(x) and not x:IsDescendantOf(Booths) then
			x.Name = "Booth"
			x.Parent = Booths
			adopted = adopted + 1
		end
	end

	-- Tidy the names of anything already inside.
	for _, x in ipairs(Booths:GetChildren()) do
		if LooksLikeBooth(x) and x.Name ~= "Booth" then
			x.Name = "Booth"
		end
	end

	if adopted > 0 then
		print("[Booth] Adopted " .. adopted .. " booth(s) into Workspace.Booths.")
	end
	return adopted
end

-------------------------------------------------------------------------------
-- Booth helpers
-------------------------------------------------------------------------------

local function IsBooth(Booth)
	if typeof(Booth) ~= "Instance" then
		return false
	end
	if Booth.Parent ~= Booths then
		return false
	end

	local Display = Booth:FindFirstChild("Display")
	if not Display then
		return false
	end

	local SurfaceGui = Display:FindFirstChild("SurfaceGui")
	local Attachment = Display:FindFirstChild("Attachment")
	local Owner = Display:FindFirstChild("BoothOwner")
	if not SurfaceGui or not Attachment or not Owner then
		return false
	end

	return SurfaceGui:FindFirstChild("ImageLabel") ~= nil
		and SurfaceGui:FindFirstChild("TextLabel") ~= nil
		and Attachment:FindFirstChild("ProximityPrompt") ~= nil
end

local function GetPrompt(Booth)
	return Booth.Display.Attachment.ProximityPrompt
end

local function SetNamePlate(Booth, Text)
	local Part = Booth:FindFirstChild("PartNamePlayer")
	if not Part then
		return
	end
	local SurfaceGui = Part:FindFirstChild("SurfaceGui")
	if not SurfaceGui then
		return
	end
	local Label = SurfaceGui:FindFirstChild("TextLabel")
	if Label then
		Label.Text = Text
	end
end

-- Whatever this booth should be showing right now.
local function CurrentImage(Booth)
	return BoothImage[Booth] or DEFAULT_IMAGE
end

local function ApplyImage(Booth)
	Booth.Display.SurfaceGui.ImageLabel.Image = CurrentImage(Booth)
end

-------------------------------------------------------------------------------
-- Saving permanent images
-------------------------------------------------------------------------------

local function KeyFor(Booth)
	return "booth_" .. tostring(BoothIndex[Booth] or 0)
end

local function LoadBoothImage(Booth)
	if not ImageStore then
		return
	end

	local ok, res = pcall(function()
		return ImageStore:GetAsync(KeyFor(Booth))
	end)

	if ok and type(res) == "string" and res ~= "" then
		BoothImage[Booth] = res
	elseif not ok then
		warn("[Booth] Could not load image for " .. KeyFor(Booth) .. ": " .. tostring(res))
	end
end

local function SaveBoothImage(Booth)
	if not ImageStore then
		BoothDirty[Booth] = nil
		return
	end

	local key = KeyFor(Booth)
	local value = BoothImage[Booth]

	for attempt = 1, SAVE_RETRIES do
		local ok, err = pcall(function()
			ImageStore:SetAsync(key, value)
		end)
		if ok then
			BoothDirty[Booth] = nil
			return true
		end
		if attempt == SAVE_RETRIES then
			warn("[Booth] Could not save " .. key .. ": " .. tostring(err))
		else
			wait(2)
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Ownership
-------------------------------------------------------------------------------

local function DoOwnershipCheck(Player, Pass)
	local Owns = false

	local Success, Result = pcall(function()
		if Pass.IsGamePass then
			return MarketplaceService:UserOwnsGamePassAsync(Player.UserId, Pass.Id)
		end
		-- PlayerOwnsAsset takes the Player object, not the UserId.
		return MarketplaceService:PlayerOwnsAsset(Player, Pass.Id)
	end)

	if Success then
		Owns = (Result == true)
	else
		-- Fail closed: never hand out a perk because the API broke.
		warn("[Booth] Ownership check failed for " .. Player.Name .. ": " .. tostring(Result))
	end

	return Owns
end

local function PlayerOwns(Player, Key, UseCache)
	local Pass = PASSES[Key]
	if not Pass then
		return false
	end

	local byPlayer = Ownership[Player]
	if not byPlayer then
		byPlayer = {}
		Ownership[Player] = byPlayer
	end

	if UseCache ~= false then
		local Cached = byPlayer[Key]
		if Cached and (tick() - Cached.Time) < OWNERSHIP_CACHE_SECONDS then
			return Cached.Owns
		end
	end

	local Owns = DoOwnershipCheck(Player, Pass)

	if Player.Parent ~= nil then
		byPlayer[Key] = {Owns = Owns, Time = tick()}
	end
	return Owns
end

-- One payload the client uses for both the booth UI and the shop.
local function PushPassState(Player, UseCache)
	local state = {}
	for _, Key in ipairs(SHOP_ORDER) do
		local Pass = PASSES[Key]
		state[#state + 1] = {
			Key = Key,
			Id = Pass.Id,
			Category = Pass.Category or "Passes",
			Title = Pass.Title,
			Blurb = Pass.Blurb,
			Icon = Pass.Icon or "",
			Price = Pass.Price or "Gamepass",
			Owns = PlayerOwns(Player, Key, UseCache),
		}
	end

	if Player.Parent ~= nil then
		RemoteEvent:FireClient(Player, "PassState", state, SHOP_CATEGORIES)
	end
	return state
end

-------------------------------------------------------------------------------
-- Admin
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Staff whitelist
-------------------------------------------------------------------------------

local StaffStore = nil
local BanStore = nil
local ReportStore = nil

if USE_DATASTORE then
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(STAFF_DATASTORE)
	end)
	if ok then
		StaffStore = res
	else
		warn("[Admin] Staff DataStore unavailable, the whitelist will not persist.")
	end

	local ok2, res2 = pcall(function()
		return DataStoreService:GetDataStore(BAN_DATASTORE)
	end)
	if ok2 then
		BanStore = res2
	else
		warn("[Admin] Ban DataStore unavailable, bans will only last this server.")
	end

	local ok3, res3 = pcall(function()
		return DataStoreService:GetDataStore(REPORT_DATASTORE)
	end)
	if ok3 then
		ReportStore = res3
	else
		warn("[Admin] Report DataStore unavailable, reports will only last this server.")
	end
end

-- [userId] = {Rank = number, Name = string, By = string}
local Staff = {}

-- [userId] = {Name = string, Reason = string, By = string, Time = number}
local Bans = {}

local RankCache = {} -- [Player] = number

--[[
	Declared here, assigned much further down.

	The staff tags need RankOf and RankLabel, so they cannot be defined until
	after those exist - but SetStaffRank, which has to refresh them, is defined
	before that point. A forward local is the way to let the earlier function
	call the later one; without it the call reads as a nil global and silently
	does nothing, which is exactly the kind of bug the ordering check looks for.
--]]
local RefreshTagsFor

local function ClearRankCache()
	RankCache = {}
end

local function SaveStaff()
	if not StaffStore then
		return false
	end

	-- DataStore keys are strings, so the table is flattened on the way out and
	-- rebuilt on the way in. Storing raw number keys silently loses them.
	local out = {}
	for userId, row in pairs(Staff) do
		out[tostring(userId)] = {Rank = row.Rank, Name = row.Name, By = row.By}
	end

	local ok, err = pcall(function()
		StaffStore:SetAsync("staff", out)
	end)
	if not ok then
		warn("[Admin] Could not save the staff list: " .. tostring(err))
	end
	return ok
end

local function LoadStaff()
	Staff = {}

	local loaded = false
	if StaffStore then
		local ok, res = pcall(function()
			return StaffStore:GetAsync("staff")
		end)
		if ok and type(res) == "table" then
			loaded = true
			for key, row in pairs(res) do
				local userId = tonumber(key)
				if userId and type(row) == "table" then
					local rank = tonumber(row.Rank) or RANK_NONE
					-- Developer and Owner are hard coded only, never restored
					-- from a save, so a tampered DataStore cannot mint one.
					if rank >= RANK_DEV then
						rank = RANK_ADMIN
					end
					if rank > RANK_NONE and not OWNERS[userId] and not DEVELOPERS[userId] then
						Staff[userId] = {
							Rank = rank,
							Name = tostring(row.Name or userId),
							By = tostring(row.By or "?"),
						}
					end
				end
			end
		elseif not ok then
			warn("[Admin] Could not load the staff list: " .. tostring(res))
		end
	end

	-- First boot only: seed the people who were hard coded before.
	if not loaded then
		for userId, row in pairs(DEFAULT_STAFF) do
			if not OWNERS[userId] and not DEVELOPERS[userId] then
				Staff[userId] = {Rank = row.Rank, Name = row.Name, By = "default"}
			end
		end
		if StaffStore then
			SaveStaff()
		end
	end

	ClearRankCache()
end

local function SaveBans()
	if not BanStore then
		return false
	end

	local out = {}
	for userId, row in pairs(Bans) do
		out[tostring(userId)] = row
	end

	local ok, err = pcall(function()
		BanStore:SetAsync("bans", out)
	end)
	if not ok then
		warn("[Admin] Could not save bans: " .. tostring(err))
	end
	return ok
end

local function LoadBans()
	Bans = {}
	if not BanStore then
		return
	end

	local ok, res = pcall(function()
		return BanStore:GetAsync("bans")
	end)
	if ok and type(res) == "table" then
		for key, row in pairs(res) do
			local userId = tonumber(key)
			if userId and type(row) == "table" then
				Bans[userId] = {
					Name = tostring(row.Name or userId),
					Reason = tostring(row.Reason or "No reason given."),
					By = tostring(row.By or "?"),
					Time = tonumber(row.Time) or 0,
				}
			end
		end
	elseif not ok then
		warn("[Admin] Could not load bans: " .. tostring(res))
	end
end

LoadStaff()
LoadBans()

-------------------------------------------------------------------------------
-- Ranks
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Adonis
-------------------------------------------------------------------------------
--[[
	One staff list, two consumers.

	Adonis is installed alongside this panel with the $ prefix. Its own Ranks
	config only hard codes the Owner and the Developers, because those are the
	only ranks that are hard coded here too. Everyone else is whitelisted in
	game through the Staff page, which lives in a DataStore and changes while
	the server is running - Adonis cannot read that on its own.

	So a rank change here is pushed into Adonis as well. Without it you get the
	thing the merge was supposed to avoid: someone made an Admin in the panel
	who cannot use a single $ command, and a demoted mod who still can.

	The mapping keeps the two ladders lined up:

	    Mod        -> Adonis Moderators   (100)
	    Admin      -> Adonis Admins       (200)
	    Developer  -> Adonis HeadAdmins   (300)   hard coded both sides
	    Owner      -> Adonis Creators     (900)   hard coded both sides

	Everything is wrapped up and retried, because Adonis loads from a remote
	module and may not be there yet - or at all, if the loader was removed. If
	it never appears the panel is completely unaffected; only the $ commands
	are, and the output says so rather than failing silently.
--]]

local ADONIS_RANK = {}
ADONIS_RANK[RANK_MOD] = "Moderators"
ADONIS_RANK[RANK_ADMIN] = "Admins"
ADONIS_RANK[RANK_DEV] = "HeadAdmins"
ADONIS_RANK[RANK_OWNER] = "Creators"

local Adonis = nil

-- Declared here, assigned below. The poll loop that uses it is written above
-- the definition, and a bare name there reads as a nil global rather than the
-- function.
local SyncAllAdonisRanks

--[[
	Adonis publishes its API by parenting an "Adonis_Loader" model with an API
	ModuleScript, some time after the server starts. Polled rather than waited
	on so a place without Adonis does not hang this script forever.
--]]
spawn(function()
	for _ = 1, 30 do
		local loader = ServerScriptService:FindFirstChild("Adonis_Loader")
			or game:FindFirstChild("Adonis_Loader")

		if loader then
			local api = loader:FindFirstChild("API", true)
			if api and api:IsA("ModuleScript") then
				local ok, res = pcall(require, api)
				if ok and type(res) == "table" then
					Adonis = res
					print("[Admin] Adonis found, staff ranks will be kept in step.")
					-- Adonis usually finishes loading after this script, so
					-- the existing whitelist has to be pushed across now.
					SyncAllAdonisRanks()
					return
				end
			end
		end

		wait(2)
	end

	print("[Admin] Adonis not found. The panel works as normal; $ commands will not.")
end)

--[[
	Mirrors one person's rank into Adonis.

	Adonis stores admins by "Name:UserId", so the UserId is what actually
	matters and a rename cannot strip someone's access - same rule the panel
	uses. Removing first and then adding avoids someone ending up in two ranks
	at once after a promotion.
--]]
local function SyncAdonisRank(userId, rank, name)
	if not Adonis then
		return
	end

	userId = tonumber(userId)
	if not userId then
		return
	end

	local entry = tostring(name or userId) .. ":" .. tostring(userId)

	local ok, err = pcall(function()
		for _, adonisRank in pairs(ADONIS_RANK) do
			if Adonis.RemoveAdmin then
				pcall(Adonis.RemoveAdmin, entry, adonisRank)
			end
		end

		local target = ADONIS_RANK[rank]
		if target and Adonis.MakeAdmin then
			Adonis.MakeAdmin(entry, target)
		end
	end)

	if not ok then
		warn("[Admin] Could not sync " .. entry .. " to Adonis: " .. tostring(err))
	end
end

-- Everyone currently on the whitelist, for when Adonis loads after we do or a
-- fresh server starts with people already ranked.
function SyncAllAdonisRanks()
	if not Adonis then
		return
	end

	for userId, holder in pairs(OWNERS) do
		SyncAdonisRank(userId, RANK_OWNER, holder)
	end
	for userId, holder in pairs(DEVELOPERS) do
		SyncAdonisRank(userId, RANK_DEV, holder)
	end
	for userId, row in pairs(Staff) do
		SyncAdonisRank(userId, row.Rank, row.Name)
	end
end


local function RankOfUserId(userId)
	userId = tonumber(userId)
	if not userId then
		return RANK_NONE
	end
	if OWNERS[userId] then
		return RANK_OWNER
	end
	if DEVELOPERS[userId] then
		return RANK_DEV
	end
	local row = Staff[userId]
	if row then
		return row.Rank
	end
	return RANK_NONE
end

local function RankOf(Player)
	if typeof(Player) ~= "Instance" or not Player:IsA("Player") then
		return RANK_NONE
	end

	local cached = RankCache[Player]
	if cached ~= nil then
		return cached
	end

	local rank = RankOfUserId(Player.UserId)

	-- Place owner always gets in, so a bad whitelist cannot lock you out.
	if rank < RANK_OWNER and ALLOW_PLACE_OWNER and game.CreatorType == Enum.CreatorType.User then
		if Player.UserId == game.CreatorId then
			rank = RANK_OWNER
		end
	end

	RankCache[Player] = rank
	return rank
end

-- Anyone who can open the panel at all.
local function IsAdmin(Player)
	return RankOf(Player) >= RANK_MOD
end

local function RankLabel(rank)
	return RANK_NAME[rank] or "Player"
end

--[[
	Can `actor` act on `targetUserId`?

	Rank must be strictly higher than the target's, which means:
	  * nobody can touch an Owner except an Owner
	  * an Admin cannot demote or kick another Admin
	  * staff cannot act on themselves by accident

	Owners are the one exception that can act on their own rank, so a second
	Owner is never untouchable.
--]]
local function CanActOn(actor, targetUserId)
	local mine = RankOf(actor)
	local theirs = RankOfUserId(targetUserId)

	if actor.UserId == tonumber(targetUserId) then
		return false, "That is you."
	end
	if mine >= RANK_OWNER then
		return true, nil
	end
	if theirs >= mine then
		return false, "They outrank you."
	end
	return true, nil
end

local function FindPlayerByUserId(userId)
	userId = tonumber(userId)
	if not userId then
		return nil
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == userId then
			return p
		end
	end
	return nil
end

--[[
	Turns what a staff member typed into one player.

	Accepts a UserId, a full name, or the start of a name, so "/kick bob"
	works the same as "/kick 49603". A partial match that hits more than one
	person is refused rather than guessed at, so a slip never bans a bystander.
--]]
local function ResolvePlayer(query)
	if type(query) == "number" then
		query = tostring(query)
	end
	if type(query) ~= "string" then
		return nil, "Who?"
	end

	query = string.gsub(query, "^%s+", "")
	query = string.gsub(query, "%s+$", "")
	if query == "" then
		return nil, "Who?"
	end

	local asId = tonumber(query)
	if asId then
		local p = FindPlayerByUserId(asId)
		if p then
			return p, nil
		end
		return nil, "Nobody here with ID " .. tostring(asId) .. "."
	end

	local lowered = string.lower(query)

	for _, p in ipairs(Players:GetPlayers()) do
		if string.lower(p.Name) == lowered then
			return p, nil
		end
	end

	local hit, count = nil, 0
	for _, p in ipairs(Players:GetPlayers()) do
		if string.sub(string.lower(p.Name), 1, string.len(lowered)) == lowered then
			hit = p
			count = count + 1
		end
	end

	if count == 1 then
		return hit, nil
	elseif count > 1 then
		return nil, "\"" .. query .. "\" matches " .. count .. " people, be more exact."
	end
	return nil, "No player called \"" .. query .. "\"."
end

-------------------------------------------------------------------------------
-- Reports
-------------------------------------------------------------------------------
--[[
	Any player can report a booth. The report lands in the staff queue, which
	every Mod and above sees on the Reports page of the panel.

	A report is deliberately cheap to file and cheap to dismiss: the point is
	that staff see the booth, its owner and the reason in one place, and can
	jump straight to acting on it, rather than needing the reporter to still
	be online to explain.

	Reports live in a DataStore so a shift change does not lose the queue.
	Only OPEN reports are kept; resolving one drops it.
--]]

local REPORT_REASONS = {
	"Inappropriate image",
	"Inappropriate text",
	"Advertising",
	"Impersonation",
	"Spam or booth hogging",
	"Other",
}

local MAX_REPORTS = 60
local REPORT_COOLDOWN = 20 -- seconds between reports from the same player

local Reports = {} -- array of {Id, BoothIndex, Against, AgainstName, By, ByName, Reason, Note, Time, Text, Image}
local NextReportId = 1
local LastReport = {} -- [userId] = tick()

local function SaveReports()
	if not ReportStore then
		return false
	end

	local ok, err = pcall(function()
		ReportStore:SetAsync("open", {Next = NextReportId, List = Reports})
	end)
	if not ok then
		warn("[Admin] Could not save reports: " .. tostring(err))
	end
	return ok
end

local function LoadReports()
	Reports = {}
	if not ReportStore then
		return
	end

	local ok, res = pcall(function()
		return ReportStore:GetAsync("open")
	end)

	if ok and type(res) == "table" then
		NextReportId = tonumber(res.Next) or 1
		if type(res.List) == "table" then
			for _, row in pairs(res.List) do
				if type(row) == "table" and row.Id then
					Reports[#Reports + 1] = row
				end
			end
		end
	elseif not ok then
		warn("[Admin] Could not load reports: " .. tostring(res))
	end
end

LoadReports()

local function ReportCount()
	return #Reports
end

-- Newest first, so the queue reads like an inbox.
local function ReportList()
	local out = {}
	for i = #Reports, 1, -1 do
		local r = Reports[i]
		out[#out + 1] = {
			Id = r.Id,
			Booth = r.BoothIndex,
			Against = r.Against,
			AgainstName = r.AgainstName,
			ByName = r.ByName,
			Reason = r.Reason,
			Note = r.Note,
			Text = r.Text,
			Image = r.Image,
			Time = r.Time,
			Online = FindPlayerByUserId(r.Against) ~= nil,
		}
	end
	return out
end

local function RemoveReport(id)
	id = tonumber(id)
	for i, r in ipairs(Reports) do
		if r.Id == id then
			table.remove(Reports, i)
			return r
		end
	end
	return nil
end

-- Keys are used as table indexes and sent over the remote, so keep them tame.
local function CleanKey(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local key = string.upper(string.gsub(raw, "%s+", "_"))
	key = string.gsub(key, "[^A-Z0-9_]", "")
	if key == "" or string.len(key) > 24 then
		return nil
	end
	return key
end

--[[
	Flattens whatever came off a text box into something safe to store and show.

	Trimming matters more than it looks. Without it a field holding only spaces
	is not equal to "", so every `if text == "" then refuse` check downstream
	waves it through, and a mod can send a warning that is literally blank.
	Newlines are folded to spaces for the same reason: a single line label
	should not be able to carry three.
--]]
local function CleanText(raw, limit)
	if type(raw) ~= "string" then
		return ""
	end
	raw = string.gsub(raw, "[\n\r\t]", " ")
	raw = string.gsub(raw, "^%s+", "")
	raw = string.gsub(raw, "%s+$", "")
	return string.sub(raw, 1, limit)
end

local function CleanAssetString(raw)
	if type(raw) ~= "string" or raw == "" then
		return ""
	end
	local digits = string.match(raw, "^%s*(%d+)%s*$")
		or string.match(raw, "^%s*rbxassetid://(%d+)%s*$")
		or string.match(raw, "[?&]id=(%d+)")
	if not digits or string.len(digits) > 18 then
		return ""
	end
	return "rbxassetid://" .. digits
end

-- The admin panel's view of the shop: every pass, including ones nobody owns.
local function PushAdminState(Player)
	if not IsAdmin(Player) then
		return
	end

	local list = {}
	for _, Key in ipairs(SHOP_ORDER) do
		local Pass = PASSES[Key]
		list[#list + 1] = {
			Key = Key,
			Id = Pass.Id,
			Category = Pass.Category,
			Title = Pass.Title,
			Blurb = Pass.Blurb,
			Icon = Pass.Icon,
			Price = Pass.Price,
			Order = Pass.Order or 100,
			Builtin = Pass.Builtin and true or false,
		}
	end

	RemoteEvent:FireClient(Player, "AdminState", list, SHOP_CATEGORIES)
end

-------------------------------------------------------------------------------
-- Panel pages
-------------------------------------------------------------------------------
--[[
	The panel has five pages and each one is fed by its own push. They are
	split up so a busy page (the player list, which refreshes as people join)
	never has to resend the quiet ones (the shop editor, the staff list).

	    AdminWho      who am I, what rank, my headshot     everyone with a rank
	    AdminPlayers  live player list + moderation state  Mod and up
	    AdminReports  the report queue                     Mod and up
	    AdminStaff    the whitelist                        Admin and up
	    AdminState    the shop editor                      Admin and up
--]]

-- The greeting: "Hello, <name>." plus the headshot and rank badge.
local function PushWho(Player)
	local rank = RankOf(Player)
	if rank < RANK_MOD then
		RemoteEvent:FireClient(Player, "AdminAccess", false, RANK_NONE, "Player")
		return
	end

	RemoteEvent:FireClient(Player, "AdminAccess", true, rank, RankLabel(rank))

	-- The headshot arrives whenever the proxy answers, which may be after the
	-- panel is already open. Sending it separately means the panel never waits.
	local url = HeadshotFor(Player.UserId, function(found)
		if Player.Parent ~= nil then
			RemoteEvent:FireClient(Player, "AdminHeadshot", Player.UserId, found)
		end
	end)
	if url then
		RemoteEvent:FireClient(Player, "AdminHeadshot", Player.UserId, url)
	end
end

local function PushPlayers(Player)
	if not IsAdmin(Player) then
		return
	end

	local myRank = RankOf(Player)
	local list = {}

	for _, p in ipairs(Players:GetPlayers()) do
		local booth = nil
		local owned = p:FindFirstChild("OwnedBooth")
		if owned and owned.Value and BoothIndex[owned.Value] then
			booth = BoothIndex[owned.Value]
		end

		list[#list + 1] = {
			UserId = p.UserId,
			Name = p.Name,
			Rank = RankOfUserId(p.UserId),
			RankName = RankLabel(RankOfUserId(p.UserId)),
			Booth = booth,
			Muted = Muted[p.UserId] and true or false,
			Frozen = Frozen[p.UserId] and true or false,
			God = Godded[p.UserId] and true or false,
			Invisible = Invisible[p.UserId] and true or false,
			-- Greys out the action buttons the viewer is not allowed to use.
			CanAct = (myRank >= RANK_OWNER) or (RankOfUserId(p.UserId) < myRank and p ~= Player),
		}

		-- Rows fill in their picture as the proxy answers, same as the greeting.
		local url = HeadshotFor(p.UserId, function(found)
			if Player.Parent ~= nil then
				RemoteEvent:FireClient(Player, "AdminHeadshot", p.UserId, found)
			end
		end)
		if url then
			list[#list].Headshot = url
		end
	end

	table.sort(list, function(a, b)
		if a.Rank ~= b.Rank then
			return a.Rank > b.Rank
		end
		return string.lower(a.Name) < string.lower(b.Name)
	end)

	RemoteEvent:FireClient(Player, "AdminPlayers", list, ServerLocked)
end

local function PushReports(Player)
	if not IsAdmin(Player) then
		return
	end
	RemoteEvent:FireClient(Player, "AdminReports", ReportList(), REPORT_REASONS)
end

local function PushStaff(Player)
	if RankOf(Player) < RANK_ADMIN then
		return
	end

	local list = {}

	-- Both come from the script rather than the whitelist, so they are shown
	-- with a note saying so and no remove button.
	for userId, name in pairs(OWNERS) do
		list[#list + 1] = {
			UserId = userId,
			Name = name,
			Rank = RANK_OWNER,
			RankName = "Owner",
			By = "hard coded",
			Locked = true,
		}
	end

	for userId, name in pairs(DEVELOPERS) do
		list[#list + 1] = {
			UserId = userId,
			Name = name,
			Rank = RANK_DEV,
			RankName = "Developer",
			By = "hard coded",
			Locked = true,
		}
	end

	for userId, row in pairs(Staff) do
		list[#list + 1] = {
			UserId = userId,
			Name = row.Name,
			Rank = row.Rank,
			RankName = RankLabel(row.Rank),
			By = row.By,
			Locked = false,
		}
	end

	table.sort(list, function(a, b)
		if a.Rank ~= b.Rank then
			return a.Rank > b.Rank
		end
		return string.lower(tostring(a.Name)) < string.lower(tostring(b.Name))
	end)

	local bans = {}
	for userId, row in pairs(Bans) do
		bans[#bans + 1] = {
			UserId = userId,
			Name = row.Name,
			Reason = row.Reason,
			By = row.By,
		}
	end
	table.sort(bans, function(a, b)
		return string.lower(tostring(a.Name)) < string.lower(tostring(b.Name))
	end)

	RemoteEvent:FireClient(Player, "AdminStaff", list, bans)
end

-- Everything at once, for when the panel first opens.
local function PushAdminAll(Player)
	if not IsAdmin(Player) then
		return
	end
	PushWho(Player)
	PushPlayers(Player)
	PushReports(Player)
	PushStaff(Player)
	PushAdminState(Player)
end

-- Fan a single page out to every staff member who can see it, so two mods
-- working at once never disagree about what the queue looks like.
local function BroadcastPlayers()
	for _, p in ipairs(Players:GetPlayers()) do
		if IsAdmin(p) then
			PushPlayers(p)
		end
	end
end

local function BroadcastReports()
	for _, p in ipairs(Players:GetPlayers()) do
		if IsAdmin(p) then
			PushReports(p)
		end
	end
end

local function BroadcastStaff()
	for _, p in ipairs(Players:GetPlayers()) do
		if RankOf(p) >= RANK_ADMIN then
			PushStaff(p)
		end
	end
end

-- Tells a staff member something happened, in the panel's status line.
local function Notify(Player, message, bad)
	if bad then
		RemoteEvent:FireClient(Player, "AdminError", message)
	else
		RemoteEvent:FireClient(Player, "AdminOk", message)
	end
end

-- Every staff action is announced to the other staff, so moderation is never
-- invisible to the rest of the team.
local function LogAction(actor, message)
	print("[Admin] " .. actor.Name .. ": " .. message)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= actor and IsAdmin(p) then
			RemoteEvent:FireClient(p, "AdminLog", actor.Name .. " " .. message)
		end
	end
end

-- Everyone in the server needs to see a shop change immediately.
local function BroadcastShop()
	for _, p in ipairs(Players:GetPlayers()) do
		PushPassState(p, true)
		if IsAdmin(p) then
			PushAdminState(p)
		end
	end
end

local function AdminSavePass(Player, data)
	if type(data) ~= "table" then
		return "Bad data."
	end

	local key = CleanKey(data.Key)
	if not key then
		return "Key must be letters, numbers or underscores."
	end

	local id = tonumber(data.Id)
	if not id or id <= 0 or id ~= math.floor(id) then
		return "Asset ID must be a whole number."
	end

	local title = CleanText(data.Title, 40)
	if string.match(title, "^%s*$") then
		return "Give it a title."
	end

	local existing = PASSES[key]

	-- Two passes sharing an id would make the purchase router ambiguous.
	for otherKey, other in pairs(PASSES) do
		if other.Id == id and otherKey ~= key then
			return "Asset ID " .. tostring(id) .. " is already used by " .. otherKey .. "."
		end
	end

	local category = CleanText(data.Category, 20)
	local known = false
	for _, c in ipairs(SHOP_CATEGORIES) do
		if c == category then
			known = true
			break
		end
	end
	if not known then
		category = SHOP_CATEGORIES[1]
	end

	if existing and existing.Builtin then
		-- Built ins keep their key, id and wiring; only the presentation moves.
		existing.Title = title
		existing.Blurb = CleanText(data.Blurb, 90)
		existing.Icon = CleanAssetString(data.Icon)
		existing.Price = CleanText(data.Price, 20)
		if existing.Price == "" then
			existing.Price = PASS_WORD
		end
		existing.Category = category
	else
		PASSES[key] = {
			Id = id,
			IsGamePass = data.IsGamePass and true or false,
			Category = category,
			Title = title,
			Blurb = CleanText(data.Blurb, 90),
			Icon = CleanAssetString(data.Icon),
			Price = CleanText(data.Price, 20),
			Order = tonumber(data.Order) or 100,
			Builtin = false,
		}
		if PASSES[key].Price == "" then
			PASSES[key].Price = PASS_WORD
		end
	end

	RebuildPassIndex()
	SaveCustomPasses()

	-- Ownership answers are keyed per pass, so a changed id must invalidate.
	for _, cache in pairs(Ownership) do
		cache[key] = nil
	end

	BroadcastShop()
	return nil
end

local function AdminDeletePass(Player, key)
	key = CleanKey(key)
	if not key or not PASSES[key] then
		return "No such pass."
	end
	if PASSES[key].Builtin then
		return "Built in passes cannot be deleted."
	end

	PASSES[key] = nil
	RebuildPassIndex()
	SaveCustomPasses()

	for _, cache in pairs(Ownership) do
		cache[key] = nil
	end

	BroadcastShop()
	return nil
end

-------------------------------------------------------------------------------
-- Boombox
-------------------------------------------------------------------------------

local function FindBoomboxTemplate()
	local direct = ServerStorage:FindFirstChild("Boombox")
	if direct and direct:IsA("Tool") then
		return direct
	end
	for _, d in ipairs(ServerStorage:GetDescendants()) do
		if d:IsA("Tool") and d.Name == "Boombox" then
			return d
		end
	end
	return nil
end

--[[
	Builds the tool at run time, so there is no Command Bar step and no model
	to insert.

	The tool deliberately contains NO scripts inside it. Script.Source can only
	be written by a plugin, never at run time, so a generated tool could never
	carry its own code. Instead the tool is just Handle + Sound + RemoteEvent,
	and both halves of the logic live in the two scripts you already paste:
	this one drives the sound, the MainUI client draws the little UI.
--]]
local BoomboxRemote = ReplicatedStorage:FindFirstChild("BoomboxRemote")
if not BoomboxRemote then
	BoomboxRemote = Instance.new("RemoteEvent")
	BoomboxRemote.Name = "BoomboxRemote"
	BoomboxRemote.Parent = ReplicatedStorage
end

local function EnsureBoombox()
	local existing = FindBoomboxTemplate()
	if existing then
		return existing
	end

	local tool = Instance.new("Tool")
	tool.Name = "Boombox"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Play any audio ID"

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(2, 1.2, 0.8)
	handle.BrickColor = BrickColor.new("Really black")
	handle.Material = Enum.Material.SmoothPlastic
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	local sound = Instance.new("Sound")
	sound.Name = "BoomboxSound"
	sound.Volume = 1
	sound.Looped = true
	sound.RollOffMaxDistance = 90
	sound.Parent = handle

	tool.Parent = ServerStorage
	print("[Boombox] Built ServerStorage.Boombox")
	return tool
end

-- Finds the Sound on whichever copy of the tool this player is holding.
local function BoomboxSoundFor(Player)
	local char = Player.Character
	local places = {}
	if char then
		places[#places + 1] = char
	end
	local bp = Player:FindFirstChildOfClass("Backpack")
	if bp then
		places[#places + 1] = bp
	end

	for _, where in ipairs(places) do
		local tool = where:FindFirstChild("Boombox")
		if tool then
			local handle = tool:FindFirstChild("Handle")
			if handle then
				local s = handle:FindFirstChild("BoomboxSound")
				if s then
					return s
				end
			end
		end
	end
	return nil
end

local LastBoombox = {}

BoomboxRemote.OnServerEvent:Connect(function(Player, action, value)
	-- Owning the pass is required, not just holding a copy of the tool.
	if not PlayerOwns(Player, "BOOMBOX", true) then
		return
	end

	local now = tick()
	local last = LastBoombox[Player]
	if last and (now - last) < 1 then
		return
	end
	LastBoombox[Player] = now

	local sound = BoomboxSoundFor(Player)
	if not sound then
		return
	end

	if action == "Play" then
		if type(value) ~= "string" and type(value) ~= "number" then
			return
		end
		local digits = string.match(tostring(value), "^%s*(%d+)%s*$")
		if not digits or string.len(digits) > 18 then
			return
		end
		sound:Stop()
		sound.SoundId = "rbxassetid://" .. digits
		local ok, err = pcall(function()
			sound:Play()
		end)
		if not ok then
			warn("[Boombox] Could not play " .. digits .. ": " .. tostring(err))
		end

	elseif action == "Stop" then
		sound:Stop()
	end
end)

local function GiveBoombox(Player)
	if not PlayerOwns(Player, "BOOMBOX", true) then
		return false
	end

	local template = FindBoomboxTemplate()
	if not template then
		warn("[Booth] No Boombox tool found in ServerStorage.")
		return false
	end

	local backpack = Player:FindFirstChildOfClass("Backpack")
	if backpack and not backpack:FindFirstChild("Boombox") then
		template:Clone().Parent = backpack
	end

	local gear = Player:FindFirstChild("StarterGear")
	if gear and not gear:FindFirstChild("Boombox") then
		template:Clone().Parent = gear
	end

	return true
end

-------------------------------------------------------------------------------
-- Input validation
-------------------------------------------------------------------------------

-- Only accepts a numeric image/decal asset ID. Players cannot inject a URL.
local function MakeImageContent(ImageId)
	if type(ImageId) == "number" then
		ImageId = tostring(ImageId)
	end
	if type(ImageId) ~= "string" then
		return nil
	end
	if string.len(ImageId) > 64 then
		return nil
	end

	local Digits = string.match(ImageId, "^%s*(%d+)%s*$")
		or string.match(ImageId, "^%s*rbxassetid://(%d+)%s*$")
		or string.match(ImageId, "[?&]id=(%d+)")

	if not Digits or Digits == "0" or string.len(Digits) > 18 then
		return nil
	end

	return "rbxassetid://" .. Digits
end

local function CheckCooldown(Player)
	local Now = tick()
	local Last = LastAction[Player]
	if Last and (Now - Last) < ACTION_COOLDOWN then
		return false
	end
	LastAction[Player] = Now
	return true
end

--[[
	Staff get their own, much shorter, cooldown.

	The one second player cooldown is there to stop booth spam, and it is fine
	for that. Reusing it for moderation was wrong in two ways: a mod clearing a
	queue of reports genuinely does press things faster than once a second, and
	a refusal returned nothing at all, so the button looked broken rather than
	rate limited. Here the window is short enough not to get in the way, and a
	refusal says so out loud.
--]]
local STAFF_COOLDOWN = 0.15
local LastStaffAction = {}

local function CheckStaffCooldown(Player)
	local Now = tick()
	local Last = LastStaffAction[Player]
	if Last and (Now - Last) < STAFF_COOLDOWN then
		RemoteEvent:FireClient(Player, "AdminError", "Slow down a moment.")
		return false
	end
	LastStaffAction[Player] = Now
	return true
end

-------------------------------------------------------------------------------
-- Claiming
-------------------------------------------------------------------------------

-- Unclaiming must NOT wipe the image: a permanent image belongs to the booth,
-- not to whoever happens to be standing in it.
local function ResetBooth(Player, Booth)
	if not Booth or not IsBooth(Booth) then
		if Player then
			local Owned = Player:FindFirstChild("OwnedBooth")
			if Owned then
				Owned.Value = nil
			end
			RemoteEvent:FireClient(Player, "BoothUnclaimed")
		end
		return
	end

	ApplyImage(Booth)
	Booth.Display.SurfaceGui.TextLabel.Text = "Unclaimed Booth"
	Booth.Display.BoothOwner.Value = nil
	SetNamePlate(Booth, "None")

	local Prompt = GetPrompt(Booth)
	Prompt.Enabled = true
	Prompt.ObjectText = "Claim Booth"

	if Player then
		local Owned = Player:FindFirstChild("OwnedBooth")
		if Owned and Owned.Value == Booth then
			Owned.Value = nil
		end
		RemoteEvent:FireClient(Player, "BoothUnclaimed")
	end
end

local function ClaimBooth(Player, Booth)
	local OwnedBooth = Player:FindFirstChild("OwnedBooth")

	if not OwnedBooth or OwnedBooth.Value then
		return
	end
	if not IsBooth(Booth) or Booth.Display.BoothOwner.Value then
		return
	end

	local Prompt = GetPrompt(Booth)
	Prompt.Enabled = false
	Prompt.ObjectText = Player.Name .. "'s Booth"

	Booth.Display.BoothOwner.Value = Player
	Booth.Display.SurfaceGui.TextLabel.Text = Player.Name .. "'s Booth"
	SetNamePlate(Booth, Player.Name)
	OwnedBooth.Value = Booth

	-- Inherit whatever image is already on this booth.
	ApplyImage(Booth)

	RemoteEvent:FireClient(Player, "DisablePrompts")
	RemoteEvent:FireClient(Player, "OpenGui")
end

local function PlayerNearBooth(Player, Booth)
	if not IsBooth(Booth) then
		return false
	end

	local Character = Player.Character
	if not Character then
		return false
	end

	local Root = Character:FindFirstChild("HumanoidRootPart")
	if not Root then
		return false
	end

	local Prompt = GetPrompt(Booth)
	local PromptParent = Prompt.Parent

	local PromptPosition

	if PromptParent:IsA("Attachment") then
		PromptPosition = PromptParent.WorldPosition
	elseif PromptParent:IsA("BasePart") then
		PromptPosition = PromptParent.Position
	else
		return false
	end

	return (Root.Position - PromptPosition).Magnitude <= Prompt.MaxActivationDistance + 4
end

local function SetupBooth(Booth, index)
	if not IsBooth(Booth) then
		return
	end

	BoothIndex[Booth] = index

	local Prompt = GetPrompt(Booth)

	-- Mobile-friendly prompt settings
	Prompt.Enabled = true
	Prompt.ActionText = "Claim"
	Prompt.ObjectText = "Claim Booth"
	Prompt.HoldDuration = 0
	Prompt.MaxActivationDistance = 14
	Prompt.RequiresLineOfSight = false
	Prompt.ClickablePrompt = true

	Prompt.Triggered:Connect(function(Player)
		ClaimBooth(Player, Booth)
	end)

	Booth.Display.BoothOwner.Value = nil
	Booth.Display.SurfaceGui.TextLabel.Text = "Unclaimed Booth"
	SetNamePlate(Booth, "None")
	ApplyImage(Booth)
end

-------------------------------------------------------------------------------
-- Admin commands
-------------------------------------------------------------------------------
--[[
	Every command is one entry in this table, and every entry is reachable two
	ways: typed in chat as "/kick bob spamming", or pressed as a button in the
	panel. Both routes call the exact same function with the exact same
	arguments, so the GUI can never quietly do something the chat command
	cannot, and neither can drift from the other as commands are added.

	    Rank    minimum rank needed
	    Args    what the panel should ask for before firing
	              "player"  a target, picked from the live list
	              "text"    free text, e.g. a reason or a message
	              "number"  a number, e.g. walkspeed
	    Run     function(actor, target, value) -> okMessage, errMessage

	Anything that can be undone has its opposite in the same table, so a mod
	who freezes someone can always find the unfreeze next to it.
--]]

local Commands = {}
local CommandOrder = {}

local function AddCommand(name, def)
	def.Name = name
	Commands[name] = def
	CommandOrder[#CommandOrder + 1] = name
end

-- Character helpers. All of them cope with a dead or still loading character
-- rather than erroring, because staff press buttons faster than people respawn.
local function HumanoidOf(Player)
	local char = Player.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

local function RootOf(Player)
	local char = Player.Character
	if not char then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")
end

local function SetFrozen(Player, on)
	Frozen[Player.UserId] = on or nil

	local hum = HumanoidOf(Player)
	if hum then
		hum.WalkSpeed = on and 0 or 16
		hum.JumpPower = on and 0 or 50
	end

	local root = RootOf(Player)
	if root then
		root.Anchored = on and true or false
	end
end

local function SetInvisible(Player, on)
	Invisible[Player.UserId] = on or nil

	local char = Player.Character
	if not char then
		return
	end

	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			part.LocalTransparencyModifier = 0
			part.Transparency = on and 1 or 0
		elseif part:IsA("Decal") then
			part.Transparency = on and 1 or 0
		end
	end

	local face = char:FindFirstChild("Head")
	if face then
		local billboard = face:FindFirstChildOfClass("BillboardGui")
		if billboard then
			billboard.Enabled = not on
		end
	end
end

-- Booth by its stable index, which is what the report queue stores.
local function BoothByIndex(index)
	index = tonumber(index)
	if not index then
		return nil
	end
	for booth, i in pairs(BoothIndex) do
		if i == index and IsBooth(booth) then
			return booth
		end
	end
	return nil
end

local function BoothOwnedBy(Player)
	local owned = Player:FindFirstChild("OwnedBooth")
	if owned and owned.Value and IsBooth(owned.Value) then
		return owned.Value
	end
	for _, booth in ipairs(Booths:GetChildren()) do
		if IsBooth(booth) and booth.Display.BoothOwner.Value == Player then
			return booth
		end
	end
	return nil
end

-- Moderation -----------------------------------------------------------------

AddCommand("kick", {
	Rank = RANK_MOD,
	Args = {"player", "text"},
	Label = "Kick",
	Blurb = "Remove them from this server.",
	Run = function(actor, target, reason)
		reason = CleanText(reason, 90)
		if reason == "" then
			reason = "No reason given."
		end
		target:Kick("Kicked by " .. actor.Name .. ": " .. reason)
		return "Kicked " .. target.Name .. ".", nil
	end,
})

AddCommand("ban", {
	Rank = RANK_ADMIN,
	Args = {"player", "text"},
	Label = "Ban",
	Blurb = "Kick them and stop them coming back.",
	Danger = true,
	Run = function(actor, target, reason)
		reason = CleanText(reason, 90)
		if reason == "" then
			reason = "No reason given."
		end

		Bans[target.UserId] = {
			Name = target.Name,
			Reason = reason,
			By = actor.Name,
			Time = os.time(),
		}
		SaveBans()

		target:Kick("Banned by " .. actor.Name .. ": " .. reason)
		BroadcastStaff()
		return "Banned " .. target.Name .. ".", nil
	end,
})

-- Unban has to work on someone who is, by definition, not here, so it takes
-- a UserId or a remembered name rather than going through ResolvePlayer.
AddCommand("unban", {
	Rank = RANK_ADMIN,
	Args = {"text"},
	Label = "Unban",
	Blurb = "Let a banned player back in. Takes a UserId or their name.",
	Raw = true,
	Run = function(actor, _target, query)
		query = CleanText(query, 40)
		if query == "" then
			return nil, "Who?"
		end

		local asId = tonumber(query)
		if asId and Bans[asId] then
			local name = Bans[asId].Name
			Bans[asId] = nil
			SaveBans()
			BroadcastStaff()
			return "Unbanned " .. name .. ".", nil
		end

		local lowered = string.lower(query)
		for userId, row in pairs(Bans) do
			if string.lower(tostring(row.Name)) == lowered then
				Bans[userId] = nil
				SaveBans()
				BroadcastStaff()
				return "Unbanned " .. row.Name .. ".", nil
			end
		end

		return nil, "No ban found for \"" .. query .. "\"."
	end,
})

AddCommand("mute", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Mute",
	Blurb = "Stop them talking in chat.",
	Run = function(actor, target)
		Muted[target.UserId] = true
		RemoteEvent:FireClient(target, "Muted", true)
		return "Muted " .. target.Name .. ".", nil
	end,
})

AddCommand("unmute", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Unmute",
	Blurb = "Give them their chat back.",
	Run = function(actor, target)
		Muted[target.UserId] = nil
		RemoteEvent:FireClient(target, "Muted", false)
		return "Unmuted " .. target.Name .. ".", nil
	end,
})

AddCommand("freeze", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Freeze",
	Blurb = "Hold them still where they are.",
	Run = function(actor, target)
		SetFrozen(target, true)
		return "Froze " .. target.Name .. ".", nil
	end,
})

AddCommand("unfreeze", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Unfreeze",
	Blurb = "Let them move again.",
	Run = function(actor, target)
		SetFrozen(target, false)
		return "Unfroze " .. target.Name .. ".", nil
	end,
})

AddCommand("warn", {
	Rank = RANK_MOD,
	Args = {"player", "text"},
	Label = "Warn",
	Blurb = "Put a message on their screen they have to read.",
	Run = function(actor, target, message)
		message = CleanText(message, 140)
		if message == "" then
			return nil, "Say what the warning is."
		end
		RemoteEvent:FireClient(target, "AdminWarn", actor.Name, message)
		return "Warned " .. target.Name .. ".", nil
	end,
})

-- Movement --------------------------------------------------------------------

AddCommand("bring", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Bring",
	Blurb = "Pull them to you.",
	Run = function(actor, target)
		local from = RootOf(target)
		local to = RootOf(actor)
		if not from or not to then
			return nil, "One of you has no character right now."
		end
		from.CFrame = to.CFrame * CFrame.new(0, 0, -4)
		return "Brought " .. target.Name .. ".", nil
	end,
})

AddCommand("goto", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Go To",
	Blurb = "Teleport yourself to them.",
	Run = function(actor, target)
		local from = RootOf(actor)
		local to = RootOf(target)
		if not from or not to then
			return nil, "One of you has no character right now."
		end
		from.CFrame = to.CFrame * CFrame.new(0, 0, 4)
		return "Went to " .. target.Name .. ".", nil
	end,
})

AddCommand("respawn", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Respawn",
	Blurb = "Load them a fresh character.",
	Run = function(actor, target)
		target:LoadCharacter()
		return "Respawned " .. target.Name .. ".", nil
	end,
})

-- Character --------------------------------------------------------------------

AddCommand("speed", {
	Rank = RANK_MOD,
	Args = {"player", "number"},
	Label = "Speed",
	Blurb = "Set how fast they walk. 16 is normal.",
	Default = "16",
	Run = function(actor, target, value)
		local n = tonumber(value)
		if not n then
			return nil, "Give a number."
		end
		n = math.clamp(n, 0, 200)
		local hum = HumanoidOf(target)
		if not hum then
			return nil, "They have no character right now."
		end
		hum.WalkSpeed = n
		return "Set " .. target.Name .. "'s speed to " .. n .. ".", nil
	end,
})

AddCommand("jump", {
	Rank = RANK_MOD,
	Args = {"player", "number"},
	Label = "Jump",
	Blurb = "Set how high they jump. 50 is normal.",
	Default = "50",
	Run = function(actor, target, value)
		local n = tonumber(value)
		if not n then
			return nil, "Give a number."
		end
		n = math.clamp(n, 0, 500)
		local hum = HumanoidOf(target)
		if not hum then
			return nil, "They have no character right now."
		end
		hum.JumpPower = n
		return "Set " .. target.Name .. "'s jump to " .. n .. ".", nil
	end,
})

AddCommand("heal", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Heal",
	Blurb = "Put them back to full health.",
	Run = function(actor, target)
		local hum = HumanoidOf(target)
		if not hum then
			return nil, "They have no character right now."
		end
		hum.Health = hum.MaxHealth
		return "Healed " .. target.Name .. ".", nil
	end,
})

--[[
	A big finite number rather than math.huge.

	Setting MaxHealth to infinity makes the health bar compute Health/MaxHealth
	as a NaN, and the bar renders as an empty or glitched sliver above the
	character for everyone in the server. A million is unkillable by anything
	in this place and still draws correctly.
--]]
local GOD_HEALTH = 1000000

AddCommand("god", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "God",
	Blurb = "Make them unkillable.",
	Run = function(actor, target)
		local hum = HumanoidOf(target)
		if not hum then
			return nil, "They have no character right now."
		end
		Godded[target.UserId] = true
		hum.MaxHealth = GOD_HEALTH
		hum.Health = GOD_HEALTH
		return "God mode on for " .. target.Name .. ".", nil
	end,
})

AddCommand("ungod", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Ungod",
	Blurb = "Make them mortal again.",
	Run = function(actor, target)
		Godded[target.UserId] = nil
		local hum = HumanoidOf(target)
		if not hum then
			return nil, "They have no character right now."
		end
		hum.MaxHealth = 100
		hum.Health = 100
		return "God mode off for " .. target.Name .. ".", nil
	end,
})

AddCommand("invisible", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Invisible",
	Blurb = "Hide them, so staff can watch unseen.",
	Run = function(actor, target)
		SetInvisible(target, true)
		return target.Name .. " is now invisible.", nil
	end,
})

AddCommand("visible", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Visible",
	Blurb = "Show them again.",
	Run = function(actor, target)
		SetInvisible(target, false)
		return target.Name .. " is visible again.", nil
	end,
})

-- Booths ------------------------------------------------------------------------

AddCommand("clearbooth", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Clear Booth",
	Blurb = "Wipe the image and text off their booth.",
	Run = function(actor, target)
		local booth = BoothOwnedBy(target)
		if not booth then
			return nil, target.Name .. " has no booth."
		end

		BoothImage[booth] = nil
		BoothDirty[booth] = true
		SaveBoothImage(booth)
		ApplyImage(booth)
		booth.Display.SurfaceGui.TextLabel.Text = target.Name .. "'s Booth"

		return "Cleared " .. target.Name .. "'s booth.", nil
	end,
})

AddCommand("unclaim", {
	Rank = RANK_MOD,
	Args = {"player"},
	Label = "Force Unclaim",
	Blurb = "Take their booth off them and free it up.",
	Run = function(actor, target)
		local booth = BoothOwnedBy(target)
		if not booth then
			return nil, target.Name .. " has no booth."
		end
		ResetBooth(target, booth)
		RemoteEvent:FireClient(target, "EnablePrompts")
		BroadcastPlayers()
		return "Freed " .. target.Name .. "'s booth.", nil
	end,
})

AddCommand("resetbooths", {
	Rank = RANK_ADMIN,
	Args = {},
	Label = "Reset All Booths",
	Blurb = "Unclaim every booth and wipe every saved image.",
	Danger = true,
	Run = function(actor)
		local n = 0
		for _, booth in ipairs(Booths:GetChildren()) do
			if IsBooth(booth) then
				local owner = booth.Display.BoothOwner.Value
				BoothImage[booth] = nil
				BoothDirty[booth] = true
				SaveBoothImage(booth)
				ResetBooth(owner, booth)
				n = n + 1
			end
		end
		BroadcastPlayers()
		return "Reset " .. n .. " booth(s).", nil
	end,
})

-- Server ------------------------------------------------------------------------

AddCommand("announce", {
	Rank = RANK_MOD,
	Args = {"text"},
	Label = "Announce",
	Blurb = "Show a message to everyone in the server.",
	Raw = true,
	Run = function(actor, _target, message)
		message = CleanText(message, 140)
		if message == "" then
			return nil, "Say what to announce."
		end
		for _, p in ipairs(Players:GetPlayers()) do
			RemoteEvent:FireClient(p, "Announce", actor.Name, message)
		end
		return "Announced.", nil
	end,
})

AddCommand("lock", {
	Rank = RANK_ADMIN,
	Args = {},
	Label = "Lock Server",
	Blurb = "Turn away anyone new who is not staff.",
	Run = function(actor)
		ServerLocked = true
		BroadcastPlayers()
		return "Server locked. Only staff can join.", nil
	end,
})

AddCommand("unlock", {
	Rank = RANK_ADMIN,
	Args = {},
	Label = "Unlock Server",
	Blurb = "Let everyone join again.",
	Run = function(actor)
		ServerLocked = false
		BroadcastPlayers()
		return "Server unlocked.", nil
	end,
})

AddCommand("time", {
	Rank = RANK_MOD,
	Args = {"number"},
	Label = "Set Time",
	Blurb = "Change the time of day, 0 to 24.",
	Default = "14",
	Raw = true,
	Run = function(actor, _target, value)
		local n = tonumber(value)
		if not n then
			return nil, "Give an hour from 0 to 24."
		end
		Lighting.ClockTime = math.clamp(n, 0, 24)
		return "Time set to " .. Lighting.ClockTime .. ".", nil
	end,
})

-- Staff -------------------------------------------------------------------------
--[[
	Promotion is the one place the rank rules really matter, so they are spelled
	out rather than folded into CanActOn:

	  * only an Owner can hand out Admin
	  * an Admin can hand out Mod, and can take Mod back
	  * nobody can set a rank at or above their own, Owners aside
	  * Owner is never grantable, because it is hard coded in the script
--]]

local function SetStaffRank(actor, targetUserId, rank, displayName)
	targetUserId = tonumber(targetUserId)
	if not targetUserId then
		return nil, "That is not a UserId."
	end

	local myRank = RankOf(actor)

	if OWNERS[targetUserId] then
		return nil, "Owners are set in the script and cannot be changed here."
	end
	if DEVELOPERS[targetUserId] then
		return nil, "Developers are set in the script and cannot be changed here."
	end
	if targetUserId == actor.UserId then
		return nil, "You cannot change your own rank."
	end

	local theirRank = RankOfUserId(targetUserId)
	if theirRank >= myRank and myRank < RANK_OWNER then
		return nil, "They already rank as high as you."
	end
	if rank >= myRank and myRank < RANK_OWNER then
		return nil, "You cannot hand out a rank at or above your own."
	end
	if rank >= RANK_DEV then
		return nil, "Developer and Owner are set in the script, not in game."
	end

	local known = FindPlayerByUserId(targetUserId)
	local name = displayName
	if known then
		name = known.Name
	end
	if not name or name == "" then
		name = (Staff[targetUserId] and Staff[targetUserId].Name) or tostring(targetUserId)
	end

	if rank <= RANK_NONE then
		if not Staff[targetUserId] then
			return nil, name .. " is not staff."
		end
		Staff[targetUserId] = nil
	else
		Staff[targetUserId] = {Rank = rank, Name = name, By = actor.Name}
	end

	SaveStaff()
	ClearRankCache()

	-- Keep the $ commands in step with the panel, or a new Admin cannot use
	-- any of them and a demoted one still can.
	SyncAdonisRank(targetUserId, rank, name)

	BroadcastStaff()
	BroadcastPlayers()

	-- Tell them right away if they are in the server, so the panel button
	-- appears or disappears without needing a rejoin.
	if known then
		PushWho(known)
		RefreshTagsFor(known)
		if IsAdmin(known) then
			PushAdminAll(known)
		else
			RemoteEvent:FireClient(known, "AdminClose")
		end
	end

	if rank <= RANK_NONE then
		return "Removed " .. name .. " from staff.", nil
	end
	return "Made " .. name .. " " .. RankLabel(rank) .. ".", nil
end

AddCommand("mod", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Make Mod",
	Blurb = "Give them the Mod rank.",
	Run = function(actor, target)
		return SetStaffRank(actor, target.UserId, RANK_MOD, target.Name)
	end,
})

AddCommand("admin", {
	Rank = RANK_DEV,
	Args = {"player"},
	Label = "Make Admin",
	Blurb = "Give them the Admin rank. Developer and up.",
	Run = function(actor, target)
		return SetStaffRank(actor, target.UserId, RANK_ADMIN, target.Name)
	end,
})

AddCommand("unstaff", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Remove Staff",
	Blurb = "Take every rank off them.",
	Run = function(actor, target)
		return SetStaffRank(actor, target.UserId, RANK_NONE, target.Name)
	end,
})

-------------------------------------------------------------------------------
-- Trolling
-------------------------------------------------------------------------------
--[[
	Harmless nonsense for staff to play with. Everything here is deliberately:

	  * reversible, with /cleanup putting a person completely back to normal
	  * incapable of taking someone's session away - nothing kicks, bans, or
	    leaves a player stuck with no way out
	  * Admin and up, because being flung across the map by a bored Mod stops
	    being funny quite quickly
	  * logged like every other command, so it is never a mystery who did it

	Marked Troll = true so the panel can put them on their own page rather than
	mixed in with the moderation buttons, where a mis-click matters more.
--]]

local TrollEffects = {} -- [userId] = {list of instances to clean up}

local function TrackEffect(Player, thing)
	local list = TrollEffects[Player.UserId]
	if not list then
		list = {}
		TrollEffects[Player.UserId] = list
	end
	list[#list + 1] = thing
	return thing
end

local function ClearEffects(Player)
	local list = TrollEffects[Player.UserId]
	if list then
		for _, thing in ipairs(list) do
			pcall(function()
				thing:Destroy()
			end)
		end
	end
	TrollEffects[Player.UserId] = nil
end

-- Where to hang a particle effect. Works on R6 and R15.
local function TorsoOf(Player)
	local char = Player.Character
	if not char then
		return nil
	end
	return char:FindFirstChild("UpperTorso")
		or char:FindFirstChild("Torso")
		or char:FindFirstChild("HumanoidRootPart")
end

AddCommand("fling", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Fling",
	Blurb = "Launch them into the sky.",
	Troll = true,
	Run = function(actor, target)
		local root = RootOf(target)
		if not root then
			return nil, "They have no character right now."
		end

		-- A shove rather than a teleport, so they arc and come back down
		-- instead of vanishing.
		root.Velocity = Vector3.new(
			math.random(-80, 80),
			math.random(120, 180),
			math.random(-80, 80)
		)
		return "Flung " .. target.Name .. ".", nil
	end,
})

AddCommand("spin", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Spin",
	Blurb = "Set them spinning. Cleared with Cleanup.",
	Troll = true,
	Run = function(actor, target)
		local root = RootOf(target)
		if not root then
			return nil, "They have no character right now."
		end

		local spin = Instance.new("BodyAngularVelocity")
		spin.Name = "TrollSpin"
		spin.AngularVelocity = Vector3.new(0, 18, 0)
		spin.MaxTorque = Vector3.new(0, math.huge, 0)
		spin.P = math.huge
		spin.Parent = root
		TrackEffect(target, spin)

		return "Spinning " .. target.Name .. ".", nil
	end,
})

AddCommand("fire", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Set Alight",
	Blurb = "Put them on fire. Does no damage.",
	Troll = true,
	Run = function(actor, target)
		local torso = TorsoOf(target)
		if not torso then
			return nil, "They have no character right now."
		end

		local f = Instance.new("Fire")
		f.Name = "TrollFire"
		f.Heat = 12
		f.Size = 8
		f.Parent = torso
		TrackEffect(target, f)

		return target.Name .. " is on fire. Harmlessly.", nil
	end,
})

AddCommand("sparkle", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Sparkles",
	Blurb = "Make them fabulous.",
	Troll = true,
	Run = function(actor, target)
		local torso = TorsoOf(target)
		if not torso then
			return nil, "They have no character right now."
		end

		local sp = Instance.new("Sparkles")
		sp.Name = "TrollSparkles"
		sp.Parent = torso
		TrackEffect(target, sp)

		return target.Name .. " is sparkling.", nil
	end,
})

AddCommand("smoke", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Smoke",
	Blurb = "Cover them in smoke.",
	Troll = true,
	Run = function(actor, target)
		local torso = TorsoOf(target)
		if not torso then
			return nil, "They have no character right now."
		end

		local sm = Instance.new("Smoke")
		sm.Name = "TrollSmoke"
		sm.Size = 6
		sm.Opacity = 0.6
		sm.Parent = torso
		TrackEffect(target, sm)

		return target.Name .. " is smoking.", nil
	end,
})

AddCommand("ghost", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Ghost",
	Blurb = "Make them see-through but still there.",
	Troll = true,
	Run = function(actor, target)
		local char = target.Character
		if not char then
			return nil, "They have no character right now."
		end

		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				part.Transparency = 0.7
			elseif part:IsA("Decal") then
				part.Transparency = 0.7
			end
		end

		return target.Name .. " is a ghost.", nil
	end,
})

AddCommand("explode", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Explode",
	Blurb = "A big bang that does no damage.",
	Troll = true,
	Run = function(actor, target)
		local root = RootOf(target)
		if not root or not root.Position then
			return nil, "They have no character right now."
		end

		local boom = Instance.new("Explosion")
		boom.Position = root.Position
		boom.BlastRadius = 12
		-- Zero pressure means all noise and no harm: it shoves them about
		-- without killing them or blowing a hole in the map.
		boom.BlastPressure = 0
		boom.DestroyJointRadiusPercent = 0
		boom.Parent = Workspace

		root.Velocity = Vector3.new(0, 90, 0)
		return "Boom.", nil
	end,
})

AddCommand("jail", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Jail",
	Blurb = "Box them in. Cleared with Cleanup.",
	Troll = true,
	Run = function(actor, target)
		local root = RootOf(target)
		if not root or not root.Position then
			return nil, "They have no character right now."
		end

		local cage = Instance.new("Model")
		cage.Name = "TrollJail"

		local at = root.Position
		local walls = {
			{Vector3.new(10, 12, 1), at + Vector3.new(0, 0, 5)},
			{Vector3.new(10, 12, 1), at + Vector3.new(0, 0, -5)},
			{Vector3.new(1, 12, 10), at + Vector3.new(5, 0, 0)},
			{Vector3.new(1, 12, 10), at + Vector3.new(-5, 0, 0)},
			{Vector3.new(10, 1, 10), at + Vector3.new(0, 6, 0)},
		}

		for _, w in ipairs(walls) do
			local part = Instance.new("Part")
			part.Size = w[1]
			part.Position = w[2]
			part.Anchored = true
			part.BrickColor = BrickColor.new("Really black")
			part.Transparency = 0.35
			part.Material = Enum.Material.Neon
			part.Parent = cage
		end

		cage.Parent = Workspace
		TrackEffect(target, cage)

		return "Jailed " .. target.Name .. ".", nil
	end,
})

AddCommand("cleanup", {
	Rank = RANK_ADMIN,
	Args = {"player"},
	Label = "Cleanup",
	Blurb = "Undo every troll effect on them.",
	Troll = true,
	Run = function(actor, target)
		ClearEffects(target)

		local char = target.Character
		if char then
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					-- Invisible is a moderation state, not a troll one, so it
					-- is left alone here.
					if not Invisible[target.UserId] then
						part.Transparency = 0
					end
				elseif part:IsA("Decal") then
					if not Invisible[target.UserId] then
						part.Transparency = 0
					end
				elseif part:IsA("Fire") or part:IsA("Smoke")
					or part:IsA("Sparkles") or part:IsA("BodyAngularVelocity") then
					part:Destroy()
				end
			end
		end

		return "Cleaned up " .. target.Name .. ".", nil
	end,
})

AddCommand("disco", {
	Rank = RANK_ADMIN,
	Args = {},
	Label = "Disco",
	Blurb = "Flash the whole map. Runs for about fifteen seconds.",
	Troll = true,
	Run = function(actor)
		if DiscoRunning then
			return nil, "The disco is already going."
		end

		DiscoRunning = true
		local wasAmbient = Lighting.Ambient
		local wasOutdoor = Lighting.OutdoorAmbient
		local wasClock = Lighting.ClockTime

		spawn(function()
			-- Bounded rather than a toggle, so a disco can never be left on by
			-- somebody who logs off and forgets about it.
			for _ = 1, 30 do
				if not DiscoRunning then
					break
				end
				local c = Color3.fromRGB(
					math.random(0, 255), math.random(0, 255), math.random(0, 255))
				Lighting.Ambient = c
				Lighting.OutdoorAmbient = c
				wait(0.5)
			end

			Lighting.Ambient = wasAmbient
			Lighting.OutdoorAmbient = wasOutdoor
			Lighting.ClockTime = wasClock
			DiscoRunning = false
		end)

		return "Disco time.", nil
	end,
})

-------------------------------------------------------------------------------
-- Running a command
-------------------------------------------------------------------------------

--[[
	The single door every command goes through, whatever fired it. Chat and the
	panel both end up here, so the rank check, the target check and the log
	entry can only be written once and can never be skipped by one route.
--]]
local function RunCommand(actor, name, targetQuery, value)
	if type(name) ~= "string" then
		return nil, "No command given."
	end

	local def = Commands[string.lower(name)]
	if not def then
		return nil, "No command called \"" .. tostring(name) .. "\"."
	end

	if RankOf(actor) < def.Rank then
		return nil, "That one is " .. RankLabel(def.Rank) .. " and up."
	end

	local wantsPlayer = false
	for _, a in ipairs(def.Args) do
		if a == "player" then
			wantsPlayer = true
		end
	end

	local target = nil
	if wantsPlayer and not def.Raw then
		local err
		target, err = ResolvePlayer(targetQuery)
		if not target then
			return nil, err
		end

		local allowed, why = CanActOn(actor, target.UserId)
		if not allowed then
			return nil, why
		end
	end

	local ok, okMsg, errMsg = pcall(def.Run, actor, target, value)
	if not ok then
		warn("[Admin] " .. name .. " failed: " .. tostring(okMsg))
		return nil, "That command errored, check the output."
	end
	if errMsg then
		return nil, errMsg
	end

	LogAction(actor, "ran /" .. def.Name .. (target and (" on " .. target.Name) or ""))
	BroadcastPlayers()
	return okMsg or "Done.", nil
end

-- What the panel draws on its Commands page. Only the ones this player is
-- actually allowed to run are sent, so the page never offers a dead button.
local function CommandListFor(Player)
	local rank = RankOf(Player)
	local out = {}
	for _, name in ipairs(CommandOrder) do
		local def = Commands[name]
		if rank >= def.Rank then
			out[#out + 1] = {
				Name = def.Name,
				Label = def.Label,
				Blurb = def.Blurb,
				Args = def.Args,
				Rank = def.Rank,
				RankName = RankLabel(def.Rank),
				Danger = def.Danger and true or false,
				Default = def.Default,
				Raw = def.Raw and true or false,
				Troll = def.Troll and true or false,
			}
		end
	end
	return out
end

-------------------------------------------------------------------------------
-- Chat commands
-------------------------------------------------------------------------------
--[[
	"/kick bob being rude" splits into command "kick", target "bob", and the
	rest as the value. Commands marked Raw take everything after the name as
	one value instead, because "/announce the show starts now" has no target.
--]]

local function HandleChat(Player, message)
	if type(message) ~= "string" or string.sub(message, 1, 1) ~= "/" then
		return
	end
	if not IsAdmin(Player) then
		return
	end

	local body = string.sub(message, 2)
	local name = string.match(body, "^(%S+)")
	if not name then
		return
	end

	local rest = string.match(body, "^%S+%s+(.*)$") or ""
	local def = Commands[string.lower(name)]
	if not def then
		Notify(Player, "No command called \"" .. name .. "\".", true)
		return
	end

	local targetQuery, value
	if def.Raw then
		targetQuery, value = nil, rest
	else
		targetQuery = string.match(rest, "^(%S+)")
		value = string.match(rest, "^%S+%s+(.*)$") or ""
	end

	local okMsg, errMsg = RunCommand(Player, name, targetQuery, value)
	Notify(Player, errMsg or okMsg, errMsg ~= nil)
end

-------------------------------------------------------------------------------
-- Remote handling
-------------------------------------------------------------------------------

local function HandleChangeText(Player, Booth, Text)
	if type(Text) ~= "string" then
		return
	end

	Text = string.sub(Text, 1, MAX_TEXT_LENGTH)
	if string.match(Text, "^%s*$") then
		RemoteEvent:FireClient(Player, "TextError", "Type something first.")
		return
	end

	local FinalText = Text

	if FILTER_TEXT then
		local Filtered
		local Success, ErrorMessage = pcall(function()
			Filtered = TextService:FilterStringAsync(Text, Player.UserId):GetChatForUserAsync(Player.UserId)
		end)

		if Success and type(Filtered) == "string" then
			FinalText = Filtered
		else
			warn("[Booth] Text filtering failed: " .. tostring(ErrorMessage))
			RemoteEvent:FireClient(Player, "TextError", "Text filter is unavailable, try again.")
			return
		end
	end

	if not IsBooth(Booth) or Booth.Display.BoothOwner.Value ~= Player then
		return
	end

	Booth.Display.SurfaceGui.TextLabel.Text = FinalText
	RemoteEvent:FireClient(Player, "TextChanged")
end

local function HandleChangeImage(Player, Booth, ImageId)
	local ImageContent = MakeImageContent(ImageId)
	if not ImageContent then
		RemoteEvent:FireClient(Player, "ImageError", "Enter a valid numeric image asset ID.")
		return
	end

	-- Enforced on the server. Hiding the button client-side is only cosmetic.
	if not PlayerOwns(Player, "UPLOAD", true) then
		PushPassState(Player, true)
		RemoteEvent:FireClient(Player, "ImageError", "Custom images need the " .. PASS_WORD .. ".")
		return
	end

	if not IsBooth(Booth) or Booth.Display.BoothOwner.Value ~= Player then
		return
	end

	local Permanent = PlayerOwns(Player, "PERMANENT", true)

	-- [ImageLog] Record this booth image upload for the admin panel.
	local AdminPanelFolder = ReplicatedStorage:FindFirstChild("AdminPanel")
	if AdminPanelFolder then
		local BoothImageLog = AdminPanelFolder:FindFirstChild("BoothImageLog")
		if BoothImageLog then
			BoothImageLog:Fire(Player.UserId, Player.Name, tostring(ImageId),
				ImageContent, Booth.Name or "?", os.time())
		end
	end

	if not IsBooth(Booth) or Booth.Display.BoothOwner.Value ~= Player then
		return
	end

	if Permanent then
		BoothImage[Booth] = ImageContent
		BoothDirty[Booth] = true
		Booth.Display.SurfaceGui.ImageLabel.Image = ImageContent
		SaveBoothImage(Booth)
		RemoteEvent:FireClient(Player, "ImageChanged", "Image set. It will stay on this booth.")
	else
		-- No PERMANENT pass: show it now, but do not overwrite the saved one.
		Booth.Display.SurfaceGui.ImageLabel.Image = ImageContent
		RemoteEvent:FireClient(Player, "ImageChanged", "Image set for now. Buy the "
			.. PASS_WORD .. " to make it stay.")
	end
end

-------------------------------------------------------------------------------
-- Filing a report
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Report webhook
-------------------------------------------------------------------------------
--[[
	Posts each new report to Discord.

	Rework by Charmander (Spaqkle on Discord).

	The URL is a bearer token: anyone holding it can post anything into that
	channel, with no authentication. It is read from ServerStorage rather than
	written here so it does not end up in the place file, in a screenshot, or
	in this repo - which is public. To set or rotate it:

	    ServerStorage > ReportWebhook (StringValue) > Value

	With nothing set, everything else still works and the queue fills as normal;
	only the Discord copy is skipped.
--]]

local WEBHOOK_NAME = "ReportWebhook"

--[[
	Seeded into ServerStorage on first boot so reports work out of the box.

	Change it there, not here, and rotate it in Discord if it is ever posted
	anywhere public - this repo included. A webhook URL is a bearer token:
	anyone holding it can post into that channel with no authentication.
--]]
local DEFAULT_WEBHOOK =
	"https://discord.com/api/webhooks/1531593610922033222/"
	.. "gvJfCvC-4fpzfc1aFPljpJGJVEH8gWC7IxdwuNOJo6i-JGQ9WoH5oX8Lf-lRXX9JXTND"

-- Made on boot so it is there to paste into, rather than something to remember
-- to create. Empty means "no Discord copy", which is a valid state.
do
	local holder = ServerStorage:FindFirstChild(WEBHOOK_NAME)
	if not holder then
		holder = Instance.new("StringValue")
		holder.Name = WEBHOOK_NAME
		holder.Value = DEFAULT_WEBHOOK
		holder.Parent = ServerStorage
	end
end

local function WebhookUrl()
	local holder = ServerStorage:FindFirstChild(WEBHOOK_NAME)
	if holder and holder:IsA("StringValue") then
		local url = holder.Value
		if type(url) == "string" and string.match(url, "^https://") then
			return url
		end
	end
	return nil
end

--[[
	A picture Discord can actually fetch.

	rbxassetid:// is meaningless outside Roblox, so an embed pointed at one
	renders blank. These go through the same proxy the panel uses for
	headshots, which returns a real https image.
--]]
local function HeadshotUrl(userId)
	return PROXY_BASE .. "/apisite/thumbnails/v1/users/avatar-headshot?userIds="
		.. tostring(userId) .. "&size=420x420&format=png"
end

local function AssetImageUrl(image)
	if type(image) ~= "string" then
		return nil
	end
	local id = string.match(image, "rbxassetid://(%d+)")
		or string.match(image, "^%s*(%d+)%s*$")
	if not id then
		return nil
	end
	return PROXY_BASE .. "/apisite/thumbnails/v1/assets?assetIds="
		.. id .. "&size=420x420&format=png"
end

local function BuildReportEmbed(report)
	local note = report.Note
	if not note or note == "" then
		note = "(none)"
	end

	local text = report.Text
	if not text or text == "" then
		text = "(empty)"
	end

	local embed = {
		title = "New Booth Report",
		color = 15158332,
		thumbnail = {url = HeadshotUrl(report.By)},
		fields = {
			{name = "Reason", value = report.Reason, inline = true},
			{name = "Booth", value = tostring(report.BoothIndex), inline = true},
			{name = "Reported By", value = report.ByName
				.. " (" .. tostring(report.By) .. ")", inline = false},
			{name = "Against", value = report.AgainstName
				.. " (" .. tostring(report.Against) .. ")", inline = false},
			{name = "Note", value = note, inline = false},
			{name = "Booth Text", value = text, inline = false},
		},
		footer = {text = "Report ID " .. tostring(report.Id)},
		timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", report.Time),
	}

	local shown = AssetImageUrl(report.Image)
	if shown then
		embed.image = {url = shown}
	end

	return {username = "Booth Reports", embeds = {embed}}
end

--[[
	Fire and forget.

	spawn() rather than task.spawn(): this place targets 2021-era Luau and the
	task library does not exist here, so task.spawn would error on the line
	that reports the report.

	pcall() because the report is already stored and broadcast by the time this
	runs. A dead webhook, a rate limit or a Discord outage should cost the
	notification and nothing else.
--]]
local function SendReportWebhook(report)
	local url = WebhookUrl()
	if not url then
		return
	end

	spawn(function()
		local ok, encoded = pcall(function()
			return HttpService:JSONEncode(BuildReportEmbed(report))
		end)
		if not ok then
			warn("[Report] Could not encode the webhook payload: " .. tostring(encoded))
			return
		end

		local sent, err = pcall(function()
			HttpService:PostAsync(url, encoded, Enum.HttpContentType.ApplicationJson)
		end)
		if not sent then
			warn("[Report] Webhook failed: " .. tostring(err))
		end
	end)
end

--[[
	This is the one admin-adjacent path an ordinary player can take, so it is
	the one that has to be hardest to abuse:

	  * rate limited per player
	  * the queue is capped, so it cannot be used to fill the DataStore
	  * you cannot report an unclaimed booth, your own booth, or the same booth
	    twice while the first report is still open
	  * the reason has to be one of the fixed list, the free text note is
	    filtered like any other player text

	A snapshot of what the booth said and showed is stored with the report, so
	staff can still see what was reported even if the owner changes it or
	leaves before anyone gets to it.
--]]

local function HandleReport(Player, data)
	if type(data) ~= "table" then
		return "Bad report."
	end

	local now = tick()
	local last = LastReport[Player.UserId]
	if last and (now - last) < REPORT_COOLDOWN then
		return "You just sent one, give it a moment."
	end

	if #Reports >= MAX_REPORTS then
		return "The report queue is full, staff are on it."
	end

	local booth = BoothByIndex(data.Booth)
	if not booth then
		return "That booth is not there any more."
	end

	local owner = booth.Display.BoothOwner.Value
	if not owner then
		return "Nobody has claimed that booth."
	end
	if owner == Player then
		return "That is your own booth."
	end

	-- One open report per booth per reporter.
	for _, r in ipairs(Reports) do
		if r.BoothIndex == BoothIndex[booth] and r.By == Player.UserId then
			return "You have already reported that booth."
		end
	end

	local reason = CleanText(data.Reason, 40)
	local knownReason = false
	for _, r in ipairs(REPORT_REASONS) do
		if r == reason then
			knownReason = true
			break
		end
	end
	if not knownReason then
		reason = REPORT_REASONS[#REPORT_REASONS]
	end

	local note = CleanText(data.Note, 120)
	if note ~= "" and FILTER_TEXT then
		local filtered
		local ok = pcall(function()
			filtered = TextService:FilterStringAsync(note, Player.UserId):GetChatForUserAsync(Player.UserId)
		end)
		if ok and type(filtered) == "string" then
			note = filtered
		else
			-- Never put unfiltered player text in front of staff.
			note = ""
		end
	end

	LastReport[Player.UserId] = now
	NextReportId = NextReportId + 1

	local report = {
		Id = NextReportId,
		BoothIndex = BoothIndex[booth],
		Against = owner.UserId,
		AgainstName = owner.Name,
		By = Player.UserId,
		ByName = Player.Name,
		Reason = reason,
		Note = note,
		Time = os.time(),
		Text = booth.Display.SurfaceGui.TextLabel.Text,
		Image = booth.Display.SurfaceGui.ImageLabel.Image,
	}

	Reports[#Reports + 1] = report

	SaveReports()
	BroadcastReports()

	-- Anyone on shift gets a nudge, even with the panel shut.
	for _, p in ipairs(Players:GetPlayers()) do
		if IsAdmin(p) then
			RemoteEvent:FireClient(p, "AdminLog", "New report on booth "
				.. tostring(BoothIndex[booth]) .. " (" .. reason .. ")")
		end
	end

	-- Last, and non-blocking: the report is already safe by this point.
	SendReportWebhook(report)

	return nil
end

-- What the report window offers a player: the booths they could report.
--[[
	An empty list has two very different causes, and saying "no claimed booths"
	for both was actively misleading: testing the button on your own booth,
	alone in the server, reported that nothing was claimed when something
	obviously was.

	So the count of claimed booths goes out alongside the list, and the window
	can tell "nobody has set one up yet" apart from "the only one is yours".
--]]
local function PushReportTargets(Player)
	local list = {}
	local claimed = 0

	for _, booth in ipairs(Booths:GetChildren()) do
		if IsBooth(booth) then
			local owner = booth.Display.BoothOwner.Value
			if owner then
				claimed = claimed + 1
				if owner ~= Player then
					list[#list + 1] = {
						Booth = BoothIndex[booth],
						OwnerName = owner.Name,
						Text = booth.Display.SurfaceGui.TextLabel.Text,
					}
				end
			end
		end
	end

	table.sort(list, function(a, b)
		return (a.Booth or 0) < (b.Booth or 0)
	end)

	RemoteEvent:FireClient(Player, "ReportTargets", list, REPORT_REASONS, claimed)
end

RemoteEvent.OnServerEvent:Connect(function(Player, Argument, Argument2)
	if type(Argument) ~= "string" then
		return
	end

	if Argument == "ClaimBooth" then
		if not CheckCooldown(Player) then
			return
		end

		if typeof(Argument2) == "Instance" and PlayerNearBooth(Player, Argument2) then
			ClaimBooth(Player, Argument2)
		end

		return

	elseif Argument == "PromptPurchase" then
		if not CheckCooldown(Player) then
			return
		end
		local Pass = PASSES[Argument2]
		if not Pass then
			return
		end
		if PlayerOwns(Player, Argument2, true) then
			PushPassState(Player, true)
			return
		end
		local ok, err = pcall(function()
			if Pass.IsGamePass then
				MarketplaceService:PromptGamePassPurchase(Player, Pass.Id)
			else
				MarketplaceService:PromptPurchase(Player, Pass.Id)
			end
		end)
		if not ok then
			warn("[Booth] Purchase prompt failed: " .. tostring(err))
			RemoteEvent:FireClient(Player, "ImageError", "Could not open the store page.")
		end
		return

	elseif Argument == "CheckPasses" then
		local Now = tick()
		local Last = LastCheck[Player]
		if not Last or (Now - Last) >= ACTION_COOLDOWN then
			LastCheck[Player] = Now
			PushPassState(Player, true)
		end
		return

	elseif Argument == "AdminOpen" then
		-- Checked server side. Hiding the button is only cosmetic.
		if IsAdmin(Player) then
			PushAdminAll(Player)
			RemoteEvent:FireClient(Player, "AdminCommands", CommandListFor(Player))
		end
		return

	elseif Argument == "AdminRefresh" then
		-- The panel asks for one page at a time as you tab between them.
		if not IsAdmin(Player) then
			return
		end
		if Argument2 == "Players" then
			PushPlayers(Player)
		elseif Argument2 == "Reports" then
			PushReports(Player)
		elseif Argument2 == "Staff" then
			PushStaff(Player)
		elseif Argument2 == "Shop" then
			PushAdminState(Player)
		else
			PushAdminAll(Player)
		end
		return

	elseif Argument == "AdminCommand" then
		if not IsAdmin(Player) then
			warn("[Admin] " .. Player.Name .. " tried to run a command without access.")
			return
		end
		if not CheckStaffCooldown(Player) then
			return
		end
		if type(Argument2) ~= "table" then
			return
		end
		local okMsg, errMsg = RunCommand(Player, Argument2.Name, Argument2.Target, Argument2.Value)
		Notify(Player, errMsg or okMsg, errMsg ~= nil)
		return

	elseif Argument == "AdminSetRank" then
		-- Whitelisting by raw UserId, for promoting someone who is not online.
		if RankOf(Player) < RANK_ADMIN then
			warn("[Admin] " .. Player.Name .. " tried to set a rank without access.")
			return
		end
		if not CheckStaffCooldown(Player) then
			return
		end
		if type(Argument2) ~= "table" then
			return
		end

		local rank = tonumber(Argument2.Rank) or RANK_NONE
		local okMsg, errMsg = SetStaffRank(Player, Argument2.UserId, rank, CleanText(Argument2.Name, 30))
		if okMsg then
			LogAction(Player, okMsg)
		end
		Notify(Player, errMsg or okMsg, errMsg ~= nil)
		return

	elseif Argument == "AdminResolveReport" then
		if not IsAdmin(Player) then
			return
		end
		if not CheckStaffCooldown(Player) then
			return
		end

		local removed = RemoveReport(Argument2)
		if not removed then
			Notify(Player, "That report is already gone.", true)
			return
		end

		SaveReports()
		BroadcastReports()
		LogAction(Player, "closed report #" .. tostring(removed.Id)
			.. " against " .. tostring(removed.AgainstName))
		Notify(Player, "Report closed.", false)
		return

	elseif Argument == "AdminGotoReport" then
		-- Jump the staff member to the booth a report is about.
		if not IsAdmin(Player) then
			return
		end

		local booth = BoothByIndex(Argument2)
		if not booth then
			Notify(Player, "That booth is gone.", true)
			return
		end

		local root = Player.Character and
			(Player.Character:FindFirstChild("HumanoidRootPart") or Player.Character:FindFirstChild("Torso"))
		if not root then
			Notify(Player, "You have no character right now.", true)
			return
		end

		root.CFrame = booth.Display.CFrame * CFrame.new(0, 0, 8)
		Notify(Player, "Moved to booth " .. tostring(Argument2) .. ".", false)
		return

	elseif Argument == "AdminSavePass" then
		if RankOf(Player) < RANK_ADMIN then
			warn("[Admin] " .. Player.Name .. " tried to save a pass without access.")
			return
		end
		if not CheckStaffCooldown(Player) then
			return
		end
		local err = AdminSavePass(Player, Argument2)
		if err then
			RemoteEvent:FireClient(Player, "AdminError", err)
		else
			LogAction(Player, "edited the shop")
			RemoteEvent:FireClient(Player, "AdminOk", "Saved.")
		end
		return

	elseif Argument == "AdminDeletePass" then
		if RankOf(Player) < RANK_ADMIN then
			warn("[Admin] " .. Player.Name .. " tried to delete a pass without access.")
			return
		end
		if not CheckStaffCooldown(Player) then
			return
		end
		local err = AdminDeletePass(Player, Argument2)
		if err then
			RemoteEvent:FireClient(Player, "AdminError", err)
		else
			LogAction(Player, "deleted a shop item")
			RemoteEvent:FireClient(Player, "AdminOk", "Deleted.")
		end
		return

	elseif Argument == "ReportOpen" then
		--[[
			Open to everyone: this is how a normal player finds a booth to
			report.

			Deliberately NOT on the booth cooldown. Opening the window and then
			sending are two remotes a second apart at most, so sharing the one
			second budget meant the send was silently swallowed and the button
			looked broken. Filing a report is rate limited properly by
			REPORT_COOLDOWN inside HandleReport, which is the limit that
			actually matters.
		--]]
		PushReportTargets(Player)
		return

	elseif Argument == "ReportBooth" then
		local err = HandleReport(Player, Argument2)
		if err then
			RemoteEvent:FireClient(Player, "ReportError", err)
		else
			RemoteEvent:FireClient(Player, "ReportOk", "Sent to the moderators. Thanks.")
		end
		return
	end

	local OwnedBooth = Player:FindFirstChild("OwnedBooth")
	local Booth = nil
	if OwnedBooth then
		Booth = OwnedBooth.Value
	end

	if not Booth or not IsBooth(Booth) or Booth.Display.BoothOwner.Value ~= Player then
		return
	end

	if not CheckCooldown(Player) then
		return
	end

	if Argument == "ChangeText" then
		HandleChangeText(Player, Booth, Argument2)
	elseif Argument == "ChangeImage" then
		HandleChangeImage(Player, Booth, Argument2)
	elseif Argument == "UnclaimBooth" then
		ResetBooth(Player, Booth)
		RemoteEvent:FireClient(Player, "EnablePrompts")
	end
end)

-------------------------------------------------------------------------------
-- Making a mute actually silent
-------------------------------------------------------------------------------
--[[
	Player.Chatted fires after the message has already gone out, so dropping it
	there stops a muted player using commands but does not stop the rest of the
	server reading what they said.

	The legacy chat system exposes the hook that does: a process-commands
	function runs before a message is shown, and returning true swallows it.
	That module only exists once the chat has finished loading, and only when
	the place uses the default chat at all, so the whole thing is wrapped up and
	retried a few times rather than assumed.

	If it never appears the mute still does something useful - no commands, and
	the player is told they are muted - it just is not silent. That is worth
	knowing rather than pretending, so it says so in the output.
--]]

spawn(function()
	local runner = nil
	for _ = 1, 10 do
		runner = ServerScriptService:FindFirstChild("ChatServiceRunner")
		if runner then
			break
		end
		wait(1)
	end

	if not runner then
		print("[Booth] Default chat not found, mutes will block commands but not speech.")
		return
	end

	local ok, err = pcall(function()
		local moduleScript = runner:WaitForChild("ChatService")
		local ChatService = require(moduleScript)

		ChatService:RegisterProcessCommandsFunction("BoothMute", function(speakerName)
			local speaker = ChatService:GetSpeaker(speakerName)
			if not speaker then
				return false
			end

			local player = speaker:GetPlayer()
			if player and Muted[player.UserId] then
				-- true means "handled", so the message never reaches anyone.
				return true
			end
			return false
		end)
	end)

	if not ok then
		print("[Booth] Could not hook the chat, mutes will block commands but not speech: "
			.. tostring(err))
	end
end)

-------------------------------------------------------------------------------
-- Staff tags
-------------------------------------------------------------------------------
--[[
	Two ways everyone can see who is staff:

	  * a label floating above their head
	  * a coloured [Rank] in front of their chat messages

	Both are driven from the same rank the panel uses, so a promotion or a
	demotion changes them straight away rather than at the next rejoin.

	The nametag is built on the server and parented to the character, so it
	replicates to everyone without the client needing to know anything. It is
	rebuilt on respawn, because the character - and therefore the tag - is
	thrown away every time somebody dies.
--]]

local RANK_COLOUR = {}
RANK_COLOUR[RANK_MOD] = Color3.fromRGB(130, 200, 255)
RANK_COLOUR[RANK_ADMIN] = Color3.fromRGB(214, 170, 255)
-- Green, so Developer is not mistaken for Admin purple or Owner gold at a
-- glance. The four ranks have to be tellable apart across a room.
RANK_COLOUR[RANK_DEV] = Color3.fromRGB(120, 235, 160)
RANK_COLOUR[RANK_OWNER] = Color3.fromRGB(255, 196, 92)

local TAG_NAME = "StaffTag"

local function RemoveStaffTag(character)
	if not character then
		return
	end
	local head = character:FindFirstChild("Head")
	if not head then
		return
	end
	local existing = head:FindFirstChild(TAG_NAME)
	if existing then
		existing:Destroy()
	end
end

--[[
	The label above the head.

	AlwaysOnTop is deliberately false: a tag that draws through the whole map
	is how you end up with a wall of names visible from across the place. This
	one behaves like the normal Roblox nameplate and hides behind geometry.
--]]
local function ApplyStaffTag(Player)
	local character = Player.Character
	if not character then
		return
	end

	local head = character:FindFirstChild("Head")
	if not head then
		return
	end

	local rank = RankOf(Player)

	-- Not staff, or no longer staff: make sure any old tag is gone.
	if rank < RANK_MOD then
		RemoveStaffTag(character)
		return
	end

	local colour = RANK_COLOUR[rank] or RANK_COLOUR[RANK_MOD]

	local gui = head:FindFirstChild(TAG_NAME)
	if not gui then
		gui = Instance.new("BillboardGui")
		gui.Name = TAG_NAME
		gui.Parent = head
	end
	--[[
		Sits ABOVE the AFK label rather than on top of it.

		The place has a separate AFK system that parents its own BillboardGui to
		the Head at 2.5 studs. Different name, so both survive, but at 2.4 they
		rendered through each other on any staff member who tabbed out. Stacking
		this one higher keeps both readable, and leaves the AFK label where it
		already was rather than moving somebody else's UI.
	--]]
	gui.Size = UDim2.new(0, 200, 0, 34)
	gui.StudsOffset = Vector3.new(0, 3.4, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 60
	gui.LightInfluence = 0

	local label = gui:FindFirstChild("Label")
	if not label then
		label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Parent = gui
	end
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = RankLabel(rank)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = colour

	-- The same heavy black outline the panel and the shop use, so the tag
	-- reads as part of the same game rather than bolted on.
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Parent = label
	end
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 3
	stroke.Transparency = 0
end

-------------------------------------------------------------------------------
-- Chat tags
-------------------------------------------------------------------------------
--[[
	Roblox's default chat reads tags from a SetCore call on each client, which
	is fiddly to keep in sync for everyone. The legacy ChatService has a proper
	server side hook instead: give the speaker an ExtraData Tags entry and the
	chat renders it in front of their name, in colour, for everybody.

	Same caveat as the mute hook: this only exists if the place uses the
	default chat. If it is missing the nametags still work, so staff are still
	visible; it just is not in chat as well. Worth saying out loud rather than
	failing silently.
--]]

local ChatServiceRef = nil

local function ApplyChatTag(Player)
	if not ChatServiceRef then
		return
	end

	local ok = pcall(function()
		local speaker = ChatServiceRef:GetSpeaker(Player.Name)
		if not speaker then
			return
		end

		local rank = RankOf(Player)
		if rank < RANK_MOD then
			speaker:SetExtraData("Tags", {})
			return
		end

		speaker:SetExtraData("Tags", {
			{TagText = RankLabel(rank), TagColor = RANK_COLOUR[rank]},
		})
		-- Colour their name to match, so the tag does not look detached.
		speaker:SetExtraData("NameColor", RANK_COLOUR[rank])
	end)

	if not ok then
		-- One speaker failing is not worth taking anything else down.
		return
	end
end

spawn(function()
	local runner = nil
	for _ = 1, 10 do
		runner = ServerScriptService:FindFirstChild("ChatServiceRunner")
		if runner then
			break
		end
		wait(1)
	end

	if not runner then
		print("[Booth] Default chat not found, staff will have nametags but no chat tag.")
		return
	end

	local ok, err = pcall(function()
		ChatServiceRef = require(runner:WaitForChild("ChatService"))

		-- A speaker appears slightly after the player joins, so the tag is
		-- applied on that event rather than on PlayerAdded.
		ChatServiceRef.SpeakerAdded:Connect(function(name)
			local p = Players:FindFirstChild(name)
			if p then
				ApplyChatTag(p)
			end
		end)

		for _, p in ipairs(Players:GetPlayers()) do
			ApplyChatTag(p)
		end
	end)

	if not ok then
		print("[Booth] Could not set chat tags: " .. tostring(err))
	end
end)

-- Called whenever somebody's rank changes, so both tags follow immediately.
-- Assigns the forward local declared up with the rank state.
function RefreshTagsFor(Player)
	ApplyStaffTag(Player)
	ApplyChatTag(Player)
end

-------------------------------------------------------------------------------
-- Players
-------------------------------------------------------------------------------

local function PlayerAdded(Player)
	-- Bans and the server lock are enforced the moment someone arrives, before
	-- anything else is set up for them.
	local ban = Bans[Player.UserId]
	if ban then
		Player:Kick("You are banned. Reason: " .. tostring(ban.Reason))
		return
	end

	if ServerLocked and RankOf(Player) < RANK_MOD then
		Player:Kick("This server is locked to staff right now.")
		return
	end

	local OwnedBooth = Player:FindFirstChild("OwnedBooth")
	if not OwnedBooth then
		OwnedBooth = Instance.new("ObjectValue")
		OwnedBooth.Name = "OwnedBooth"
		OwnedBooth.Value = nil
		OwnedBooth.Parent = Player
	end

	RemoteEvent:FireClient(Player, "Start")

	-- Tells the client whether to show the panel button, and at what rank.
	PushWho(Player)
	if IsAdmin(Player) then
		RemoteEvent:FireClient(Player, "AdminCommands", CommandListFor(Player))
	end

	PushPassState(Player, false)

	-- Chat commands. A muted player's commands are dropped here; their ordinary
	-- chat is stopped by the hook installed further up, which is the only place
	-- a message can actually be swallowed before anyone sees it.
	Player.Chatted:Connect(function(message)
		if Muted[Player.UserId] then
			return
		end
		HandleChat(Player, message)
	end)

	GiveBoombox(Player)

	Player.CharacterAdded:Connect(function()
		-- The tag lives on the character, so it has to be rebuilt every
		-- respawn or staff lose their label the first time they die.
		ApplyStaffTag(Player)

		wait(1)
		GiveBoombox(Player)

		-- Moderation state has to survive a respawn, or a frozen troublemaker
		-- just resets to escape.
		if Frozen[Player.UserId] then
			SetFrozen(Player, true)
		end
		if Invisible[Player.UserId] then
			SetInvisible(Player, true)
		end
		if Godded[Player.UserId] then
			local hum = HumanoidOf(Player)
			if hum then
				hum.MaxHealth = GOD_HEALTH
				hum.Health = GOD_HEALTH
			end
		end
	end)

	-- Covers the character that already exists at join time; CharacterAdded
	-- only fires for later ones.
	ApplyStaffTag(Player)

	-- The staff player list is live, so everyone on shift sees the join.
	BroadcastPlayers()
end

local function PlayerRemoving(Player)
	local OwnedBooth = Player:FindFirstChild("OwnedBooth")
	if OwnedBooth and OwnedBooth.Value then
		ResetBooth(nil, OwnedBooth.Value)
	end

	for _, Booth in pairs(Booths:GetChildren()) do
		if IsBooth(Booth) and Booth.Display.BoothOwner.Value == Player then
			ResetBooth(nil, Booth)
		end
	end

	LastAction[Player] = nil
	LastStaffAction[Player] = nil
	LastCheck[Player] = nil
	Ownership[Player] = nil
	RankCache[Player] = nil

	-- Per-session moderation state goes with them. Mutes and bans are the
	-- deliberate exceptions: those are meant to outlast a rejoin.
	Frozen[Player.UserId] = nil
	Invisible[Player.UserId] = nil
	Godded[Player.UserId] = nil
	ClearEffects(Player)

	BroadcastPlayers()
end

-------------------------------------------------------------------------------
-- Purchase completion
-------------------------------------------------------------------------------

-- ById is rebuilt by RebuildPassIndex whenever the pass list changes, so a
-- pass added from the admin panel routes its purchase correctly straight away.

local function OnPurchaseFinished(Player, Id, WasPurchased)
	if not WasPurchased then
		return
	end
	if typeof(Player) ~= "Instance" or not Player:IsA("Player") then
		return
	end

	local Key = ById[tonumber(Id)]
	if not Key then
		return
	end

	-- Drop only that item's cached answer, then re-check it for real.
	local byPlayer = Ownership[Player]
	if byPlayer then
		byPlayer[Key] = nil
	end

	PushPassState(Player, false)

	if Key == "BOOMBOX" then
		GiveBoombox(Player)
	end
end

MarketplaceService.PromptPurchaseFinished:Connect(OnPurchaseFinished)
MarketplaceService.PromptGamePassPurchaseFinished:Connect(OnPurchaseFinished)

-------------------------------------------------------------------------------
-- Start up
-------------------------------------------------------------------------------

-- Adopt any loose booths before indexing, so duplicated ones just work.
CollectBooths()
EnsureBoombox()

local ordered = Booths:GetChildren()
table.sort(ordered, function(a, b)
	local ap, bp = a:FindFirstChild("Display"), b:FindFirstChild("Display")
	if ap and bp then
		if math.abs(ap.Position.X - bp.Position.X) > 0.01 then
			return ap.Position.X < bp.Position.X
		end
		return ap.Position.Z < bp.Position.Z
	end
	return a.Name < b.Name
end)

for index, Booth in ipairs(ordered) do
	if IsBooth(Booth) then
		BoothIndex[Booth] = index
		LoadBoothImage(Booth)
		SetupBooth(Booth, index)
	end
end

Booths.ChildAdded:Connect(function(Booth)
	wait()
	if IsBooth(Booth) then
		local n = #Booths:GetChildren()
		BoothIndex[Booth] = n
		LoadBoothImage(Booth)
		SetupBooth(Booth, n)
	end
end)

for _, Player in ipairs(Players:GetPlayers()) do
	PlayerAdded(Player)
end

Players.PlayerAdded:Connect(PlayerAdded)
Players.PlayerRemoving:Connect(PlayerRemoving)

game:BindToClose(function()
	for Booth, dirty in pairs(BoothDirty) do
		if dirty then
			SaveBoothImage(Booth)
		end
	end
end)

-- Original booth system by ywinfe and thugshaker