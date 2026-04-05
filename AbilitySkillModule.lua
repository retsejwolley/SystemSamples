local KingCrimson = {}
KingCrimson.__index = KingCrimson

--[[
This is the start of the skill module of the ability: King Crimson.

The ability I scripted comes from an anime called Jojo's Bizarre Adventure where "stands" take place usually back to the user, such as a shadow. 

I explained most of the functions and topics, I hope I have explained it well. Focus is placed on explaining the logic, performance decisions, and component interactions across the server and client.
]]--

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
--[[
Here I assign services that I will use multiple times later in the code. I define these dependencies at the top to cache them. Caching services is a good performance decision because calling game:GetService() repeatedly inside functions can slow down the script unnecessarily. It also keeps the dependencies organized.
]]--

-- Dependencies
local Modules = ReplicatedStorage:WaitForChild("Modules")
local DamageHandler = require(ServerScriptService:WaitForChild("DamageHandler"))
local BezierPunch = require(ServerStorage.BezierPunch)
local RagdollHandler = require(Modules:WaitForChild("RagdollHandler"))
local HitboxHandler = require(ServerScriptService:WaitForChild("HitboxHandler"))
local VFXHandler = require(Modules:WaitForChild("VFXHandler"))
local SFXHandler = require(Modules:WaitForChild("SFXHandler"))
local MovementHandler = require(Modules:WaitForChild("MovementHandler"))



local AbilityModels = ServerStorage:WaitForChild("AbilityModels")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local InfoFolder = ReplicatedStorage:WaitForChild("AbilityModules")
--[[
Here I call some other system modules and assign remote variables. Centralizing these module requires ensures that KingCrimson can communicate effectively with global systems like Hitboxes and VFX without circular dependencies.
]]--


-- Constants
local STAND_NAME = "KingCrimson"
local AbilityInfo = require(InfoFolder:WaitForChild(STAND_NAME))
local MOVES = AbilityInfo.GetMoves()
local ASSETS = AbilityInfo.GetAssets()

--[[
These variables are constant for this ability. By pulling the data from a central AbilityInfo module, I keep the configuration (like damage numbers and asset IDs) separate from the logic. This decision makes the ability much easier to balance and tweak later.
]]--


-- Constructor: Modified to accept an Entity (Player or NPC Model)
function KingCrimson.new(entity)
	local self = setmetatable({}, KingCrimson)

	if entity:IsA("Player") then
		self.Player = entity
		self.Character = entity.Character
	elseif entity:IsA("Model") then
		self.Player = nil
		self.Character = entity
	else
		warn("KingCrimson.new requires a Player or Model (NPC)")
		return nil
	end

	-- Instance specific state management prevents global variable conflicts
	self.State = {
		IsBarraging = false,
		BarrageAnim = nil,
		BarrageSound = nil,
		TimeEraseActive = false,
		AlreadyAttackPos = false,
		StayForwardTask = nil,
		OldTransparencyTable = nil
	}

	return self
end

--[[
Here is the most crucial part of my code. Metatables allow me to store unique variables separately for each player who uses this ability. By returning 'self', I create an Object oriented structure. 

The self.State table is a very important technical decision because it holds the active data for that specific player. This instance specific state management prevents global variable conflicts, ensuring that if Player A triggers an attack, it doesn't accidentally overwrite or cancel Player B's attack data.
]]--

-- Helper Methods
function KingCrimson:GetStand()
	if not self.Character then return nil end
	-- Changed from self.Player.Name to self.Character.Name to support NPCs
	return self.Character:FindFirstChild(self.Character.Name .. "_Stand")
end

