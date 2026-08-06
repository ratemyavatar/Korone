--[[
	Admin Panel — Client (for r45 / 2021 client)
	================================================
	WHERE:  StarterGui -> LocalScript "AdminPanelClient"  (one script,
	        builds the whole glass panel at run time)

	Features:
	  * Jarvis-style glass: translucent panels, cyan glow border, sheen.
	  * Opening smoothly moves the camera to face your character, then
	    fades the panel in (staggered fade + scale pop + shine sweep).
	  * Tabs: COMMANDS / PLAYERS / IMAGE LOGS.
	      COMMANDS  grid of every staff command the server allows, with a
	                target + value dock and a free-text command box.
	      PLAYERS   tap a player to pick them as the command target, or
	                tap the rank button to open a dropdown and promote /
	                demote them (Mod / Admin / Remove — the server only
	                allows those; Owner/Dev are script-locked).
	      IMAGE LOGS  every image uploaded to a booth: thumbnail, asset
	                id, uploader, booth, time. Searchable by username,
	                permanent, live-updating.
	  * Mobile compatible: the panel scales to fit any screen, and every
	    button works with touch.

	Uses the game's existing plumbing (ReplicatedStorage.RemoteEvent
	"AdminOpen"/"AdminAccess"/"AdminCommands"/"AdminCommand"/"AdminSetRank")
	and the ReplicatedStorage.AdminPanel remotes from AdminPanelServer.

	2021 compatible: no task.*, no CanvasGroup, no string interpolation,
	no FontFace, no Enum.AutomaticSize.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
if not Player then
	return
end
local PlayerGui = Player:WaitForChild("PlayerGui")

local BoothRemote = ReplicatedStorage:WaitForChild("RemoteEvent")

------------------------------------------------------------------
-- Palette (glass / Jarvis)
------------------------------------------------------------------

local GLASS = Color3.fromRGB(22, 30, 46)
local GLASS_DEEP = Color3.fromRGB(14, 20, 32)
local GLASS_LIGHT = Color3.fromRGB(38, 52, 76)
local CYAN = Color3.fromRGB(0, 200, 255)
local CYAN_DIM = Color3.fromRGB(0, 140, 190)
local TEXT = Color3.fromRGB(226, 238, 248)
local MUTED = Color3.fromRGB(140, 158, 180)
local DANGER = Color3.fromRGB(255, 110, 120)

local FONT = Enum.Font.Gotham
local FONT_BOLD = Enum.Font.GothamBold

local RANK = {
	None = 0,
	Mod = 1,
	Admin = 2,
	Dev = 3,
	Owner = 4,
}

------------------------------------------------------------------
-- Small builders
------------------------------------------------------------------

local function New(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do
		-- One bad property value must never kill the whole panel.
		local ok, err = pcall(function()
			obj[k] = v
		end)
		if not ok then
			warn("[AdminPanel] could not set " .. class .. "." .. tostring(k)
				.. " (" .. tostring(err) .. ")")
		end
	end
	if parent then
		obj.Parent = parent
	end
	return obj
end

local function Glass(frame, radius, glow)
	frame.BackgroundColor3 = GLASS
	frame.BackgroundTransparency = 0.35
	frame.BorderSizePixel = 0
	local corner = New("UICorner", { CornerRadius = UDim.new(0, radius or 12) }, frame)
	local stroke = New("UIStroke", {
		Color = glow and CYAN or CYAN_DIM,
		Thickness = 2,
		Transparency = glow and 0.35 or 0.7,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, frame)
	local grad = New("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, GLASS_LIGHT),
			ColorSequenceKeypoint.new(1, GLASS_DEEP),
		}),
		Rotation = 45,
	}, frame)
	return corner, stroke, grad
end

local function GlassLabel(text, size, color, parent, bold)
	return New("TextLabel", {
		BackgroundTransparency = 1,
		Font = bold and FONT_BOLD or FONT,
		Text = text,
		TextColor3 = color or TEXT,
		TextSize = size or 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextStrokeTransparency = 0.4,
		Size = UDim2.new(1, 0, 1, 0),
	}, parent)
end

------------------------------------------------------------------
-- Screen + master frame
------------------------------------------------------------------

local Screen = New("ScreenGui", {
	Name = "AdminControl",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, PlayerGui)

local Panel = New("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.new(0, 720, 0, 470),
	Visible = false,
}, Screen)
Glass(Panel, 16, true)
local PanelScale = New("UIScale", { Scale = 1 }, Panel)

