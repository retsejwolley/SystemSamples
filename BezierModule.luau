--!strict

-- Bezier based projectile mover
-- Uses cubic bezier math instead of lerp chains so motion stays stable
-- even if framerate changes. Rotation follows the curve tangent.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- exported config type so other scripts get autocomplete when requiring this module
export type BezierConfig = {
	TargetPart: BasePart,
	FaceAttachment: Attachment,
	TargetPosition: Vector3,
	Duration: number,
	Style: string?,
	EasingStyle: Enum.EasingStyle?,
	EasingDirection: Enum.EasingDirection?,
	VisualizePath: boolean?
}

-- main object type
-- listing private methods here helps Luau strict mode understand the structure
export type BezierMover = {
	Config: BezierConfig,
	IsPlaying: boolean,
	IsPaused: boolean,
	_startPos: Vector3,
	_p1: Vector3,
	_p2: Vector3,
	_elapsedTime: number,
	_connection: RBXScriptConnection?,
	_completedEvent: BindableEvent,
	_waypointEvent: BindableEvent,
	Completed: RBXScriptSignal,
	WaypointReached: RBXScriptSignal,

	_GenerateControlPoints: (BezierMover) -> (),
	_GetPositionAt: (BezierMover, number) -> Vector3,
	_GetTangentAt: (BezierMover, number) -> Vector3, 

	_DrawDebugPath: (BezierMover) -> (),
    -- samples used to visualize the curve

	Play: (BezierMover) -> (),
	Pause: (BezierMover) -> (),
	Resume: (BezierMover) -> (),
	Cancel: (BezierMover) -> (),
	Destroy: (BezierMover) -> ()
}

local BezierMover = {}
BezierMover.__index = BezierMover

-- list of movement styles
-- easier to extend instead of scattering strings in the code
local CURVE_STYLES = {
	Standard = "Standard",
	ZigZag = "ZigZag",
	OverheadLoop = "OverheadLoop",
	Chaotic = "Chaotic",
	Boomerang = "Boomerang",
	GroundSkim = "GroundSkim",
	Orbit = "Orbit"
}

function BezierMover.new(config: BezierConfig): BezierMover
	-- Luau's strict mode blocks direct casting of newly attached metatables to exported type aliases.
	-- Casting the table to 'any' strips the internal metatable tracking.
	-- This bypasses the type error and allows the final return statement to enforce the BezierMover type.
	local self = setmetatable({}, BezierMover) :: any

	self.Config = config

	-- if the user didn't specify a style we fall back to Standard
    -- doing this here avoids having to check for nil inside the movement logic later

    self.Config.Style = config.Style or CURVE_STYLES.Standard

	-- duration is used as a divisor when calculating progress
    -- if someone passes 0 the movement math would explode (division by zero)
    -- clamping it here guarantees the runtime loop stays safe
    self.Config.Duration = math.max(config.Duration, 0.01)

	-- easing parameters are optional so the module can still run
    -- even if the caller only provides the basic movement settings
    self.Config.EasingStyle = config.EasingStyle or Enum.EasingStyle.Linear
    self.Config.EasingDirection = config.EasingDirection or Enum.EasingDirection.InOut

	self.IsPlaying = false
	self.IsPaused = false
	self._elapsedTime = 0

	-- cache the starting position immediately
    -- if the part gets triggered by physics or another script before Play()
    -- the curve would otherwise start from the wrong position
    self._startPos = config.TargetPart.Position

	self._completedEvent = Instance.new("BindableEvent")
	self._waypointEvent = Instance.new("BindableEvent")

	self.Completed = self._completedEvent.Event
	self.WaypointReached = self._waypointEvent.Event

	self:_GenerateControlPoints()

	if self.Config.VisualizePath then
		self:_DrawDebugPath()
	end

	return self :: BezierMover
end

