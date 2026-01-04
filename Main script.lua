-- Lazer puzzle main LocalScript

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local EventsFolder = ReplicatedStorage:WaitForChild("Events")
local MoveMirrorEvent = EventsFolder:FindFirstChild("MoveMirror")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local cam = workspace.CurrentCamera

-- Constants (easy to tune)
local MAX_LASER_DISTANCE = 1000
local MAX_BOUNCES = 50
local FILLER_TWEEN_TIME = 3
local WAIT_AFTER_ALL_HIT = 3
local LASER_THICKNESS = 0.2

-- State
local heartbeatConnections = {}
local laserSegments = {}
local laserFillers = {}
local lasersHitGoal = {}
local laserActive = false
local pointingAtTarget, pointingStartTime, timeOfLastHit = false, nil, nil

-- Leaderstats / Level
local Leaderstats = Instance.new("Folder")
Leaderstats.Name = "leaderstats"
Leaderstats.Parent = localPlayer

local Level = Instance.new("NumberValue")
Level.Name = "Level"
Level.Parent = Leaderstats

local LevelMap = nil

-- Ensure camera can be controlled by script.
-- We perform a small number of attempts and then give up to avoid tight infinite loops.
do
	local attempts = 0
	while cam.CameraType ~= Enum.CameraType.Scriptable and attempts < 10 do
		cam.CameraType = Enum.CameraType.Scriptable
		task.wait(0.05)
		attempts = attempts + 1
	end
end

-- Utility: approximate axis-aligned normal checks.
-- Because raycast normals may not be exact, check dot product with axis.
local function isAxis(normal, axis, tol)
	tol = tol or 0.999
	return normal:Dot(axis) >= tol
end

-- Create a neon laser segment between two points.
-- Keep parts small and anchored (visual only).
local function CreateLaserSegment(startPos, endPos, color)
	if not (startPos and endPos) then return nil end
	local segment = Instance.new("Part")
	segment.Name = "Laser"
	segment.Material = Enum.Material.Neon
	segment.CastShadow = false
	segment.Size = Vector3.new(LASER_THICKNESS, LASER_THICKNESS, (endPos - startPos).Magnitude)
	segment.Color = color
	segment.Anchored = true
	segment.CanCollide = false
	segment.CanTouch = false
	segment.CanQuery = false
	segment.Locked = true
	segment.CFrame = CFrame.new((startPos + endPos) / 2, endPos)
	local container = workspace:FindFirstChild("Lasers") or workspace
	segment.Parent = container
	return segment
end

-- Remove laser segments (optionally only by color).
local function ClearLaserSegments(color)
	local container = workspace:FindFirstChild("Lasers")
	if not container then return end
	for _, p in ipairs(container:GetChildren()) do
		if p.Name == "Laser" and (not color or p.Color == color) then
			p:Destroy()
		end
	end
	-- keep our local list consistent
	table.clear(laserSegments)
end

-- Destroy the temporary filler visuals
local function DeleteFillers()
	for _, f in ipairs(laserFillers) do
		if f and f.Parent then
			f:Destroy()
		end
	end
	table.clear(laserFillers)
end

-- Create a small filler effect (a neon cylinder that expands).
-- This is purely visual to emphasize a goal being hit.
local function CreateFiller(position, color)
	if not position then return end
	local filler = Instance.new("Part")
	filler.Anchored = true
	filler.Shape = Enum.PartType.Cylinder
	filler.Orientation = Vector3.new(0, 0, 90)
	filler.Position = position
	filler.Size = Vector3.new(0.01, 0.01, 0.01)
	filler.Color = color
	filler.Material = Enum.Material.Neon
	filler.Parent = workspace:FindFirstChild("Temp") or workspace
	local tween = TweenService:Create(filler, TweenInfo.new(FILLER_TWEEN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Size = Vector3.new(0.01, 3.7, 3.7)})
	tween:Play()
	table.insert(laserFillers, filler)
end

-- Convenience wrapper to create pair of fillers for laser + goal
local function CreateFillers(laserPart, goalPart)
	if not laserPart then return end
	CreateFiller(laserPart.Position, laserPart.Color)
	if goalPart then
		CreateFiller(goalPart.Position, goalPart.Color)
	end