-- accent glow line along the top
local GlowBar = New("Frame", {
	Size = UDim2.new(1, -8, 0, 3),
	Position = UDim2.new(0.5, 0, 0, 4),
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = CYAN,
	BackgroundTransparency = 0.2,
	BorderSizePixel = 0,
}, Panel)
New("UICorner", { CornerRadius = UDim.new(1, 0) }, GlowBar)

-- shine sweep (animated on open)
local Shine = New("Frame", {
	Size = UDim2.new(0.25, 0, 1.15, 0),
	Position = UDim2.new(-0.3, 0, 0, 0),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BackgroundTransparency = 0.85,
	BorderSizePixel = 0,
	Rotation = 18,
	ZIndex = 50,
}, Panel)
local ShineGrad = New("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
	}),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.45, 0.7),
		NumberSequenceKeypoint.new(0.55, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	}),
	Rotation = 90,
}, Shine)

------------------------------------------------------------------
-- Header
------------------------------------------------------------------

local Header = New("Frame", {
	Size = UDim2.new(1, 0, 0, 46),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
}, Panel)

GlassLabel("ADMIN // CONTROL", 20, CYAN, Header, true)

local CloseBtn = New("TextButton", {
	Size = UDim2.new(0, 34, 0, 34),
	Position = UDim2.new(1, -40, 0, 6),
	BackgroundColor3 = GLASS_DEEP,
	BackgroundTransparency = 0.3,
	BorderSizePixel = 0,
	Text = "",
	AutoButtonColor = true,
}, Header)
Glass(CloseBtn, 10, true)
GlassLabel("X", 18, TEXT, CloseBtn, true).TextXAlignment = Enum.TextXAlignment.Center

------------------------------------------------------------------
-- Tab bar
------------------------------------------------------------------

local Tabs = New("Frame", {
	Size = UDim2.new(1, 0, 0, 38),
	Position = UDim2.new(0, 0, 0, 46),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
}, Panel)

local TabButtons = {}
local function MakeTab(name, x)
	local btn = New("TextButton", {
		Size = UDim2.new(0, 150, 0, 30),
		Position = UDim2.new(0, x, 0, 4),
		BackgroundColor3 = GLASS_DEEP,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
	}, Tabs)
	Glass(btn, 8, false)
	local lbl = GlassLabel(name, 14, MUTED, btn, true)
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	TabButtons[name] = { Btn = btn, Lbl = lbl }
	return btn
end
MakeTab("COMMANDS", 10)
MakeTab("PLAYERS", 170)
MakeTab("IMAGE LOGS", 330)

------------------------------------------------------------------
-- Pages
------------------------------------------------------------------

local Pages = {}

