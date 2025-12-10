-- Lazer puzzle game main script
-- - Uses Raycasting, Tweening, RunService heartbeat, and basic physics/rooting checks.

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MoveMirrorEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("MoveMirror")
local player = game.Players.LocalPlayer
local Button = player.PlayerGui:WaitForChild("ScreenGui"):WaitForChild("Button")
local heartbeatConnections, laserSegments, laserFillers = {}, {}, {}
local lasersHitGoal, laserActive = {}, false
local pointingAtTarget, pointingStartTime, timeOfLastHit = false, nil, nil
local timeToWait = 3

-- Simple leaderstats container 
local Leaderstats = Instance.new("Folder", player)
Leaderstats.Name = "leaderstats" -- be explicit
local Level = Instance.new("NumberValue", Leaderstats)
Level.Name = "Level"
local LevelMap = nil
local cam = workspace.CurrentCamera

-- Force scriptable camera. I intentionally wait so camera is always scriptable here.
repeat wait() cam.CameraType = Enum.CameraType.Scriptable until cam.CameraType == Enum.CameraType.Scriptable

-- Helper: create a neon laser segment between two points
local function CreateLaserSegment(startPos, endPos, color)
	local segment = Instance.new("Part")
	segment.Name = "Laser"
	segment.Material = Enum.Material.Neon
	segment.CastShadow = false
	segment.Size = Vector3.new(0.2, 0.2, (endPos - startPos).Magnitude)
	segment.Color = color
	segment.Anchored = true
	segment.CanCollide = false
	segment.CanTouch = false
	segment.CanQuery = false
	segment.Locked = true
	-- orient the part so it faces the end position
	segment.CFrame = CFrame.new((startPos + endPos) / 2, endPos)
	segment.Parent = workspace:FindFirstChild("Lasers") or workspace -- safe fallback
	return segment
end

-- Clear laser segments. If Color passed, only remove that color; otherwise clear all laser parts.
local function ClearLaserSegments(Color)
	for _, laser in ipairs((workspace:FindFirstChild("Lasers") and workspace.Lasers:GetChildren()) or {}) do
		if not Color or laser.Color == Color then
			laser:Destroy()
		end
	end
end

-- Delete any filler parts we created during goal animation
local function DeleteFillers()
	for _, filler in ipairs(laserFillers) do
		if filler and filler.Parent then filler:Destroy() end
	end
	laserFillers = {}
end

-- Create animated cylindrical fillers between a laser and its goal (visual flourish)
local function CreateFillers(laser, goal)
	if not laser then return end
	local function makeFiller(pos, color)
		local filler = Instance.new("Part")
		filler.Anchored = true
		filler.Shape = Enum.PartType.Cylinder
		filler.Orientation = Vector3.new(0, 0, 90)
		filler.Position = pos
		filler.Size = Vector3.new(0.01, 0.01, 0.01)
		filler.Color = color
		filler.Material = Enum.Material.Neon
		filler.Parent = workspace:FindFirstChild("Temp") or workspace
		TweenService:Create(filler, TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Size = Vector3.new(0.01, 3.7, 3.7)}):Play()
		table.insert(laserFillers, filler)
	end

	makeFiller(laser.Position, laser.Color)
	if goal then makeFiller(goal.Position, goal.Color) end
end