end

-- Trace a single laser through the scene, handling mirrors, fixers, splitters, and goals.
local function Shoot(laser)
	if not (laser and laser:IsA("BasePart")) then return end

	-- Clean up previous segments for this laser color
	ClearLaserSegments(laser.Color)

	-- local references to speed up access
	local levelMap = LevelMap

	-- Raycast params builder
	local function buildParams()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local filterList = {}

		-- exclude the laser part and the rendered container of lasers
		table.insert(filterList, laser)
		local lasersContainer = workspace:FindFirstChild("Lasers")
		if lasersContainer then table.insert(filterList, lasersContainer) end

		-- exclude any temporary filler visuals
		for _, f in ipairs(laserFillers) do
			if f and f:IsA("BasePart") then
				table.insert(filterList, f)
			end
		end

		-- exclude level glass if present (prevents self-hit)
		if levelMap and levelMap:FindFirstChild("Glass") then
			table.insert(filterList, levelMap.Glass)
		end

		params.FilterDescendantsInstances = filterList
		return params
	end

	-- Step function: recursive ray stepping. Keeps logic limited and readable.
	local function Step(currentPos, currentDir, bounceCount, color, fromSplitter)
		if bounceCount >= MAX_BOUNCES then return end
		if not (currentPos and currentDir) then return end

		local params = buildParams()
		local direction = currentDir.Unit * MAX_LASER_DISTANCE
		local result = workspace:Raycast(currentPos, direction, params)
		local endPos = nil

		if result then
			endPos = result.Position
			local hitPart = result.Instance
			local normal = result.Normal

			-- Helper: record visual segment
			local function recordSegment()
				local seg = CreateLaserSegment(currentPos, endPos, color)
				table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = seg})
			end

			-- Tech pieces are grouped under a "Tech" parent; handle special names
			if hitPart and hitPart.Parent and hitPart.Parent.Name == "Tech" then
				if hitPart.Name == "Fixer" then
					-- Fixer flips direction on the axis most aligned with the normal.
					-- Use axis approximation for reliability.
					local newDir = currentDir
					if isAxis(normal, Vector3.new(0, 0, 1)) or isAxis(normal, Vector3.new(0, 0, -1)) then
						newDir = Vector3.new(currentDir.X, currentDir.Y, -currentDir.Z)
					elseif isAxis(normal, Vector3.new(1, 0, 0)) or isAxis(normal, Vector3.new(-1, 0, 0)) then
						newDir = Vector3.new(-currentDir.X, currentDir.Y, currentDir.Z)
					end
					recordSegment()
					Step(endPos, newDir.Unit, bounceCount + 1, color, false)

				elseif hitPart.Name == "Splitter" then
					-- Splitter spawns three rays around the original direction.
					-- Make small angular offsets using a cross vector; handle degenerate cross.
					local rightVector = currentDir:Cross(Vector3.new(0, 1, 0))
					if rightVector.Magnitude < 0.01 then
						rightVector = currentDir:Cross(Vector3.new(1, 0, 0))
					end
					rightVector = rightVector.Unit
					local splitNormals = {
						(currentDir + rightVector * 0.5).Unit,
						(currentDir - rightVector * 0.5).Unit,
						currentDir.Unit
					}
					-- Start the split a small offset away from the part to prevent immediate re-hits
					local offsetStart = hitPart.Position + currentDir.Unit * 2
					for _, nrm in ipairs(splitNormals) do
						Step(offsetStart, nrm, bounceCount + 1, color, true)
					end
					-- Draw the incoming segment only once for the splitter
					if not fromSplitter then recordSegment() end

				else
					-- Unknown tech part: treat as opaque; record segment and stop
					local segment = CreateLaserSegment(currentPos, endPos, color)
					table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
				end

			elseif hitPart and hitPart.Parent and hitPart.Parent.Name == "Mirrors" then
				-- Reflect off mirrors using the reflection formula r = v - 2*(v·n)*n
				local reflect = currentDir - (2 * currentDir:Dot(normal) * normal)
				recordSegment()
				Step(endPos, reflect.Unit, bounceCount + 1, color, false)

			else
				-- Non-tech, non-mirror hit: could be a goal.
				if hitPart and hitPart.Name == laser.Name and hitPart.Parent and hitPart.Parent.Name == "Goals" then
					-- first time this laser hits its goal -> mark and check for overall completion
					if not lasersHitGoal[laser.Name] then
						lasersHitGoal[laser.Name] = true

						-- if all lasers are hitting their goals, start the timer and animate fillers
						local allHit = true
						for _, v in ipairs((levelMap and levelMap.Lasers and levelMap.Lasers:GetChildren()) or {}) do
							if not lasersHitGoal[v.Name] then
								allHit = false
								break
							end
						end
						if allHit then
							timeOfLastHit = tick()
							for _, l in ipairs((levelMap and levelMap.Lasers and levelMap.Lasers:GetChildren()) or {}) do
								local goalPart = (levelMap and levelMap.Goals) and levelMap.Goals:FindFirstChild(l.Name)
								if l and goalPart then
									CreateFillers(l, goalPart)
								end
							end
						end
					end
				else
					-- If we were previously hitting the goal but now no longer, reset state.
					if lasersHitGoal[laser.Name] then
						lasersHitGoal[laser.Name] = false
						DeleteFillers()
					end
				end

				-- Draw the final segment to the hit point
				local segment = CreateLaserSegment(currentPos, endPos, color)
				table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
			end
		else
			-- No hit: draw a long segment to max distance
			endPos = currentPos + direction
			local segment = CreateLaserSegment(currentPos, endPos, color)
			table.insert(laserSegments, {startPos = currentPos, endPos = endPos, Part = segment})
		end
	end

	-- Start the ray from the laser's position and forward look vector
	Step(laser.Position, laser.CFrame.LookVector, 0, laser.Color, false)