local function NewPage()
	local page = New("Frame", {
		Size = UDim2.new(1, -20, 1, -96),
		Position = UDim2.new(0, 10, 0, 90),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
	}, Panel)
	Pages[#Pages + 1] = page
	return page
end

local SelectedCommand = nil
local SelectedTarget = nil
local CommandDefs = {}

------------------------------------------------------------------
-- COMMANDS page
------------------------------------------------------------------

local CommandsPage = NewPage()
local CmdScroll = New("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 242),
	Position = UDim2.new(0, 0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = CYAN_DIM,
	CanvasSize = UDim2.new(0, 0, 0, 0),
}, CommandsPage)

-- input dock
local Dock = New("Frame", {
	Size = UDim2.new(1, 0, 0, 56),
	Position = UDim2.new(0, 0, 1, 0),
	AnchorPoint = Vector2.new(0, 1),
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
}, CommandsPage)
Glass(Dock, 10, false)

local TargetBox = New("TextBox", {
	Size = UDim2.new(0, 180, 0, 34),
	Position = UDim2.new(0, 10, 0, 10),
	BackgroundColor3 = GLASS_DEEP,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	PlaceholderText = "Target player",
	PlaceholderColor3 = MUTED,
	Text = "",
	TextColor3 = TEXT,
	Font = FONT,
	TextSize = 14,
	ClearTextOnFocus = false,
}, Dock)
Glass(TargetBox, 8, false)

local ValueBox = New("TextBox", {
	Size = UDim2.new(0, 320, 0, 34),
	Position = UDim2.new(0, 200, 0, 10),
	BackgroundColor3 = GLASS_DEEP,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	PlaceholderText = "Value (free text for raw commands)",
	PlaceholderColor3 = MUTED,
	Text = "",
	TextColor3 = TEXT,
	Font = FONT,
	TextSize = 14,
	ClearTextOnFocus = false,
}, Dock)
Glass(ValueBox, 8, false)

local CmdStatus = GlassLabel("", 12, MUTED, Dock)
CmdStatus.Position = UDim2.new(0, 528, 0, 10)
CmdStatus.Size = UDim2.new(0, 150, 0, 34)

local function SetStatus(text, bad)
	CmdStatus.Text = text or ""
	CmdStatus.TextColor3 = bad and DANGER or CYAN
end

local function FireCommand(name, target, value)
	BoothRemote:FireServer("AdminCommand", {
		Name = name,
		Target = target,
		Value = value or "",
	})
end

local function BuildCommands(list)
	CmdScroll:ClearAllChildren()
	CommandDefs = {}
	local grid = New("UIGridLayout", {
		CellSize = UDim2.new(0, 165, 0, 40),
		CellPadding = UDim2.new(0, 8, 0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal,
	}, CmdScroll)
	for i, def in ipairs(list or {}) do
		CommandDefs[def.Name] = def
		local btn = New("TextButton", {
			Size = UDim2.new(0, 165, 0, 40),
			BackgroundColor3 = GLASS_DEEP,
			BackgroundTransparency = 0.4,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = true,
			LayoutOrder = i,
		}, CmdScroll)
		Glass(btn, 8, false)
		local stroke = btn:FindFirstChildOfClass("UIStroke")
		local lbl = GlassLabel(def.Label or def.Name, 14,
			def.Danger and DANGER or TEXT, btn, true)
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextTruncate = Enum.TextTruncate.AtEnd
		btn.MouseButton1Click:Connect(function()
			SelectedCommand = def.Name
			for _, other in ipairs(CmdScroll:GetChildren()) do
				if other:IsA("TextButton") and other ~= btn then
					local st = other:FindFirstChildOfClass("UIStroke")
					if st then
						st.Color = CYAN_DIM
						st.Transparency = 0.7
						st.Thickness = 2
					end
				end
			end
			stroke.Color = CYAN
			stroke.Transparency = 0.2
			stroke.Thickness = 3
			TargetBox.Visible = not def.Raw
			ValueBox.Position = def.Raw and UDim2.new(0, 10, 0, 10)
				or UDim2.new(0, 200, 0, 10)
			ValueBox.Size = def.Raw and UDim2.new(0, 500, 0, 34)
				or UDim2.new(0, 320, 0, 34)
			SetStatus("Selected /" .. def.Name, false)
		end)
	end
	local cols = math.max(1, math.floor((Panel.AbsoluteSize.X - 40) / 173))
	local rows = math.max(1, math.ceil(#(list or {}) / cols))
	CmdScroll.CanvasSize = UDim2.new(0, 0, 0, rows * 48 + 8)
end

local ExecBtn = New("TextButton", {
	Size = UDim2.new(0, 100, 0, 34),
	Position = UDim2.new(1, -110, 0, 10),
	BackgroundColor3 = GLASS_LIGHT,
	BackgroundTransparency = 0.3,
	BorderSizePixel = 0,
	Text = "",
	AutoButtonColor = true,
}, Dock)
Glass(ExecBtn, 8, true)
GlassLabel("EXECUTE", 14, CYAN, ExecBtn, true).TextXAlignment = Enum.TextXAlignment.Center
ExecBtn.MouseButton1Click:Connect(function()
	if not SelectedCommand then
		SetStatus("Pick a command first", true)
		return
	end
	local def = CommandDefs[SelectedCommand]
	local target = nil
	if def and not def.Raw then
		target = TargetBox.Text
	end
	FireCommand(SelectedCommand, target, ValueBox.Text)
	SetStatus("Sending /" .. SelectedCommand .. "...", false)
end)

-- free-text command box (like typing in chat)
local FreeText = New("TextBox", {
	Size = UDim2.new(1, -130, 0, 34),
	Position = UDim2.new(0, 10, 0, 250),
	BackgroundColor3 = GLASS_DEEP,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	PlaceholderText = "Type a command, e.g. /kick bob spamming  —  Enter to run",
	PlaceholderColor3 = MUTED,
	Text = "",
	TextColor3 = TEXT,
	Font = FONT,
	TextSize = 14,
	ClearTextOnFocus = false,
}, CommandsPage)
Glass(FreeText, 8, false)
FreeText.FocusLost:Connect(function(enter)
	if not enter then
		return
	end
	local text = FreeText.Text
	FreeText.Text = ""
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	if text == "" then
		return
	end
	if string.sub(text, 1, 1) == "/" then
		text = string.sub(text, 2)
	end
	local name = string.match(text, "^(%S+)")
	if not name then
		return
	end
	local rest = string.match(text, "^%S+%s+(.*)$") or ""
	local def = CommandDefs[name]
	if def and def.Raw then
		FireCommand(name, nil, rest)
	else
		local target = string.match(rest, "^(%S+)")
		local value = string.match(rest, "^%S+%s+(.*)$") or ""
		FireCommand(name, target, value)
	end
	SetStatus("Ran /" .. name, false)
end)

------------------------------------------------------------------
-- PLAYERS page
------------------------------------------------------------------

local PlayersPage = NewPage()
local PlayerScroll = New("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, -46),
	Position = UDim2.new(0, 0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = CYAN_DIM,
	CanvasSize = UDim2.new(0, 0, 0, 0),
}, PlayersPage)

local PlayerStatus = GlassLabel("", 12, MUTED, PlayersPage)
PlayerStatus.Position = UDim2.new(0, 0, 1, -2)
PlayerStatus.AnchorPoint = Vector2.new(0, 1)
PlayerStatus.Size = UDim2.new(1, 0, 0, 22)

local function SetPlayerStatus(text, bad)
	PlayerStatus.Text = text or ""
	PlayerStatus.TextColor3 = bad and DANGER or CYAN
end

-- rank dropdown (promote / demote a tapped player)
local RankDropdown = New("Frame", {
	Size = UDim2.new(0, 150, 0, 0),
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 60,
}, PlayersPage)
Glass(RankDropdown, 8, true)

local function HideRankDropdown()
	RankDropdown.Visible = false
	RankDropdown:ClearAllChildren()
end

local function ShowRankDropdown(row, targetPlayer, myRank)
	RankDropdown:ClearAllChildren()
	local options = {}
	-- The booth server only allows Mod/Admin/Remove in-game; Developer and
	-- Owner are hard-coded in the script and cannot be granted.
	if myRank >= RANK.Owner then
		options = {
			{ Label = "Admin", Rank = RANK.Admin },
			{ Label = "Mod", Rank = RANK.Mod },
			{ Label = "Remove Staff", Rank = RANK.None },
		}
	elseif myRank >= RANK.Admin then
		options = {
			{ Label = "Mod", Rank = RANK.Mod },
			{ Label = "Remove Staff", Rank = RANK.None },
		}
	elseif myRank >= RANK.Mod then
		options = {
			{ Label = "Remove Staff", Rank = RANK.None },
		}
	end

	local layout = New("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, RankDropdown)
	New("UIPadding", {
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 4),
	}, RankDropdown)

	for i, opt in ipairs(options) do
		local btn = New("TextButton", {
			Size = UDim2.new(1, -8, 0, 28),
			BackgroundColor3 = GLASS_LIGHT,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = true,
			LayoutOrder = i,
		}, RankDropdown)
		Glass(btn, 6, opt.Rank ~= RANK.None)
		local color = opt.Rank == RANK.Admin and CYAN
			or opt.Rank == RANK.Mod and Color3.fromRGB(130, 200, 255)
			or DANGER
		GlassLabel(opt.Label, 13, color, btn, true).TextXAlignment = Enum.TextXAlignment.Center
		btn.MouseButton1Click:Connect(function()
			HideRankDropdown()
			BoothRemote:FireServer("AdminSetRank", {
				Rank = opt.Rank,
				UserId = targetPlayer.UserId,
				Name = targetPlayer.Name,
			})
			SetPlayerStatus("Setting " .. targetPlayer.Name .. " to " ..
				(opt.Rank == RANK.None and "no staff rank" or opt.Label) .. "...", false)
		end)
	end

	RankDropdown.Size = UDim2.new(0, 150, 0, #options * 32 + 8)

	-- position the dropdown under the tapped row, inside the page
	local pagePos = PlayersPage.AbsolutePosition
	local relX = row.AbsolutePosition.X - pagePos.X
	local relY = row.AbsolutePosition.Y - pagePos.Y + row.AbsoluteSize.Y + 4
	local maxX = PlayersPage.AbsoluteSize.X - RankDropdown.AbsoluteSize.X - 8
	if relX > maxX then
		relX = maxX
	end
	local maxY = PlayersPage.AbsoluteSize.Y - RankDropdown.AbsoluteSize.Y - 24
	if relY > maxY then
		relY = maxY
	end
	RankDropdown.Position = UDim2.new(0, math.max(relX, 8), 0, math.max(relY, 8))
	RankDropdown.Visible = true
end

local MyRank = 0

local function BuildPlayers()
	PlayerScroll:ClearAllChildren()
	HideRankDropdown()
	local layout = New("UIListLayout", {
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, PlayerScroll)
	local players = Players:GetPlayers()
	table.sort(players, function(a, b)
		return a.Name < b.Name
	end)
	for i, p in ipairs(players) do
		local row = New("TextButton", {
			Size = UDim2.new(1, 0, 0, 36),
			BackgroundColor3 = GLASS_DEEP,
			BackgroundTransparency = 0.45,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = true,
			LayoutOrder = i,
		}, PlayerScroll)
		Glass(row, 8, false)
		local stroke = row:FindFirstChildOfClass("UIStroke")
		local isMe = p == Player
		GlassLabel(p.Name .. (isMe and "  (you)" or ""), 14,
			isMe and CYAN or TEXT, row, true)

		-- tap: select as command target
		row.MouseButton1Click:Connect(function()
			SelectedTarget = p
			TargetBox.Text = p.Name
			for _, other in ipairs(PlayerScroll:GetChildren()) do
				if other:IsA("TextButton") and other ~= row then
					local st = other:FindFirstChildOfClass("UIStroke")
					if st then
						st.Color = CYAN_DIM
						st.Transparency = 0.7
						st.Thickness = 2
					end
				end
			end
			stroke.Color = CYAN
			stroke.Transparency = 0.2
			stroke.Thickness = 3
			SetPlayerStatus("Target: " .. p.Name, false)
			-- owner/admin shortcut: show the rank dropdown
			if MyRank >= RANK.Mod then
				ShowRankDropdown(row, p, MyRank)
			end
		end)
	end
	PlayerScroll.CanvasSize = UDim2.new(0, 0, 0, #players * 42 + 8)
end

------------------------------------------------------------------
-- IMAGE LOGS page (the main feature)
------------------------------------------------------------------

local LogsPage = NewPage()

local LogSearch = New("TextBox", {
	Size = UDim2.new(0, 380, 0, 34),
	Position = UDim2.new(0, 0, 0, 0),
	BackgroundColor3 = GLASS_DEEP,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	PlaceholderText = "Search by username...",
	PlaceholderColor3 = MUTED,
	Text = "",
	TextColor3 = TEXT,
	Font = FONT,
	TextSize = 14,
	ClearTextOnFocus = false,
}, LogsPage)
Glass(LogSearch, 8, false)

local LogRefresh = New("TextButton", {
	Size = UDim2.new(0, 110, 0, 34),
	Position = UDim2.new(0, 392, 0, 0),
	BackgroundColor3 = GLASS_LIGHT,
	BackgroundTransparency = 0.3,
	BorderSizePixel = 0,
	Text = "",
	AutoButtonColor = true,
}, LogsPage)
Glass(LogRefresh, 8, true)
GlassLabel("REFRESH", 13, CYAN, LogRefresh, true).TextXAlignment = Enum.TextXAlignment.Center

local LogCount = GlassLabel("", 13, MUTED, LogsPage)
LogCount.Position = UDim2.new(0, 512, 0, 0)
LogCount.Size = UDim2.new(0, 190, 0, 34)

local LogScroll = New("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, -46),
	Position = UDim2.new(0, 0, 0, 44),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = CYAN_DIM,
	CanvasSize = UDim2.new(0, 0, 0, 0),
}, LogsPage)

local CurrentLogs = {}

local function TimeText(t)
	if not t or t == 0 then
		return "?"
	end
	return os.date("%b %d  %H:%M", t)
end

local function MakeLogRow(entry, layoutOrder)
	local row = New("Frame", {
		Size = UDim2.new(1, 0, 0, 72),
		BackgroundColor3 = GLASS_DEEP,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder,
	}, LogScroll)
	Glass(row, 10, false)

	local thumb = New("ImageLabel", {
		Size = UDim2.new(0, 56, 0, 56),
		Position = UDim2.new(0, 8, 0, 8),
		BackgroundColor3 = GLASS,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Image = tostring(entry.img or ""),
		ScaleType = Enum.ScaleType.Fit,
	}, row)
	New("UICorner", { CornerRadius = UDim.new(0, 6) }, thumb)

	local idLbl = GlassLabel("ID: " .. tostring(entry.id or "?"), 13, CYAN, row)
	idLbl.Position = UDim2.new(0, 74, 0, 8)
	idLbl.Size = UDim2.new(0, 220, 0, 18)

	local userLbl = GlassLabel("by " .. tostring(entry.n or "?"), 14, TEXT, row, true)
	userLbl.Position = UDim2.new(0, 74, 0, 26)
	userLbl.Size = UDim2.new(0, 200, 0, 20)

	local boothLbl = GlassLabel("booth: " .. tostring(entry.b or "?"), 12, MUTED, row)
	boothLbl.Position = UDim2.new(0, 74, 0, 46)
	boothLbl.Size = UDim2.new(0, 240, 0, 18)

	local timeLbl = GlassLabel(TimeText(entry.t), 12, MUTED, row)
	timeLbl.Position = UDim2.new(1, -110, 0, 26)
	timeLbl.Size = UDim2.new(0, 100, 0, 18)
	timeLbl.TextXAlignment = Enum.TextXAlignment.Right

	-- tap the row to copy the id
	row.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			pcall(function()
				game:GetService("Clipboard"):Set(tostring(entry.id or ""))
			end)
			SetStatus("Copied ID " .. tostring(entry.id), false)
		end
	end)

	return row
end

local function RebuildLogs(list)
	CurrentLogs = list or {}
	LogScroll:ClearAllChildren()
	New("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, LogScroll)
	if #CurrentLogs == 0 then
		GlassLabel("No image uploads logged yet.", 14, MUTED, LogScroll)
		LogCount.Text = "0 entries"
		return
	end
	for i, entry in ipairs(CurrentLogs) do
		MakeLogRow(entry, i)
	end
	LogCount.Text = tostring(#CurrentLogs) .. " entr" ..
		(#CurrentLogs == 1 and "y" or "ies")
	LogScroll.CanvasSize = UDim2.new(0, 0, 0, #CurrentLogs * 80 + 8)
end

local function FetchLogs()
	local folder = ReplicatedStorage:FindFirstChild("AdminPanel")
	local fn = folder and folder:FindFirstChild("GetImageLogs")
	if not fn or not fn:IsA("RemoteFunction") then
		LogCount.Text = "panel server missing"
		return
	end
	local ok, res = pcall(function()
		return fn:InvokeServer(LogSearch.Text)
	end)
	if ok and type(res) == "table" then
		RebuildLogs(res)
	end
end

LogRefresh.MouseButton1Click:Connect(FetchLogs)
LogSearch.FocusLost:Connect(function(enter)
	if enter then
		FetchLogs()
	end
end)

local function WatchLogs()
	local folder = ReplicatedStorage:FindFirstChild("AdminPanel")
	local ev = folder and folder:FindFirstChild("ImageLogBroadcast")
	if not ev or not ev:IsA("RemoteEvent") then
		return
	end
	ev.OnClientEvent:Connect(function(entry)
		local needle = LogSearch.Text:lower()
		if needle ~= "" and tostring(entry.n or ""):lower():find(needle, 1, true) == nil then
			return -- doesn't match the active search
		end
		local filtered = {}
		for _, e in ipairs(CurrentLogs) do
			if needle == "" or tostring(e.n or ""):lower():find(needle, 1, true) then
				filtered[#filtered + 1] = e
			end
		end
		table.insert(filtered, 1, entry)
		RebuildLogs(filtered)
	end)
end

------------------------------------------------------------------
-- Tab switching
------------------------------------------------------------------

local function ShowPage(name)
	HideRankDropdown()
	local index = 1
	if name == "PLAYERS" then
		index = 2
	elseif name == "IMAGE LOGS" then
		index = 3
	end
	for i, page in ipairs(Pages) do
		page.Visible = (i == index)
	end
	for tabName, tab in pairs(TabButtons) do
		tab.Lbl.TextColor3 = (tabName == name) and CYAN or MUTED
	end
	if name == "PLAYERS" then
		BuildPlayers()
	elseif name == "IMAGE LOGS" then
		FetchLogs()
	end
end

TabButtons["COMMANDS"].Btn.MouseButton1Click:Connect(function()
	ShowPage("COMMANDS")
end)
TabButtons["PLAYERS"].Btn.MouseButton1Click:Connect(function()
	ShowPage("PLAYERS")
end)
TabButtons["IMAGE LOGS"].Btn.MouseButton1Click:Connect(function()
	ShowPage("IMAGE LOGS")
end)

------------------------------------------------------------------
-- Design transparency capture (fixes open-after-close staying
-- invisible: we remember each element's intended look once, and always
-- fade back to that on open).
------------------------------------------------------------------

local DesignTransparency = {} -- [obj] = { BackgroundTransparency=?, TextTransparency=?, ImageTransparency=? }

local function CaptureDesign()
	DesignTransparency = {}
	for _, desc in ipairs(Panel:GetDescendants()) do
		if desc:IsA("GuiObject") then
			local t = {}
			if desc:IsA("Frame") or desc:IsA("TextButton")
				or desc:IsA("TextBox") or desc:IsA("ImageLabel")
				or desc:IsA("ImageButton") or desc:IsA("ScrollingFrame") then
				t.BackgroundTransparency = desc.BackgroundTransparency
			end
			if desc:IsA("TextLabel") or desc:IsA("TextButton")
				or desc:IsA("TextBox") then
				t.TextTransparency = desc.TextTransparency
			end
			if desc:IsA("ImageLabel") or desc:IsA("ImageButton") then
				t.ImageTransparency = desc.ImageTransparency
			end
			DesignTransparency[desc] = t
		end
	end
end

------------------------------------------------------------------
-- Mobile scaling
------------------------------------------------------------------

local function FitPanel()
	local screen = Screen.AbsoluteSize
	if screen.X <= 0 or screen.Y <= 0 then
		return
	end
	local fit = math.min((screen.X - 24) / 720, (screen.Y - 24) / 470, 1)
	PanelScale.Scale = math.max(fit, 0.42)
end

Screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(FitPanel)

------------------------------------------------------------------
-- Open / close animations + camera
------------------------------------------------------------------

local Open = false
local SavedCameraCFrame = nil
local SavedCameraType = nil

local function FaceCharacter()
	local char = Player.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart")
		or char:FindFirstChild("Torso")
	if not root then
		return
	end

	local forward = root.CFrame.LookVector
	forward = Vector3.new(forward.X, 0, forward.Z)
	if forward.Magnitude < 0.05 then
		forward = Vector3.new(1, 0, 0)
	end
	forward = forward.Unit

	local cam = workspace.CurrentCamera
	local camPos = root.Position + forward * 9 + Vector3.new(0, 3.4, 0)
	local lookAt = root.Position + Vector3.new(0, 2.6, 0)
	local goal = CFrame.lookAt(camPos, lookAt)

	cam.CameraType = Enum.CameraType.Scriptable
	local tw = TweenService:Create(cam, TweenInfo.new(0.65,
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = goal,
	})
	tw:Play()
end

local function FadePanel(on, done)
	if on then
		Panel.Visible = true
		PanelScale.Scale = 0.94
		local elems = {}
		for _, desc in ipairs(Panel:GetDescendants()) do
			if desc:IsA("GuiObject") then
				local design = DesignTransparency[desc]
				if design then
					table.insert(elems, { Obj = desc, Design = design })
				end
			end
		end
		for i, e in ipairs(elems) do
			local changes = {}
			for prop, toVal in pairs(e.Design) do
				e.Obj[prop] = 1
				changes[prop] = toVal
			end
			local delay = (i - 1) * 0.012
			local tw = TweenService:Create(e.Obj,
				TweenInfo.new(0.35, Enum.EasingStyle.Quad,
					Enum.EasingDirection.Out, delay), changes)
			tw:Play()
		end
		local scaleTw = TweenService:Create(PanelScale,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 1,
		})
		scaleTw:Play()
		-- shine sweep
		Shine.Position = UDim2.new(-0.3, 0, 0, 0)
		local shineTw = TweenService:Create(Shine,
			TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(1.1, 0, 0, 0),
		})
		shineTw:Play()
		if done then
			done()
		end
	else
		local elems = {}
		for _, desc in ipairs(Panel:GetDescendants()) do
			if desc:IsA("GuiObject") and DesignTransparency[desc] then
				table.insert(elems, desc)
			end
		end
		local cam = workspace.CurrentCamera
		local restore = SavedCameraCFrame and cam.CFrame or nil
		for i, obj in ipairs(elems) do
			local changes = {}
			local design = DesignTransparency[obj]
			for prop in pairs(design) do
				changes[prop] = 1
			end
			local tw = TweenService:Create(obj,
				TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), changes)
			tw:Play()
		end
		wait(0.18)
		Panel.Visible = false
		if restore then
			local tw = TweenService:Create(cam,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				CFrame = restore,
			})
			tw:Play()
			wait(0.5)
		end
		if SavedCameraType then
			workspace.CurrentCamera.CameraType = SavedCameraType
		end
		SavedCameraCFrame = nil
		SavedCameraType = nil
		if done then
			done()
		end
	end
end

local function OpenPanel()
	if Open then
		return
	end
	Open = true
	local cam = workspace.CurrentCamera
	SavedCameraCFrame = cam.CFrame
	SavedCameraType = cam.CameraType
	FaceCharacter()
	ShowPage("COMMANDS")
	FadePanel(true)
end

local function ClosePanel()
	if not Open then
		return
	end
	Open = false
	FadePanel(false)
end

CloseBtn.MouseButton1Click:Connect(ClosePanel)

-- if the character respawns while open, re-face the camera at them
Player.CharacterAdded:Connect(function()
	if Open then
		wait(1)
		if Open then
			FaceCharacter()
		end
	end
end)

------------------------------------------------------------------
-- Open button (floating glass pill)
------------------------------------------------------------------

local OpenButton = New("TextButton", {
	Name = "OpenAdmin",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -14, 0, 60),
	Size = UDim2.new(0, 120, 0, 40),
	BackgroundColor3 = GLASS_DEEP,
	BackgroundTransparency = 0.3,
	BorderSizePixel = 0,
	Text = "",
	AutoButtonColor = true,
	Visible = false,
	ZIndex = 20,
}, Screen)
Glass(OpenButton, 10, true)
GlassLabel("◈ ADMIN", 15, CYAN, OpenButton, true).TextXAlignment = Enum.TextXAlignment.Center
OpenButton.MouseButton1Click:Connect(function()
	if Open then
		ClosePanel()
	else
		OpenPanel()
	end
end)

-- hide the old panel's button (defensive)
local function HideOldButton()
	pcall(function()
		local main = PlayerGui:FindFirstChild("MainUI")
		if main then
			local old = main:FindFirstChild("AdminButton")
			if old then
				old.Visible = false
			end
		end
	end)
end

------------------------------------------------------------------
-- Auth: use the game's own admin plumbing
------------------------------------------------------------------

local IsAdmin = false

BoothRemote.OnClientEvent:Connect(function(argument, argument2, argument3, argument4)
	if argument == "AdminAccess" then
		IsAdmin = (argument2 == true)
		MyRank = tonumber(argument3) or 0
		OpenButton.Visible = IsAdmin
		if IsAdmin then
			HideOldButton()
		end
	elseif argument == "AdminCommands" then
		if type(argument2) == "table" then
			BuildCommands(argument2)
		end
	elseif argument == "AdminOk" then
		if Open and Pages[2].Visible then
			SetPlayerStatus(tostring(argument2 or "ok"), false)
		else
			SetStatus(tostring(argument2 or "ok"), false)
		end
	elseif argument == "AdminError" then
		if Open and Pages[2].Visible then
			SetPlayerStatus(tostring(argument2 or "error"), true)
		else
			SetStatus(tostring(argument2 or "error"), true)
		end
	end
end)

spawn(function()
	wait(1)
	-- ask the server who we are (also triggers AdminCommands for admins)
	pcall(function()
		BoothRemote:FireServer("AdminOpen")
	end)
	-- Safety net: if the server never answered, fall back to showing the
	-- open button for the game owner so the panel is never unreachable.
	wait(4)
	if not IsAdmin and Player.UserId == 49603 then
		IsAdmin = true
		OpenButton.Visible = true
		HideOldButton()
	end
	WatchLogs()
end)

-- keep the player list + command grid fresh
spawn(function()
	while true do
		wait(20)
		if Open and Pages[2].Visible then
			BuildPlayers()
		end
	end
end)

-- capture design transparencies once everything is built (before any open)
FitPanel()
CaptureDesign()