-- Main laser shoot routine. Traces laser through scene, handles mirrors, splitters, and goals.
local function Shoot(Laser)
	-- remove previous segments of this laser color for clarity
	ClearLaserSegments(Laser.Color)
	laserSegments = {}

	-- local recursion to step laser rays forward
	local function Step(currentPos, currentNormal, bounceCount, color, isSplitterHit)
		if bounceCount >= 50 then return end
		local params = RaycastParams.new()
		local direction = currentNormal.Unit * 1000
		params.FilterType = Enum.RaycastFilterType.Exclude

		-- Build filter list safely: exclude this laser part and the lasers container.
		local filterList = {}
		if typeof(Laser) == "Instance" then table.insert(filterList, Laser) end
		if workspace:FindFirstChild("Lasers") then table.insert(filterList, workspace.Lasers) end
		-- Exclude temporary fillers if they exist
		for _, f in ipairs(laserFillers) do
			if f and f:IsA("BasePart") then table.insert(filterList, f) end
		end
		-- exclude level glass if available
		if LevelMap and LevelMap:FindFirstChild("Glass") then table.insert(filterList, LevelMap.Glass) end

		params.FilterDescendantsInstances = filterList

		local result = workspace:Raycast(currentPos, direction, params)
		local endPos
		if result then
			endPos = result.Position
			local hitPart = result.Instance
			if hitPart and hitPart.Parent and hitPart.Parent.Name == "Tech" and hitPart.Name == "Fixer" then
				-- Fixer simply flips the normal on the axis it detects
				local normal = result.Normal
				if normal == Vector3.new(0, 0, 1) then currentNormal = Vector3.new(0, 0, -1)
				elseif normal == Vector3.new(0, 0, -1) then currentNormal = Vector3.new(0, 0, 1)
				elseif normal == Vector3.new(1, 0, 0) then currentNormal = Vector3.new(-1, 0, 0)
				elseif normal == Vector3.new(-1, 0, 0) then currentNormal = Vector3.new(1, 0, 0)
				elseif normal == Vector3.new(0, 1, 0) then currentNormal = Vector3.new(0, 1, 0)
				elseif normal == Vector3.new(0, -1, 0) then currentNormal = Vector3.new(0, -1, 0) end
				local segment = CreateLaserSegment(currentPos, endPos, color)
				table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
				Step(endPos, currentNormal, bounceCount + 1, color, false)

			elseif hitPart and hitPart.Parent and hitPart.Parent.Name == "Tech" and hitPart.Name == "Splitter" then
				-- Splitter spawns multiple rays: keep it simple, three directions
				local normal = result.Normal
				if normal == Vector3.new(0, 0, 1) then currentNormal = Vector3.new(0, 0, -1)
				elseif normal == Vector3.new(0, 0, -1) then currentNormal = Vector3.new(0, 0, 1)
				elseif normal == Vector3.new(1, 0, 0) then currentNormal = Vector3.new(-1, 0, 0)
				elseif normal == Vector3.new(-1, 0, 0) then currentNormal = Vector3.new(1, 0, 0)
				elseif normal == Vector3.new(0, 1, 0) then currentNormal = Vector3.new(0, 1, 0)
				elseif normal == Vector3.new(0, -1, 0) then currentNormal = Vector3.new(0, -1, 0) end

				local offsetDistance = 2
				local splitStartPos = hitPart.Position + currentNormal.Unit * offsetDistance
				local rightVector = currentNormal:Cross(Vector3.new(0, 1, 0)).Unit
				if rightVector.Magnitude < 0.01 then rightVector = currentNormal:Cross(Vector3.new(1, 0, 0)).Unit end
				local splitNormals = {currentNormal + rightVector * 0.5, currentNormal - rightVector * 0.5, currentNormal}
				for _, newNormal in ipairs(splitNormals) do
					Step(splitStartPos, newNormal.Unit, bounceCount + 1, color, true)
				end
				if not isSplitterHit then
					local segment = CreateLaserSegment(currentPos, endPos, color)
					table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
				end

			else
				-- Mirror reflection or end-of-path logic
				if hitPart and hitPart.Parent and hitPart.Parent.Name == "Mirrors" then
					local norm = result.Normal
					currentNormal = currentNormal - (2 * currentNormal:Dot(norm) * norm)
					local segment = CreateLaserSegment(currentPos, endPos, color)
					table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
					Step(endPos, currentNormal, bounceCount + 1, color, false)
				else
					-- Goal detection: a laser hit its own goal part
					if hitPart and hitPart.Name == Laser.Name and hitPart.Parent and hitPart.Parent.Name == "Goals" then
						if not lasersHitGoal[Laser.Name] then
							lasersHitGoal[Laser.Name] = true
							local allHit = true
							for _, v in pairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
								if not lasersHitGoal[v.Name] then allHit = false break end
							end
							if allHit then
								timeOfLastHit = tick()
								for _, laser in ipairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
									local goal = (LevelMap and LevelMap.Goals) and LevelMap.Goals:FindFirstChild(laser.Name)
									if laser and goal then CreateFillers(laser, goal) end
								end
							end
						end
					else
						-- If we previously were hitting goal and now no longer, reset the state
						if lasersHitGoal[Laser.Name] then
							lasersHitGoal[Laser.Name] = false
							DeleteFillers()
						end
					end
					local segment = CreateLaserSegment(currentPos, endPos, color)
					table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
				end
			end
		else
			-- No hit: draw until max distance
			endPos = currentPos + direction
			local segment = CreateLaserSegment(currentPos, endPos, color)
			table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
		end
	end

	-- Start the ray from the laser part
	local startPos = Laser.Position
	local startNormal = Laser.CFrame.LookVector
	local color = Laser.Color -- fixed capitalization bug
	Step(startPos, startNormal, 0, color)
end

