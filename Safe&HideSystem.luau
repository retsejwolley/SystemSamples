--Safe & Hide System

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")


---SETTINGS--
local TagDelay = 0.5 -- This determines the delay time between tagging a character as "Safe" or "Hide", you can think it like cooldown.

local function isInsideZone(character: Model, zone: BasePart)
	for _, part in ipairs(Workspace:GetPartsInPart(zone)) do
		if part:IsDescendantOf(character) then
			return true
		end
	end
	return false
end

local function setTag(character: Model, tag: string, value: boolean)
	if value then
		if not CollectionService:HasTag(character, tag) then
			CollectionService:AddTag(character, tag)
		end
	else
		if CollectionService:HasTag(character, tag) then
			CollectionService:RemoveTag(character, tag)
		end
	end
end

local function monitorCharacter(player: Player, character: Model)
	while character.Parent and player.Parent do
		local inSafe, inHide = false, false

		for _, zone in ipairs(CollectionService:GetTagged("SafeZone")) do
			if zone:IsA("BasePart") and isInsideZone(character, zone) then
				inSafe = true
				break
			end
		end

		for _, zone in ipairs(CollectionService:GetTagged("HideZone")) do
			if zone:IsA("BasePart") and isInsideZone(character, zone) then
				inHide = true
				break
			end
		end

		setTag(character, "Safe", inSafe)
		setTag(character, "Hide", inHide)

		task.wait(TagDelay)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.defer(monitorCharacter, player, character)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