function BezierMover._GenerateControlPoints(self: BezierMover)
	--[[
	Bezier curves use four points:

	P0 : starting position
	P1 : first control point
	P2 : second control point
	P3 : final destination

	]]
	
	local p0 = self._startPos
	local p3 = self.Config.TargetPosition
	-- distance is reused as a scaling factor for most curve styles
    -- this keeps the shape looking proportional whether the target
    -- is 5 studs away or 200 studs away
    local distance = (p3 - p0).Magnitude

	-- midpoint is an anchor for many curve styles
    -- it lets us bend the curve without biasing it too heavily
    -- toward either the start or the target
    local midPoint = p0:Lerp(p3, 0.5)
	local upVector = Vector3.new(0, 1, 0)
	local forwardVector = (p3 - p0).Unit

	-- when forwardVector is perfectly vertical the cross product becomes zero
    -- that would break normalization and produce NaN values
    -- so we fall back to a safe axis to keep the math stable
    if rightVector.Magnitude == 0 then
	   rightVector = Vector3.new(1, 0, 0)
    end

	local style = self.Config.Style

	-- Modifying the control points (P1 and P2) dictates the physical bending of the curve.
	-- For example, pulling P1 backwards and upwards creates an initial arc, 
	-- while pushing P2 downwards forces a dive effect.
	if style == CURVE_STYLES.Standard then
		self._p1 = p0:Lerp(midPoint, 0.5) + Vector3.new(0, distance * 0.2, 0)
		self._p2 = midPoint:Lerp(p3, 0.5) + Vector3.new(0, distance * 0.2, 0)

	elseif style == CURVE_STYLES.ZigZag then
		self._p1 = p0:Lerp(midPoint, 0.5) + (rightVector * (distance * 0.4))
		self._p2 = midPoint:Lerp(p3, 0.5) - (rightVector * (distance * 0.4))

	elseif style == CURVE_STYLES.OverheadLoop then
		self._p1 = p0 + (forwardVector * (distance * 0.1)) + Vector3.new(0, distance * 0.9, 0)
		self._p2 = p3 + (forwardVector * -(distance * 0.2)) + Vector3.new(0, distance * 0.6, 0)

	elseif style == CURVE_STYLES.Chaotic then
		-- use local Random instead of math.random to avoid shared seed patterns
		local rng = Random.new()
		self._p1 = p0 + Vector3.new(rng:NextNumber(-distance, distance), rng:NextNumber(0, distance), rng:NextNumber(-distance, distance))
		self._p2 = p3 + Vector3.new(rng:NextNumber(-distance, distance), rng:NextNumber(0, distance), rng:NextNumber(-distance, distance))

	elseif style == CURVE_STYLES.Boomerang then
		self._p1 = p3 + (forwardVector * distance) + (rightVector * (distance * 0.5))
		self._p2 = p3 - (forwardVector * (distance * 0.2)) + (rightVector * (distance * 0.5))

	elseif style == CURVE_STYLES.GroundSkim then
		self._p1 = p0 - Vector3.new(0, distance * 0.4, 0)
		self._p2 = p3 - Vector3.new(0, distance * 0.4, 0)

	elseif style == CURVE_STYLES.Orbit then
		self._p1 = p0 + (rightVector * distance) + Vector3.new(0, distance * 0.5, 0)
		self._p2 = p3 - (rightVector * distance) - Vector3.new(0, distance * 0.5, 0)
	else
		self._p1 = p0:Lerp(p3, 0.33)
		self._p2 = p0:Lerp(p3, 0.66)
	end
end

function BezierMover._GetPositionAt(self: BezierMover, t: number): Vector3
	local u = 1 - t
	local uu = u * u
	local uuu = uu * u
	local tt = t * t
	local ttt = tt * t

	-- direct cubic bezier formula (faster than chaining lerps)
	local term1 = uuu * self._startPos
	local term2 = 3 * uu * t * self._p1
	local term3 = 3 * u * tt * self._p2
	local term4 = ttt * self.Config.TargetPosition
	
	--[[
	Evaluate the cubic Bezier polynomial.

	B(t) = (1 - t)^3 P0
     + 3(1 - t)^2 t P1
     + 3(1 - t) t^2 P2
     + t^3 P3

	Calculating the polynomial directly avoids repeatedly calling Vector3:Lerp,
	which would allocate additional vectors every frame.
	]]

	return term1 + term2 + term3 + term4
end

function BezierMover._GetTangentAt(self: BezierMover, t: number): Vector3
	
	-- derivative gives the tangent direction of the curve
	
	local u = 1 - t
	local tt = t * t
	local uu = u * u

	local p0 = self._startPos
	local p1 = self._p1
	local p2 = self._p2
	local p3 = self.Config.TargetPosition

	-- This calculates the derivative of the cubic function to find the tangent vector.
	-- Extracting the mathematical slope directly is highly accurate compared to checking the position 
	-- slightly ahead of the current frame, completely eliminating rotation jitter at high speeds.
	local term1 = 3 * uu * (p1 - p0)
	local term2 = 6 * u * t * (p2 - p1)
	local term3 = 3 * tt * (p3 - p2)

	local tangent = term1 + term2 + term3

	if tangent.Magnitude > 0 then
		return tangent.Unit
	else
		return Vector3.new(0, 0, -1) 
	end
	