-- Smooth camera transitions between levels
local function MoveCam()
	local camPart = workspace.LCamParts:WaitForChild("Cam" .. tostring(Level.Value))
	local camPart2 = workspace.LCamParts:WaitForChild("Cam" .. tostring(Level.Value + 1))
	local tween = TweenService:Create(cam, TweenInfo.new(.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = camPart.CFrame + Vector3.new(0, 10, 0)})
	tween:Play()
	tween.Completed:Wait(1)
	local tween2 = TweenService:Create(cam, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = camPart2.CFrame + Vector3.new(0, 10, 0)})
	tween2:Play()
	tween2.Completed:Wait(1)
	local tween3 = TweenService:Create(cam, TweenInfo.new(.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = camPart2.CFrame})
	tween3:Play()
	tween3.Completed:Wait(1)
	Level.Value = Level.Value + 1
end

-- Called when the player has completed a level: turn lasers and goals green, animate, and advance
local function HandleWin()
	for _, laser in ipairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
		for _, segment in ipairs((workspace:FindFirstChild("Lasers") and workspace.Lasers:GetChildren()) or {}) do
			if segment.Name == "Laser" then segment.Color = Color3.fromRGB(0, 255, 0) end
		end
		local goal = LevelMap.Goals:FindFirstChild(laser.Name)
		if laser and goal then
			laser.Color = Color3.fromRGB(0, 255, 0)
			goal.Color = Color3.fromRGB(0, 255, 0)
		end
	end
	for i, filler in ipairs(laserFillers) do
		if filler then filler.Color = Color3.fromRGB(0, 255, 0) end
	end
	for _, laser in ipairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
		local goal = LevelMap.Goals:FindFirstChild(laser.Name)
		if laser and goal then CreateFillers(laser, goal) end
	end
	laserActive = false
	for _, connection in ipairs(heartbeatConnections) do
		if connection.Connected then connection:Disconnect() end
	end
	heartbeatConnections = {}
	wait(1)
	MoveCam()
end

-- Check whether all lasers currently hit their goals and enough time has passed
local function CheckForWin()
	local allHit = true
	for _, v in pairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
		if not lasersHitGoal[v.Name] then allHit = false break end
	end
	if allHit and timeOfLastHit and tick() - timeOfLastHit >= timeToWait then
		HandleWin()
	end
end

-- When level number changes, set up level map and heartbeat shoot loops
Level.Changed:Connect(function()
	LevelMap = workspace.Levels:WaitForChild("L" .. tostring(Level.Value))
	laserActive = true
	ClearLaserSegments() -- clear everything
	DeleteFillers()
	lasersHitGoal = {}
	pointingAtTarget, pointingStartTime, timeOfLastHit = false, nil, nil
	local camPart = workspace.LCamParts:WaitForChild("Cam" .. tostring(Level.Value))
	cam.CFrame = camPart.CFrame

	for i, v in pairs(LevelMap.Lasers:GetChildren()) do
		spawn(function()
			local Goal = LevelMap.Goals:FindFirstChild(v.Name)
			local connection
			connection = RunService.Heartbeat:Connect(function()
				if laserActive then
					Shoot(v)
					if pointingAtTarget and pointingStartTime then
						if tick() - pointingStartTime >= 3 then
							HandleWin(v, Goal)
							pointingAtTarget, pointingStartTime = false, nil
						end
					end
					CheckForWin()
				end
			end)
			table.insert(heartbeatConnections, connection)
		end)
	end
end)

-- start at level one
Level.Value = 1

-- Input handling section (mouse/touch/keyboard)
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local LocalPlayer = Players.LocalPlayer
local mouse = LocalPlayer:GetMouse()
local selectedPart = nil

-- Utility: check if a moving part is intersecting any relevant static geometry
local function isTouchingWall(part)
	if not part then return false end
	for _, otherPart in workspace:GetPartsInPart(part) do
		if otherPart:IsDescendantOf(workspace:FindFirstChild("Walls") or workspace)
		or (LevelMap and otherPart:IsDescendantOf(LevelMap:FindFirstChild("Glass") or workspace))
		or (LevelMap and otherPart:IsDescendantOf(LevelMap:FindFirstChild("Lasers") or workspace))
		or (LevelMap and otherPart:IsDescendantOf(LevelMap:FindFirstChild("Goals") or workspace))
		or (LevelMap and otherPart:IsDescendantOf(LevelMap:FindFirstChild("Mirrors") or workspace)) then
			return true
		end
	end
	return false
end

-- Move selected part toward a target position in small increments to avoid tunneling
local function MoveTo(Pos)
	if not selectedPart then return end
	local startPos = selectedPart.Position
	local delta = Pos - startPos
	local i = 0
	repeat
		local lastPos = selectedPart.Position
		selectedPart.Position = selectedPart.Position + delta / 100
		if #workspace:GetPartsInPart(selectedPart) > 0 then
			selectedPart.Position = lastPos
			break
		end
		i = i + 1
	until i >= 100
end