end

-- Smooth camera movement between camera parts (guard for missing parts)
local function MoveCam()
	local camParts = workspace:FindFirstChild("LCamParts")
	if not camParts then return end

	local currentCam = camParts:FindFirstChild("Cam" .. tostring(Level.Value))
	local nextCam = camParts:FindFirstChild("Cam" .. tostring(Level.Value + 1))

	if not currentCam then return end
	cam.CFrame = currentCam.CFrame

	-- Transition to next camera if available, else just perform a subtle bounce
	if nextCam then
		local tween1 = TweenService:Create(cam, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = currentCam.CFrame + Vector3.new(0, 10, 0)})
		tween1:Play()
		tween1.Completed:Wait()
		local tween2 = TweenService:Create(cam, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = nextCam.CFrame + Vector3.new(0, 10, 0)})
		tween2:Play()
		tween2.Completed:Wait()
		local tween3 = TweenService:Create(cam, TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = nextCam.CFrame})
		tween3:Play()
		tween3.Completed:Wait()
	end

	Level.Value = Level.Value + 1
end

-- When the player completes a level: color lasers/goals green, animate fillers, stop the loop
local function HandleWin()
	if not LevelMap then return end

	-- color all laser visuals green
	for _, seg in ipairs((workspace:FindFirstChild("Lasers") and workspace.Lasers:GetChildren()) or {}) do
		if seg.Name == "Laser" then
			seg.Color = Color3.fromRGB(0, 255, 0)
		end
	end

	-- color lasers and goals in the level green and create fillers
	for _, laserPart in ipairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
		local goal = (LevelMap and LevelMap.Goals) and LevelMap.Goals:FindFirstChild(laserPart.Name)
		if laserPart and goal then
			laserPart.Color = Color3.fromRGB(0, 255, 0)
			goal.Color = Color3.fromRGB(0, 255, 0)
			CreateFillers(laserPart, goal)
		end
	end

	laserActive = false

	-- disconnect heartbeat connections cleanly
	for _, conn in ipairs(heartbeatConnections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(heartbeatConnections)

	-- small pause then transition camera/level
	task.wait(1)
	MoveCam()
end

-- Check if all lasers are hitting their goals and enough time has elapsed to confirm win
local function CheckForWin()
	if not LevelMap then return end
	local allHit = true
	for _, v in ipairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
		if not lasersHitGoal[v.Name] then
			allHit = false
			break
		end
	end
	if allHit and timeOfLastHit and tick() - timeOfLastHit >= WAIT_AFTER_ALL_HIT then
		HandleWin()
	end
end

-- When level changes, prepare the new level: reset visuals and start each laser's heartbeat loop
Level.Changed:Connect(function()
	LevelMap = workspace:FindFirstChild("Levels") and workspace.Levels:FindFirstChild("L" .. tostring(Level.Value))
	if not LevelMap then return end

	laserActive = true
	ClearLaserSegments()
	DeleteFillers()
	table.clear(lasersHitGoal)
	pointingAtTarget, pointingStartTime, timeOfLastHit = false, nil, nil

	-- Position camera at level start
	local camParts = workspace:FindFirstChild("LCamParts")
	if camParts then
		local startCam = camParts:FindFirstChild("Cam" .. tostring(Level.Value))
		if startCam then cam.CFrame = startCam.CFrame end
	end

	-- For each laser in the level, spawn a heartbeat loop to update its trace.
	for _, laserPart in ipairs((LevelMap and LevelMap.Lasers and LevelMap.Lasers:GetChildren()) or {}) do
		task.spawn(function()
			-- keep track of connection to allow cleanup later
			local conn = RunService.Heartbeat:Connect(function()
				if not laserActive then return end
				Shoot(laserPart)
				-- optional: allow pointing-based quick-win if you implement pointing elsewhere
				if pointingAtTarget and pointingStartTime and tick() - pointingStartTime >= WAIT_AFTER_ALL_HIT then
					HandleWin()
					pointingAtTarget, pointingStartTime = false, nil
				end
				CheckForWin()
			end)
			table.insert(heartbeatConnections, conn)
		end)
	end
end)

-- start at level 1
Level.Value = 1

-- INPUT AND MOVEMENT HANDLING
local mouse = localPlayer:GetMouse()
local selectedPart = nil

-- Utility: report whether 'part' overlaps any relevant static geometry we care about.
local function isTouchingWall(part)
	if not part then return false end
	-- using GetPartsInPart is efficient and direct for overlapping checks
	for _, otherPart in ipairs(workspace:GetPartsInPart(part)) do
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

-- Move selected part safely toward a target in small steps to avoid tunnelling.
local function MoveToSafe(part, target)
	if not (part and target) then return end
	local startPos = part.Position
	local delta = target - startPos
	local steps = 100
	local stepVec = delta / steps
	for i = 1, steps do
		local last = part.Position
		part.Position = part.Position + stepVec
		if #workspace:GetPartsInPart(part) > 0 then
			part.Position = last
			break
		end
		task.wait()
	end
end

-- Axis-aligned incremental movement with separate X/Z trials to simplify collision fixes.
local function movePart(targetPosition, part)
	if not (part and targetPosition) then return end
	local lastPos = part.Position
	-- try X
	part.Position = Vector3.new(targetPosition.X, part.Position.Y, part.Position.Z)
	if isTouchingWall(part) then
		part.Position = lastPos
	end
	lastPos = part.Position
	-- try Z
	part.Position = Vector3.new(part.Position.X, part.Position.Y, targetPosition.Z)
	if isTouchingWall(part) then
		part.Position = lastPos
	end
end

-- Fix small embedding by nudging slightly along X
local function fixGap(part)
	if not part then return end
	local wallOffset = 0.1
	if isTouchingWall(part) then
		part.Position = Vector3.new(part.Position.X + wallOffset, part.Position.Y, part.Position.Z)
	end
end

-- Play a local sound childed to this script by name
local function playSound(soundName)
	local snd = script:FindFirstChild(soundName)
	if not (snd and snd:IsA("Sound")) then return end
	local clone = snd:Clone()
	clone.Parent = workspace
	Debris:AddItem(clone, 1)
	clone:Play()
end

-- Desktop mouse drag logic; keep loop short and responsive
mouse.Button1Down:Connect(function()
	if not (LevelMap and LevelMap:FindFirstChild("Mirrors")) then return end
	local target = mouse.Target
	if not (target and target:IsDescendantOf(LevelMap:WaitForChild("Mirrors"))) then return end
	local canDrag = target:FindFirstChild("CanDrag")
	if not (canDrag and canDrag.Value) then return end

	selectedPart = target
	playSound("Click")
	-- While the mouse button is held, move the part smoothly towards the cursor
	while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) and selectedPart do
		local targetPosition = mouse.Hit.Position
		local goal = Vector3.new(targetPosition.X, selectedPart.Position.Y, targetPosition.Z)
		local pos = selectedPart.Position:Lerp(goal, 0.3)
		MoveToSafe(selectedPart, Vector3.new(pos.X, pos.Y, selectedPart.Position.Z))
		MoveToSafe(selectedPart, Vector3.new(selectedPart.Position.X, pos.Y, pos.Z))
		fixGap(selectedPart)
		task.wait()
	end
	selectedPart = nil
	playSound("Click")
end)

