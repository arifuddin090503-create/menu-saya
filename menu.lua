if _G.kunci_saya ~= "KEY-BELAJAR-123" then
	warn("Key salah!")
	return
end

local player = game.Players.LocalPlayer
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Stats = game:GetService("Stats")

local gui = Instance.new("ScreenGui")
gui.Name = "MenuSaya"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 40)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0, 20, 0.3, 0)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local layout = Instance.new("UIListLayout", frame)
layout.Padding = UDim.new(0, 6)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
local pad = Instance.new("UIPadding", frame)
pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)

local judul = Instance.new("TextButton")
judul.Size = UDim2.new(1, -16, 0, 28)
judul.Text = "Menu Saya   [X]"
judul.TextColor3 = Color3.new(1, 1, 1)
judul.Font = Enum.Font.GothamBold
judul.TextSize = 16
judul.BackgroundTransparency = 1
judul.LayoutOrder = 0
judul.Parent = frame
judul.MouseButton1Click:Connect(function() gui:Destroy() end)

local function buatToggle(nama, urutan, saatBerubah)
	local aktif = false
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -16, 0, 32)
	btn.LayoutOrder = urutan
	btn.Font = Enum.Font.Gotham
	btn.TextSize = 14
	btn.TextColor3 = Color3.new(1, 1, 1)
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	btn.Parent = frame

	local function refresh()
		btn.Text = nama .. ": " .. (aktif and "ON" or "OFF")
		btn.BackgroundColor3 = aktif and Color3.fromRGB(40, 150, 80) or Color3.fromRGB(60, 60, 70)
	end
	refresh()

	btn.MouseButton1Click:Connect(function()
		aktif = not aktif
		refresh()
		saatBerubah(aktif)
	end)
end

-- Fitur 1: tampilan FPS dan ping
local infoLabel = Instance.new("TextLabel")
infoLabel.Size = UDim2.new(1, -16, 0, 24)
infoLabel.LayoutOrder = 2
infoLabel.BackgroundTransparency = 1
infoLabel.Font = Enum.Font.Code
infoLabel.TextSize = 14
infoLabel.TextColor3 = Color3.fromRGB(200, 255, 200)
infoLabel.Text = "FPS: -  |  Ping: - ms"
infoLabel.Visible = false
infoLabel.Parent = frame

local koneksiFps
local function ambilPing()
	local ok, nilai = pcall(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	return ok and math.floor(nilai) or 0
end

buatToggle("FPS & Ping", 1, function(on)
	infoLabel.Visible = on
	if koneksiFps then
		koneksiFps:Disconnect()
		koneksiFps = nil
	end
	if not on then return end

	local frames = 0
	local mulai = os.clock()
	koneksiFps = RunService.RenderStepped:Connect(function()
		frames += 1
		local sekarang = os.clock()
		if sekarang - mulai >= 0.5 then
			local fps = math.floor(frames / (sekarang - mulai))
			infoLabel.Text = ("FPS: %d  |  Ping: %d ms"):format(fps, ambilPing())
			frames = 0
			mulai = sekarang
		end
	end)
end)

-- Fitur 2: sembunyikan atau tampilkan menu dengan RightShift
local petunjuk = Instance.new("TextLabel")
petunjuk.Size = UDim2.new(1, -16, 0, 20)
petunjuk.LayoutOrder = 3
petunjuk.BackgroundTransparency = 1
petunjuk.Font = Enum.Font.Gotham
petunjuk.TextSize = 12
petunjuk.TextColor3 = Color3.fromRGB(150, 150, 160)
petunjuk.Text = "RightShift: sembunyikan/tampilkan"
petunjuk.Parent = frame

local koneksiKey = UserInputService.InputBegan:Connect(function(input, diproses)
	if diproses then return end
	if input.KeyCode == Enum.KeyCode.RightShift then
		frame.Visible = not frame.Visible
	end
end)

-- bersihkan saat menu ditutup
gui.Destroying:Connect(function()
	if koneksiFps then koneksiFps:Disconnect() end
	koneksiKey:Disconnect()
end)
