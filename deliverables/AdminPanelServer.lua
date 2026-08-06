--[[
	Admin Panel — Server (for r45 / 2021 client)
	================================================
	WHERE:  ServerScriptService -> Script named "AdminPanelServer"

	Two features:

	1. IMAGE LOG  — every booth image upload logged permanently in
	   DataStore "BoothImageLogs_v1" (id, image, user, booth, time),
	   newest first, capped 500, searchable by username, live-pushed to
	   admins.

	NET (all under ReplicatedStorage.AdminPanel):
	  * BoothImageLog     BindableEvent
	  * GetImageLogs      RemoteFunction
	  * ImageLogBroadcast RemoteEvent

	REQUIRED — the 3-line hook inside ServerScriptService.Server
	(HandleChangeImage), placed right after:
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

	2021 compatible: no task.*, no string interpolation, no FontFace.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")

------------------------------------------------------------------
-- Admin check (mirrors ServerScriptService.Server)
------------------------------------------------------------------

local OWNERS = {
	[49603] = "thugshaker",
	[78857] = "qzc",
	[181869] = "ywinfe",
}

local DEVELOPERS = {
	[18205] = "vxy",
}

local ALLOW_PLACE_OWNER = true

local RANK_MOD = 1
local RANK_ADMIN = 2
local RANK_DEV = 3
local RANK_OWNER = 4

local StaffWhitelist = {}

local function LoadWhitelist()
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore("StaffList_v2")
	end)
	if not ok then
		return
	end
	local ok2, res = pcall(function()
		return store:GetAsync("staff")
	end)
	if ok2 and type(res) == "table" then
		for key, row in pairs(res) do
			local userId = tonumber(key)
			local rank = tonumber(type(row) == "table" and row.Rank or 0)
			if userId and rank and rank >= RANK_MOD and rank < RANK_DEV then
				StaffWhitelist[userId] = rank
			end
		end
	end
end

local function RankOf(player)
	local userId = player.UserId
	if OWNERS[userId] then
		return RANK_OWNER
	end
	if DEVELOPERS[userId] then
		return RANK_DEV
	end
	local wl = StaffWhitelist[userId]
	if wl then
		return wl
	end
	if ALLOW_PLACE_OWNER and game.CreatorType == Enum.CreatorType.User then
		local ok, creatorId = pcall(function()
			return game.CreatorId
		end)
		if ok and creatorId == userId then
			return RANK_OWNER
		end
	end
	return 0
end

local function IsAdmin(player)
	return RankOf(player) >= RANK_MOD
end

spawn(LoadWhitelist)

------------------------------------------------------------------
-- Net (ReplicatedStorage.AdminPanel)
------------------------------------------------------------------

local Folder = ReplicatedStorage:FindFirstChild("AdminPanel")
if not Folder then
	Folder = Instance.new("Folder")
	Folder.Name = "AdminPanel"
	Folder.Parent = ReplicatedStorage
end

local function GetOrCreate(class, name)
	local inst = Folder:FindFirstChild(name)
	if not inst then
		inst = Instance.new(class)
		inst.Name = name
		inst.Parent = Folder
	end
	return inst
end

local BoothImageLog = GetOrCreate("BindableEvent", "BoothImageLog")
local GetImageLogs = GetOrCreate("RemoteFunction", "GetImageLogs")
local ImageLogBroadcast = GetOrCreate("RemoteEvent", "ImageLogBroadcast")

------------------------------------------------------------------
-- IMAGE LOG
------------------------------------------------------------------

local MAX_LOGS = 500
local LogStore = nil
local Logs = {}   -- newest first: {u, n, id, img, b, t}
local LogDirty = false
local LogSavePending = false

local function GetLogStore()
	if LogStore then
		return LogStore
	end
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore("BoothImageLogs_v1")
	end)
	if ok then
		LogStore = res
	else
		warn("[AdminPanel] image log DataStore unavailable — logs will be session-only.")
	end
	return LogStore
end

local function SaveLogs()
	if not LogDirty then
		return
	end
	local store = GetLogStore()
	if not store then
		return
	end
	LogDirty = false
	local ok, err = pcall(function()
		store:SetAsync("logs", Logs)
	end)
	if not ok then
		warn("[AdminPanel] could not save image log: " .. tostring(err))
		LogDirty = true
	end
end

local function FlushLogsSoon()
	if LogSavePending then
		return
	end
	LogSavePending = true
	spawn(function()
		wait(10)
		LogSavePending = false
		SaveLogs()
	end)
end

local function SanitizeEntry(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local entry = {
		u = tonumber(raw.u) or 0,
		n = tostring(raw.n or "?"),
		id = tostring(raw.id or "?"),
		img = tostring(raw.img or ""),
		b = tostring(raw.b or "?"),
		t = tonumber(raw.t) or os.time(),
	}
	if entry.id == "?" or entry.n == "?" then
		return nil
	end
	return entry
end

local function LoadLogs()
	local store = GetLogStore()
	if not store then
		return
	end
	local ok, res = pcall(function()
		return store:GetAsync("logs")
	end)
	if ok and type(res) == "table" then
		Logs = {}
		for _, raw in ipairs(res) do
			local entry = SanitizeEntry(raw)
			if entry then
				table.insert(Logs, entry)
			end
		end
		while #Logs > MAX_LOGS do
			table.remove(Logs)
		end
		LogDirty = false
	elseif not ok then
		warn("[AdminPanel] could not load image log: " .. tostring(res))
	end
end

BoothImageLog.Event:Connect(function(userId, userName, imageId, image, booth, time)
	local prev = Logs[1]
	if prev and prev.u == tonumber(userId) and prev.id == tostring(imageId)
		and prev.b == tostring(booth) and (os.time() - (prev.t or 0)) < 5 then
		return
	end
	local entry = {
		u = tonumber(userId) or 0,
		n = tostring(userName or "?"),
		id = tostring(imageId or "?"),
		img = tostring(image or ""),
		b = tostring(booth or "?"),
		t = tonumber(time) or os.time(),
	}
	table.insert(Logs, 1, entry)
	while #Logs > MAX_LOGS do
		table.remove(Logs)
	end
	LogDirty = true
	FlushLogsSoon()
	for _, p in ipairs(Players:GetPlayers()) do
		if IsAdmin(p) then
			ImageLogBroadcast:FireClient(p, entry)
		end
	end
end)

GetImageLogs.OnServerInvoke = function(player, search)
	if not IsAdmin(player) then
		return {}
	end
	local needle = tostring(search or ""):lower()
	local out = {}
	for _, entry in ipairs(Logs) do
		if needle == "" or tostring(entry.n or ""):lower():find(needle, 1, true) then
			out[#out + 1] = entry
			if #out >= MAX_LOGS then
				break
			end
		end
	end
	return out
end

------------------------------------------------------------------
-- Boot / shutdown
------------------------------------------------------------------