function KingCrimson:CreateBulletTracer(startPos, endPos)
	local distance = (endPos - startPos).Magnitude
	local tracer = Instance.new("Part")

	tracer.Name = "BulletTracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CastShadow = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 255, 100)
	tracer.Size = Vector3.new(0.25, 0.25, distance)
	tracer.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -distance / 2)
	tracer.Parent = workspace

	local fadeInfo = TweenInfo.new(0.25, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
	TweenService:Create(tracer, fadeInfo, {Transparency = 1}):Play()
	Debris:AddItem(tracer, 0.25)
end

--[[
This is the bullet tracer function that creates a beam between the final and starter points for a certain duration. 

How it works mathematically: I calculate the Magnitude (distance) between the two vectors to determine how long the part needs to be. Then, I use CFrame.lookAt to point the tracer directly at the endPos, and multiply it by a CFrame offset of half the distance (-distance / 2) to center the beam perfectly between the two points. Finally, I use TweenService for a smooth visual fade and Debris service to garbage-collect the part, preventing memory leaks in the workspace.
]]--


function KingCrimson:PlayAnim(targetModel, animId, speed)
	if not animId or not targetModel then return nil end

	local humanoid = targetModel:FindFirstChild("Humanoid")
	local animator = humanoid and humanoid:FindFirstChild("Animator") or Instance.new("Animator", humanoid)
	local animation = Instance.new("Animation")
	animation.AnimationId = animId

	local track = animator:LoadAnimation(animation)
	track:Play(0.1, 10, speed or 1)

	return track
end

--[[
This is the anim player function that loads the target animationId to the target character's animator and plays it with a designated playback speed. It includes fallback logic to create an Animator instance if one does not already exist on the Humanoid, ensuring the animation plays safely without throwing errors.
]]--


function KingCrimson:AttackPosition(forwardAmount, duration)
	local stand = self:GetStand()
	if not stand then return end

	local standHrp = stand:WaitForChild("HumanoidRootPart")
	local motor = standHrp:FindFirstChild("StandConnector")
	if not motor then return end

	-- Cancel the previous reset task if the player attacks consecutively
	if self.State.AlreadyAttackPos and self.State.StayForwardTask then
		task.cancel(self.State.StayForwardTask)
		self.State.StayForwardTask = nil
	end

	local attackGoal = {C0 = CFrame.new(0, 0, -forwardAmount)}
	local attackInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(motor, attackInfo, attackGoal):Play()
	self.State.AlreadyAttackPos = true

	self.State.StayForwardTask = task.delay(duration, function()
		if motor and motor.Parent then
			local resetGoal = {C0 = CFrame.new(2, 1, 2)}
			local resetInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(motor, resetInfo, resetGoal):Play()
			self.State.AlreadyAttackPos = false
		end
	end)

	task.wait(0.2)
end

--[[
Attack position makes the ability take place in front of the user before attacking. 

This function tweens the ability rig position to the front of the player by "forwardAmount" (studs) throughout the "duration" (number). 

The reason why I use Motor6D instead of classic welds is because Motor6D makes the rig animations work correctly instead of just freezing it. Alongside this, Motor6D provides more flexible movement and tweening by manipulating the C0 property. 

To handle rapid consecutive attacks safely, I added logic using 'self.State.AlreadyAttackPos' and 'task.cancel(self.State.StayForwardTask)'. This decision ensures that if a player attacks again before the previous reset finishes, the tweens won't overlap and glitch the stand's position.
]]--


--[[
Helper methods are usually part of multiple abilities, that's why I created simple, modular functions of these codes in order to avoid repeating myself (DRY principle).
]]--


-- Core Abilities
function KingCrimson:Summon()
	local existingStand = self:GetStand()

	-- [[ DESPAWN LOGIC ]] --
	if existingStand then
		local hrp = existingStand:FindFirstChild("HumanoidRootPart")
		local motor = hrp and hrp:FindFirstChild("StandConnector")

		if motor then
			TweenService:Create(motor, TweenInfo.new(0.3, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {C0 = CFrame.new(0,0,0)}):Play()

			for _, v in pairs(existingStand:GetDescendants()) do 
				if v:IsA("BasePart") then
					TweenService:Create(v, TweenInfo.new(0.3, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Transparency = 1}):Play()
					-- Safely disable particle emitters for a smooth fade out
				elseif v:IsA("ParticleEmitter") then
					v.Enabled = false
				end
			end
		end

		-- Disable aura if applicable
		VFXHandler.PlayVFX(self.Character, "KC_CharacterAura", nil, 2, false)

		task.delay(0.3, function() 
			if existingStand then existingStand:Destroy() end 
		end)
		return
	end

	-- [[ SPAWN LOGIC ]] --
	if not self.Character then return end
	local hrp = self.Character:WaitForChild("HumanoidRootPart")
	local standModel = AbilityModels:FindFirstChild(STAND_NAME)

	if not standModel then return end

	local standClone = standModel:Clone()
	standClone.Name = self.Character.Name .. "_Stand"
	standClone.Parent = self.Character

	local standHrp = standClone:WaitForChild("HumanoidRootPart")
	for _, v in pairs(standClone:GetDescendants()) do 
		if v:IsA("BasePart") then 
			v.CanCollide = false 
			v.Massless = true 
		end 
	end

	local motor = Instance.new("Motor6D")
	motor.Name = "StandConnector"
	motor.Part0 = hrp
	motor.Part1 = standHrp
	motor.Parent = standHrp
	motor.C0 = CFrame.new(0,0,0)

	SFXHandler.PlaySound(standHrp, ASSETS.Sounds.Summon)
	VFXHandler.PlayVFX(standClone, "#4_Summon", "HumanoidRootPart", 2)

	-- Example Aura Activation (If you have KC auras, enable them here like WhiteSnake)
	local TargetParts = {"Head","Right Arm","Left Arm","Right Leg","Left Leg"}
	VFXHandler.PlayVFX(self.Character, "KC_CharacterAura", TargetParts, 2, true)
	VFXHandler.PlayVFX(standClone, "KC_StandAura", TargetParts, 2, true)

	TweenService:Create(motor, TweenInfo.new(0.5, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {C0 = CFrame.new(2,1,2)}):Play()

	if standClone.Parent then 
		self:PlayAnim(standClone, ASSETS.Animations.Idle) 
	end
end

--[[
In this Summon ability, whenever a player triggers the designated key it gets fired, checks for the ability model, clones it, and tweens it to the correct place.

The logic handles both spawning and despawning to prevent duplicate instances. If 'existingStand' is found, it triggers a despawn sequence: tweening the transparency of all BaseParts and smoothly moving the Motor6D before safely calling :Destroy() to free memory. 

When spawning, a crucial physics decision was made in the for-loop: setting CanCollide to false and Massless to true for all BaseParts. This guarantees the Stand model will not disrupt the player's core movement physics or cause unnatural weight drag.
]]--



function KingCrimson:BarrageStart()
	local stand = self:GetStand()
	if not stand or self.State.IsBarraging then return end

	local data = MOVES.Barrage
	-- Used self.Character instead of self.Player
	self.Character:SetAttribute("IsHolding_Barrage", true)
	self.State.IsBarraging = true

	self.State.BarrageSound = SFXHandler.PlaySound(stand.HumanoidRootPart, ASSETS.Sounds.Barrage[1], false, 0, ASSETS.Sounds.Barrage[2])
	self.State.BarrageAnim = self:PlayAnim(stand, ASSETS.Animations.Barrage)

	BezierPunch.Start(stand, data.HitDuration)
	self:AttackPosition(data.SelfForward, data.SelfDuration)
	HitboxHandler.Run(self.Character, stand, data)
end

function KingCrimson:BarrageStop()
	if not self.State.IsBarraging then return end

	-- Used self.Character instead of self.Player
	self.Character:SetAttribute("IsHolding_Barrage", nil)
	self.State.IsBarraging = false

	if self.State.BarrageAnim then self.State.BarrageAnim:Stop(0.2) end
	if self.State.BarrageSound then 
		self.State.BarrageSound:Stop()
		self.State.BarrageSound:Destroy() 
	end

	local stand = self:GetStand()
	if stand then
		BezierPunch.Stop(stand)
		local motor = stand.HumanoidRootPart:FindFirstChild("StandConnector")
		if motor then
			TweenService:Create(motor, TweenInfo.new(0.4, Enum.EasingStyle.Quad), {C0 = CFrame.new(2, 1, 2)}):Play()
		end
	end
end


--[[
Barrage is an iconic skill for this type of ability. It basically spawns multiple hitboxes alongside a bezier curve module that creates extra arms in order to feel like the character punches really fast.

How this function works is, since this ability is holdable, it's divided into two functions. The start script sets up the hitboxes, arms, animations, and sound. The stop function handles the cleanup process.

The logic relies heavily on state management ('self.State.IsBarraging') to ensure the player cannot trigger the start function multiple times, which would create overlapping sounds or broken hitboxes. In BarrageStop, destroying the sound object and calling BezierPunch.Stop ensures no memory leaks or visual bugs remain after the button is released.
]]--


function KingCrimson:Heavy()
	local stand = self:GetStand()
	if not stand then return end

	local data = MOVES.Heavy
	SFXHandler.PlaySound(stand.HumanoidRootPart, ASSETS.Sounds.Heavy)

	self:PlayAnim(stand, ASSETS.Animations.Heavy, 2.25)
	self:AttackPosition(data.SelfForward, data.SelfDuration)

	task.delay(0.35, function()
		HitboxHandler.Run(self.Character, stand, data)
	end)
end

--[[
This is the heavy punch ability. It plays an animation and sound right before punching through the enemy. I use task.delay(0.35) to sync the creation of the hitbox with the exact keyframe of the animation where the fist swings forward, making the combat feel highly responsive.
]]--


function KingCrimson:Punch()
	local stand = self:GetStand()
	if not stand then return end

	local data = MOVES.Punch
	self:PlayAnim(stand, ASSETS.Animations.M1, 2)
	self:AttackPosition(data.SelfForward, data.SelfDuration)

	HitboxHandler.Run(self.Character, stand, data)
end

--[[
This is a similar version of the heavy punch ability, but with lower damage defined in its "data".

How data works is there is basically an information table located in the module that includes various variables. This data table is passed into the HitboxHandler server module, meaning the hitboxes dynamically scale based on the provided configuration without needing separate hitbox logic for every single attack.
]]--


function KingCrimson:Chop()
	local stand = self:GetStand()
	if not stand then return end 

	local data = table.clone(MOVES.Chop)
	local speed = 1

	-- Apply buffs if Time Erase is currently active
	if self.State.TimeEraseActive then
		speed = 2
		data.DPSTotal = 50
		data.Ragdoll = true
		BezierPunch.Start(stand, 0.75)
	end

	SFXHandler.PlaySound(stand.HumanoidRootPart, ASSETS.Sounds.Chop)
	self:PlayAnim(stand, ASSETS.Animations.Chop, speed)
	self:AttackPosition(data.SelfForward, data.SelfDuration)

	task.delay(0.3 / speed, function()
		HitboxHandler.Run(self.Character, stand, data)
	end)
end

--[[
A similar version of the previous two skills, but it connects with the DamagePerSecond system in its data in order to create a bleeding effect on the enemy.

I included a logical branch here: if 'self.State.TimeEraseActive' is true, the chop is buffed. Because tables in Lua pass by reference, I use table.clone(MOVES.Chop) so I can safely modify 'data.DPSTotal' and 'data.Ragdoll' without permanently altering the base move stats. The task.delay is also dynamically divided by the 'speed' multiplier so the hitbox always matches the faster animation timing.
]]--


-- Time Erase And Counter

--[[
Both of the skills below are explained at the end of the code.
]]--


function KingCrimson:ReverseErase()
	if not self.State.TimeEraseActive then return end

	-- FireClient is wrapped safely in case an NPC used this move
	if self.Player then
		Remotes.ScreenAction:FireClient(self.Player, "TimeErase")
	end

	if self.Character then
		local hum = self.Character:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = 16 end

		local hrp = self.Character:FindFirstChild("HumanoidRootPart")
		if hrp then SFXHandler.PlaySound(hrp, ASSETS.Sounds.TimeEraseStop) end

		self.Character:SetAttribute("Safe", nil)
		self.Character:SetAttribute("TimeErase", nil)

		-- Restore visibility dynamically to prevent memory leaks
		if self.State.OldTransparencyTable then
			for _, info in pairs(self.State.OldTransparencyTable) do
				if info.Part then info.Part.Transparency = info.OldTrans end
			end
		end

		self.State.OldTransparencyTable = nil
	end

	task.wait(1)
	self.State.TimeEraseActive = false
end

function KingCrimson:TimeEraseStart()
	local stand = self:GetStand()
	if not self.Character or not stand then return end

	local hum = self.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
	end

	local data = MOVES.TimeErase
	self.Character:SetAttribute("Safe", true)
	self.Character:SetAttribute("TimeErase", true)
	self.State.TimeEraseActive = true

	local anim = self:PlayAnim(stand, ASSETS.Animations.TimeEraseStand)
	self:PlayAnim(self.Character, ASSETS.Animations.TimeErasePlayer)
	self:AttackPosition(data.SelfForward, data.SelfDuration)	

	SFXHandler.PlaySound(stand.HumanoidRootPart, ASSETS.Sounds.TimeErase, false, 0, 1.5)

	anim.KeyframeReached:Once(function(name)
		if name ~= "Erase" then return end

		if hum then
			hum.WalkSpeed = 32
			hum.JumpPower = 50
		end

		self.State.OldTransparencyTable = {}

		-- Map current elements to store their original transparency state
		for _, part in pairs(self.Character:GetDescendants()) do
			if (part:IsA("BasePart") and part.Name ~= "HumanoidRootPart") or part:IsA("Decal") or part:IsA("Texture") then
				table.insert(self.State.OldTransparencyTable, {
					Part = part,
					OldTrans = part.Transparency
				})
				part.Transparency = 1
			end
		end

		-- Dispatch UI event to client if the entity is a Player
		if self.Player then
			Remotes.ScreenAction:FireClient(self.Player, "TimeErase", {
				Duration = data.Duration, 
				Weight = 2.5,
				State = true, 
				List = self.State.OldTransparencyTable
			})
		end

		task.delay(data.Duration, function()
			self:ReverseErase()
		end)
	end)
end

function KingCrimson:TimeEraseStop()
	self:ReverseErase()
end

function KingCrimson:Epitaph()
	if not self.Character then return end
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local hum = self.Character:FindFirstChildOfClass("Humanoid")

	local moveData = MOVES.Epitaph
	local duration = moveData.Duration or 2

	self.Character:SetAttribute("StandName", "KingCrimson")
	self.Character:SetAttribute("Countering", "Epitaph")

	if root and ASSETS.Sounds.Epitaph then
		SFXHandler.PlaySound(root, ASSETS.Sounds.Epitaph, false, 0, 2)
	end

	if hum then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
	end

	local shadow = Instance.new("Highlight")
	shadow.Name = "CounterShadow"
	shadow.Parent = self.Character
	shadow.FillColor = Color3.new(0, 0, 0)
	shadow.OutlineTransparency = 1
	shadow.FillTransparency = 1
	shadow.DepthMode = Enum.HighlightDepthMode.Occluded

	local tweenInfo = TweenInfo.new(duration / 2, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out, 0, true)
	TweenService:Create(shadow, tweenInfo, {FillTransparency = 0.1}):Play()

	task.delay(duration, function()
		if self.Character:GetAttribute("Countering") == "Epitaph" then
			self.Character:SetAttribute("Countering", nil)

			if shadow then
				local endTween = TweenService:Create(shadow, TweenInfo.new(0.5), {FillTransparency = 1})
				endTween:Play()
				endTween.Completed:Wait()
				shadow:Destroy()
			end

			if hum then
				MovementHandler.Update(self.Character)
			end
		end
	end)
end


-- This is a counter ability which is required by another server script. That is the reason why I didn't use the self metatable here.
function KingCrimson.EpitaphApply(victimChar, attackerChar)
	local victimRoot = victimChar:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attackerChar:FindFirstChild("HumanoidRootPart")

	-- Clear counter state
	victimChar:SetAttribute("Countering", nil)
	local shadow = victimChar:FindFirstChild("CounterShadow")
	if shadow then shadow:Destroy() end

	if victimRoot and attackerRoot then
		SFXHandler.PlaySound(victimRoot, ASSETS.Sounds.TimeSkip, false, 0, 1)

		-- Position behind the attacker
		local behindCFrame = attackerRoot.CFrame * CFrame.new(0, 0, 5)
		victimRoot.CFrame = CFrame.lookAt(behindCFrame.Position, attackerRoot.Position)

		task.spawn(function()
			if not victimChar.Parent or not attackerChar.Parent then return end
			local victimPlayer = Players:GetPlayerFromCharacter(victimChar)
			-- FireClient safely to prevent errors if the victim is an NPC
			if victimPlayer then
				ReplicatedStorage.Remotes.ScreenAction:FireClient(victimPlayer,"CameraFollow",{IsFollow = false})
			end
		end)

		task.delay(0.3, function() 
			if not victimChar.Parent or not attackerChar.Parent then return end

			local hum = victimChar:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.AutoRotate = false
				hum.WalkSpeed = 0 
				hum.JumpPower = 0
			end

			-- Passed victimChar instead of victimPlayer to HitboxHandler so NPCs can also counter attack

			local moveData = table.clone( MOVES.Epitaph)
			moveData["HitboxCFrame"] = attackerRoot.CFrame
			
			HitboxHandler.Run(victimChar, victimChar,moveData)

			task.delay(0.5, function() 
				if hum then
					hum.AutoRotate = true
					MovementHandler.Update(victimChar)
				end
			end)
		end)
	end
end



--[[
The counter: Epitaph

This is the counter ability. When the player triggers the designated keycode, the "Epitaph" function makes the player go idle for a few seconds. I use a Tween on a Highlight instance to create a dark shadow visual effect.

In this period of time, the player receives an attribute that can be detected by the HitboxHandler.

Whenever the HitboxHandler detects any counter attributes, it immediately checks for the server module of the target ability name, which is this module for our example.

The counter execution is run by the HITBOX HANDLER, not the player itself. Because the HitboxHandler is a separate server script interacting with two different characters (attacker and victim), it needs to call this as a global class function (KingCrimson.EpitaphApply) rather than an instance method. This is the technical reason why I didn't use the 'self.' metatable here.

What the counter does is calculate the positional math to teleport the victim behind the attacker. I do this by multiplying the attacker's Root CFrame by CFrame.new(0, 0, 5), and then using CFrame.lookAt to ensure the victim immediately faces the attacker. It then temporarily freezes the victim's Humanoid and auto-rotates before executing a chop via HitboxHandler.Run.
]]--

--[[
Time erase

Time Erase is the most complicated system in this script, and it actually splits logic with its own client script.

When the skill is triggered, I wait for a specific animation KeyframeReached event ('Erase') before triggering the effect. The player becomes invisible on the server. 

To ensure the player restores to their correct previous appearance (rather than just setting everything to fully opaque), I implemented a loop that maps the current transparency of every BasePart, Decal, and Texture into 'self.State.OldTransparencyTable'. This data mapping decision allows me to safely save and restore exact visual states.

The client makes the player visible again locally immediately. This creates a cool visual interaction where the player can see themselves, while the rest of the server cannot.

This skill is stopped automatically by the client module if it was active for a certain amount of seconds or if the player makes an attacking move. 

The :ReverseErase function clears out the old transparency map (setting it to nil) to ensure garbage collection handles it and no memory leaks occur, before reverting the player's WalkSpeed.

The client side of the code handles the environmental changes you see in-game, such as the world crashing and skybox changes, taking the visual heavy-lifting off the server's shoulders.
]]--


--[[
Thanks for reading my ability script. I hope the explanations clearly illustrate the logic and interaction between systems.
]]--

function KingCrimson:Destroy()
	-- Smooth Despawn (Auras included)
	local stand = self:GetStand()
	if stand then
		self:Summon()
	end

	--  Stop Barrage If Enabled
	if self.State.IsBarraging then
		self:BarrageStop()
	end

	-- Cancell All Active Tasks
	if self.State.StayForwardTask then
		task.cancel(self.State.StayForwardTask)
		self.State.StayForwardTask = nil
	end

	--  Cancel Time Erase properly if the character gets destroyed/ragdolled while using it
	if self.State.TimeEraseActive then
		self:ReverseErase()
	end
end


return KingCrimson