-- Move part axis-aligned with simple wall checks (keeps Y stable)
local function movePart(targetPosition, part)
	if not part then return end
	local startPos = part.Position
	local delta = targetPosition - startPos
	local stepCount = 10
	local stepSize = delta / stepCount
	local lastPos = part.Position
	-- try X
	part.Position = Vector3.new(targetPosition.X, part.Position.Y, part.Position.Z)
	if isTouchingWall(part) then part.Position = lastPos end
	lastPos = part.Position
	-- try Z
	part.Position = Vector3.new(part.Position.X, part.Position.Y, targetPosition.Z)
	if isTouchingWall(part) then part.Position = lastPos end
end

-- Fix small embedding into walls by nudging slightly
local function fixGap(part)
	if not part then return end
	local wallOffset = 0.1
	local wallPosition = part.Position
	if isTouchingWall(part) then
		part.Position = Vector3.new(wallPosition.X + wallOffset, wallPosition.Y, wallPosition.Z)
	end
end

-- Play a sound stored under this script by name (I keep sounds as children)
local function playSound(soundName)
	local snd = script:FindFirstChild(soundName)
	if snd and snd:IsA("Sound") then
		local soundClone = snd:Clone()
		soundClone.Parent = workspace
		Debris:AddItem(soundClone, 1)
		soundClone:Play()
	end
end

-- Mouse drag for desktop
mouse.Button1Down:Connect(function()
	if not (LevelMap and LevelMap:FindFirstChild("Mirrors")) then return end
	local target = mouse.Target
	selectedPart = target
	if target and target:IsDescendantOf(LevelMap:WaitForChild("Mirrors")) and target:FindFirstChild("CanDrag") and target.CanDrag.Value then
		selectedPart = target
		playSound("Click")
		while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) do
			local targetPosition = mouse.Hit.Position
			local Goal = Vector3.new(targetPosition.X, selectedPart.Position.Y, targetPosition.Z)
			local Pos = selectedPart.Position:Lerp(Goal, .3)
			MoveTo(Vector3.new(Pos.X, Pos.Y, selectedPart.Position.Z))
			MoveTo(Vector3.new(selectedPart.Position.X, Pos.Y, Pos.Z))
			fixGap(selectedPart)
			task.wait()
		end
		selectedPart = nil
		playSound("Click")
	end
end)

-- Touch controls (simple)
UserInputService.TouchStarted:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	local target = mouse.Target
	if target and LevelMap and target:IsDescendantOf(LevelMap:WaitForChild("Mirrors")) and target:FindFirstChild("CanDrag") and target.CanDrag.Value then
		selectedPart = target
	end
end)

UserInputService.TouchMoved:Connect(function(input, gameProcessed)
	if gameProcessed or not selectedPart then return end
	local targetPosition = mouse.Hit.Position
	local Goal = Vector3.new(targetPosition.X, selectedPart.Position.Y, targetPosition.Z)
	local Pos = selectedPart.Position:Lerp(Goal, .3)
	MoveTo(Vector3.new(Pos.X, Pos.Y, selectedPart.Position.Z))
	MoveTo(Vector3.new(selectedPart.Position.X, Pos.Y, Pos.Z))
	fixGap(selectedPart)
end)

UserInputService.TouchEnded:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	selectedPart = nil
end)

-- Mobile rotate buttons
if UserInputService.TouchEnabled then
	local leftButton = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("Mobile"):WaitForChild("Left")
	local rightButton = LocalPlayer.PlayerGui.Mobile.Right
	local function rotatePart(clockwise)
		if selectedPart then
			local isPressed = true
			local angleStep = clockwise and 1.2 or -1.2
			leftButton.MouseButton1Up:Connect(function() isPressed = false end)
			while isPressed and selectedPart do
				selectedPart.Orientation = selectedPart.Orientation + Vector3.new(0, angleStep, 0)
				if isTouchingWall(selectedPart) then
					selectedPart.Orientation = selectedPart.Orientation - Vector3.new(0, angleStep, 0)
				end
				task.wait()
			end
		end
	end
	leftButton.MouseButton1Down:Connect(function() rotatePart(true) end)
	rightButton.MouseButton1Down:Connect(function() rotatePart(false) end)
end

-- Keyboard rotate (hold R to rotate the selected mirror)
local rotating, rotationSpeed, rotateAmount = false, .01, 2
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.R and selectedPart and selectedPart:FindFirstChild("CanRotate") and selectedPart.CanRotate.Value then
		rotating = true
		while rotating and selectedPart do
			selectedPart.Orientation = selectedPart.Orientation + Vector3.new(0, rotateAmount, 0)
			if isTouchingWall(selectedPart) then
				selectedPart.Orientation = selectedPart.Orientation - Vector3.new(0, rotateAmount, 0)
			end
			task.wait(rotationSpeed)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.R then
		rotating = false
	end
end)
