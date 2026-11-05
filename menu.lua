if _G.kunci_saya ~= "KEY-BELAJAR-123" then
	warn("Key salah!")
	return
end

local player = game.Players.LocalPlayer

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

-- Fitur 1: jalan bolak-balik
local jalanAktif = false

buatToggle("Jalan Bolak-balik", 1, function(on)
	jalanAktif = on
	if not on then return end

	local RunService = game:GetService("RunService")
local koneksi

if not on then
    if koneksi then koneksi:Disconnect() koneksi = nil end
    return
end

local arah = -1 -- -1 = maju, 1 = mundur
local gantiAt = os.clock() + 2

koneksi = RunService.RenderStepped:Connect(function()
    if not jalanAktif then
        koneksi:Disconnect()
        koneksi = nil
        local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum:Move(Vector3.zero) end
        return
    end
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    if os.clock() >= gantiAt then
        arah = -arah
        gantiAt = os.clock() + 2
    end
    hum:Move(Vector3.new(0, 0, arah), true)
end)