end

function BezierMover._DrawDebugPath(self: BezierMover)
	
	-- debug markers along the curve so the path can be seen in workspace
    -- more segments = smoother debug line but also more parts spawned
	local segments = 30 
	local folder = Instance.new("Folder")
	folder.Name = "BezierDebug_" .. self.Config.TargetPart.Name
	folder.Parent = workspace

	for i = 0, segments do
		local t = i / segments
		local pos = self:_GetPositionAt(t)
		local tangent = self:_GetTangentAt(t)

		local up = Vector3.new(0, 1, 0)
		local right = tangent:Cross(up).Unit
		local realUp = right:Cross(tangent).Unit

		local marker = Instance.new("Part")
		marker.Size = Vector3.new(0.1, 0.1, 0.5)
		marker.Anchored = true
		marker.CanCollide = false
		marker.Material = Enum.Material.Neon
		marker.Color = Color3.new(1, 0, 0)

		marker.CFrame = CFrame.fromMatrix(pos, right, realUp, -tangent)
		marker.Parent = folder

		-- Creates a localized fade effect. 
		-- The delay matches the lifetime of the projectile, meaning the path 
		-- begins fading exactly as the projectile finishes its journey.
		local fadeInfo = TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, self.Config.Duration * t)
		game:GetService("TweenService"):Create(marker, fadeInfo, {Transparency = 1}):Play()
	end

	game:GetService("Debris"):AddItem(folder, self.Config.Duration + 3)
end

function BezierMover.Play(self: BezierMover)
	if self.IsPlaying then return end

	self.IsPlaying = true
	self.IsPaused = false
	
	-- Heartbeat runs once every frame right before physics simulation
    -- tying the motion to this signal keeps the movement consistent
    -- even if the server frame rate fluctuates
	self._connection = RunService.Heartbeat:Connect(function(deltaTime)
		if self.IsPaused then return end

		-- Accumulating deltaTime calculates the exact time passed regardless of frame drops.
		self._elapsedTime += deltaTime

		-- convert elapsed runtime into a normalized progress value (0 → 1)
        -- this becomes the parameter used to evaluate the curve
        local rawAlpha = math.clamp(self._elapsedTime / self.Config.Duration, 0, 1)

		-- TweenService:GetValue translates the linear time progress (rawAlpha) into an eased progression.
		-- This modifies the velocity along the path without altering the coordinate geometry of the path itself.
		local t = TweenService:GetValue(rawAlpha, self.Config.EasingStyle :: Enum.EasingStyle, self.Config.EasingDirection :: Enum.EasingDirection)

		local currentPos = self:_GetPositionAt(t)
		local tangentVector = self:_GetTangentAt(t)

		local baseCFrame = CFrame.lookAt(currentPos, currentPos + tangentVector)

		-- inverting the attachment's rotational matrix returns its opposite offset values.
		-- multiplying the base CFrame by this inverse counters the default front facing orientation,
		-- forcing the specified attachment face to look forward along the curve.
		local attachmentOffset = self.Config.FaceAttachment.CFrame.Rotation:Inverse()
		self.Config.TargetPart.CFrame = baseCFrame * attachmentOffset

		--The waypoint event 
		--The additional subtraction check prevents the signal from firing
		--multiple times if the frame step happens to land near the same value on consecutive updates.
		
		if rawAlpha >= 0 and rawAlpha - (deltaTime / self.Config.Duration) < 0.5 then
			self._waypointEvent:Fire(0.5)
		end

		if rawAlpha >= 1 then
			self.Config.TargetPart.Position = self.Config.TargetPosition 
			self:Cancel()
			self._completedEvent:Fire()
		end
	end)
end

function BezierMover.Pause(self: BezierMover)
	self.IsPaused = true
end

function BezierMover.Resume(self: BezierMover)
	if self.IsPlaying and self.IsPaused then
		self.IsPaused = false
	end
end

function BezierMover.Cancel(self: BezierMover)
	self.IsPlaying = false
	if self._connection then
		-- Disconnecting the RunService connection immediately halts the physics loop.
		-- If this is neglected, abandoned loops will stack and degrade server performance permanently.
		self._connection:Disconnect()
		self._connection = nil
	end
end

function BezierMover.Destroy(self: BezierMover)
	self:Cancel()
	self._completedEvent:Destroy()
	self._waypointEvent:Destroy()

	-- cleanup so the object can be garbage collected
	table.clear(self)
end

return BezierMover