-- Touch handling: touch start selects, moved updates, end deselects.
UserInputService.TouchStarted:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	local target = mouse.Target
	if not (LevelMap and target and target:IsDescendantOf(LevelMap:WaitForChild("Mirrors"))) then return end
	local canDrag = target:FindFirstChild("CanDrag")
	if canDrag and canDrag.Value then
		selectedPart = target
	end
end)

UserInputService.TouchMoved:Connect(function(input, gameProcessed)
	if gameProcessed or not selectedPart then return end
	local targetPosition = mouse.Hit.Position
	local goal = Vector3.new(targetPosition.X, selectedPart.Position.Y, targetPosition.Z)
	local pos = selectedPart.Position:Lerp(goal, 0.3)
	MoveToSafe(selectedPart, Vector3.new(pos.X, pos.Y, selectedPart.Position.Z))
	MoveToSafe(selectedPart, Vector3.new(selectedPart.Position.X, pos.Y, pos.Z))
	fixGap(selectedPart)
end)

UserInputService.TouchEnded:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	selectedPart = nil
end)

-- Mobile rotation: single event binding per button to avoid repeated connections.
if UserInputService.TouchEnabled then
	local mobileGui = playerGui:FindFirstChild("Mobile")
	if mobileGui then
		local leftButton = mobileGui:FindFirstChild("Left")
		local rightButton = mobileGui:FindFirstChild("Right")

		local function rotateLoop(direction) -- direction positive rotates clockwise
			if not selectedPart then return end
			local rotating = true
			while rotating and selectedPart do
				local angleStep = direction * 1.2
				selectedPart.Orientation = selectedPart.Orientation + Vector3.new(0, angleStep, 0)
				if isTouchingWall(selectedPart) then
					selectedPart.Orientation = selectedPart.Orientation - Vector3.new(0, angleStep, 0)
				end
				task.wait()
			end
		end

		if leftButton then
			local active = false
			leftButton.MouseButton1Down:Connect(function()
				if active or not selectedPart then return end
				active = true
				task.spawn(function()
					rotateLoop(1)
					active = false
				end)
			end)
			leftButton.MouseButton1Up:Connect(function()
				active = false
			end)
		end

		if rightButton then
			local active = false
			rightButton.MouseButton1Down:Connect(function()
				if active or not selectedPart then return end
				active = true
				task.spawn(function()
					rotateLoop(-1)
					active = false
				end)
			end)
			rightButton.MouseButton1Up:Connect(function()
				active = false
			end)
		end
	end
end

-- Keyboard rotation: hold 'R' to rotate selected mirror.
do
	local rotating = false
	local rotateAmount = 2 -- degrees per step
	local rotationSpeed = 0.01

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.R and selectedPart and selectedPart:FindFirstChild("CanRotate") and selectedPart.CanRotate.Value then
			if rotating then return end
			rotating = true
			task.spawn(function()
				while rotating and selectedPart do
					selectedPart.Orientation = selectedPart.Orientation + Vector3.new(0, rotateAmount, 0)
					if isTouchingWall(selectedPart) then
						selectedPart.Orientation = selectedPart.Orientation - Vector3.new(0, rotateAmount, 0)
					end
					task.wait(rotationSpeed)
				end
			end)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.R then
			rotating = false
		end
	end)
end
