-- Entity Screen Effect 

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local MarketplaceService = game:GetService("MarketplaceService")
local tag = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

--SETTINGS--
local MAX_DISTANCE = 40 -- The effects will start to apply from the lowest intensity for the players with in this studs.
local MIN_DISTANCE = 5 -- The effects will stay same (the highest intensity) for the players with in this studs.
local ApplyBlur = true -- make false to disable
local ScreenEffectColor = Color3.new(1, 0, 0)

local ScreenGui
local RedFrame
local Blur
local HumanoidRootPart
local Humanoid



local function createEffects()
	ScreenGui = Instance.new("ScreenGui")
	ScreenGui.ResetOnSpawn = false
	ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	ScreenGui.IgnoreGuiInset = true

	RedFrame = Instance.new("Frame")
	RedFrame.Size = UDim2.new(1,0,1,0)
	RedFrame.BackgroundColor3 = ScreenEffectColor
	RedFrame.BackgroundTransparency = 1
	RedFrame.ZIndex = 10
	RedFrame.Parent = ScreenGui

	Blur = Instance.new("BlurEffect")
	Blur.Size = 0
	Blur.Parent = Workspace.CurrentCamera
end

local function removeEffects()
	if ScreenGui then
		ScreenGui:Destroy()
	end
	if Blur then
		Blur:Destroy()
	end
	ScreenGui = nil
	RedFrame = nil
	Blur = nil
end

local function onCharacterAdded(char)
	HumanoidRootPart = char:WaitForChild("HumanoidRootPart")
	Humanoid = char:WaitForChild("Humanoid")
	createEffects()

	Humanoid.Died:Connect(function()
		removeEffects()
	end)
end

LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
if LocalPlayer.Character then
	onCharacterAdded(LocalPlayer.Character)
end

local function calculateIntensity(distance)
	if distance > MAX_DISTANCE then return 0 end
	if distance <= MIN_DISTANCE then return 1 end
	return 1 - ((distance - MIN_DISTANCE) / (MAX_DISTANCE - MIN_DISTANCE))
end

RunService.Heartbeat:Connect(function()
	if not HumanoidRootPart then return end

	local closest = MAX_DISTANCE + 1
	for _, m in pairs(Workspace:GetChildren()) do
		if m:IsA("Model") and tag:HasTag(m,"Entity")  then
			local hrp = m:FindFirstChild("HumanoidRootPart")
			if hrp then
				local d = (HumanoidRootPart.Position - hrp.Position).Magnitude
				if d < closest then closest = d end
			end
		end
	end

	if RedFrame and Blur then
		local intensity = calculateIntensity(closest)
		RedFrame.BackgroundTransparency = 1 - (intensity*0.45)
		if ApplyBlur == true then
			Blur.Size = intensity * 5
		end
	end
	

	
end)
