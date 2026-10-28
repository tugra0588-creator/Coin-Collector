-- Connected Discord GitHub
-- Coin collector: spawns coins at random ground positions, rewards quick pickups with a combo multiplier,
-- mirrors the totals to the leaderboard and saves them with DataStore so progress survives leaving the game.
-- Setup: Script in ServerScriptService. The LocalScript CoinClient handles coin visuals and the combo timer HUD.

local Players = game:GetService("Players") -- Join/leave events and character-to-player lookup
local Workspace = game:GetService("Workspace") -- Raycasts, the coin container and the synchronised server clock
local DataStoreService = game:GetService("DataStoreService") -- Persistent storage that outlives the server
local CollectionService = game:GetService("CollectionService") -- Tags let the client find coins without knowing their names
local Debris = game:GetService("Debris") -- Removes bonus coins after a delay without needing a yielding thread each

local CONFIG = {
	CoinCount = 25, -- Coins alive at the same time
	AreaCenter = Vector3.new(0, 0, 0), -- Middle of the square coins spawn in; matches a default Baseplate
	AreaSize = 120, -- Side length of that square in studs
	RaycastHeight = 200, -- Height the ground-finding ray starts from, above any terrain or building
	MaxSpawnAttempts = 8, -- Retries before falling back, since a ray can hit a player instead of the ground
	HoverHeight = 3, -- Studs a coin floats above the surface so it is reachable without jumping
	CoinSize = Vector3.new(0.6, 4, 4), -- A cylinder's axis is X, so a thin X makes a coin shape
	CoinColor = Color3.fromRGB(255, 225, 60), -- Face colour, a bright classic-Roblox yellow
	CoinRimColor = Color3.fromRGB(170, 105, 10), -- Outline and "R" colour; darker so the coin looks embossed
	CoinImageId = "", -- Optional: an uploaded coin image ("rbxassetid://123") replaces the drawn "R"
	BurstCount = 8, -- Bonus coins thrown out when the combo first reaches MaxCombo
	BurstRadius = 4, -- Studs from the player where each bonus coin starts, so it doesn't spawn inside the body
	BurstSpeed = 30, -- Horizontal launch speed in studs per second
	BurstLift = 60, -- Upward launch speed, so the coins arc through the air before landing
	BonusCoinSize = Vector3.new(0.4, 2.5, 2.5), -- Smaller than normal coins, which makes the burst look like loose change
	BonusCoinValue = 5, -- Coins awarded per bonus coin; they ignore the combo so the reward is predictable
	BonusLifetime = 8, -- Seconds before an uncollected bonus coin disappears
	RespawnDelay = 4, -- Seconds before a collected coin reappears somewhere else
	ComboWindow = 5, -- Seconds allowed between pickups before the combo ends
	MaxCombo = 5, -- Cap for the multiplier so the economy stays predictable
	CheckInterval = 0.25, -- How often expired combos are cleared; players never notice 4 Hz
	CoinTag = "Coin", -- Must match the tag the client script listens for
	DataStoreName = "CoinCollectorData", -- Changing this name starts everyone's data from scratch
	SaveRetries = 3, -- DataStore calls fail occasionally, so each one gets a few attempts
	RetryDelay = 2, -- Seconds between attempts to respect request limits
	AutosaveInterval = 60, -- Protects progress against a server crash
}

type PlayerData = {
	Coins: number,
	BestCombo: number,
	Combo: number,
	ComboExpires: number, -- Server time when the current combo ends
	Ready: boolean, -- Loading finished, so pickups are accepted
	CanSave: boolean, -- Only true when the load succeeded; prevents overwriting real data with zeros
	Dirty: boolean, -- True when there is something new to save
	Saving: boolean, -- True while a DataStore request is in flight
}

local coinStore = DataStoreService:GetDataStore(CONFIG.DataStoreName)
local rng = Random.new() -- Dedicated generator, so spawn positions don't depend on global math.random state

local function getKey(player: Player): string
	return "Player_" .. player.UserId -- UserId never changes, unlike names, so progress follows the account
end

local function createStat(parent: Instance, name: string): IntValue
	local stat = Instance.new("IntValue") -- Leaderboard columns must be Value objects
	stat.Name = name
	stat.Parent = parent
	return stat
end

local function addCoinFace(part: BasePart, face: Enum.NormalId)
	local gui = Instance.new("SurfaceGui") -- Draws UI on one flat side of the part
	gui.Face = face
	gui.CanvasSize = Vector2.new(200, 200) -- Fixed pixel canvas, so the artwork looks identical at any coin size
	gui.LightInfluence = 0 -- Ignores scene lighting, so the face stays bright in shadow
	gui.Parent = part
	local disc = Instance.new("Frame")
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = UDim2.fromScale(0.5, 0.5)
	disc.Size = UDim2.fromScale(0.92, 0.92) -- Slightly smaller than the canvas, because the outline is drawn outside the frame
	disc.BackgroundColor3 = CONFIG.CoinColor
	disc.BorderSizePixel = 0
	disc.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0) -- A 50% radius turns the square frame into a circle
	corner.Parent = disc
	local rim = Instance.new("UIStroke") -- Dark outline like the classic Roblox coin
	rim.Color = CONFIG.CoinRimColor
	rim.Thickness = 8
	rim.Parent = disc
	if CONFIG.CoinImageId ~= "" then
		local image = Instance.new("ImageLabel")
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.Image = CONFIG.CoinImageId
		image.Parent = disc
		return -- A custom image replaces the drawn logo below
	end
	local letter = Instance.new("TextLabel")
	letter.AnchorPoint = Vector2.new(0.5, 0.5)
	letter.Position = UDim2.fromScale(0.5, 0.5)
	letter.Size = UDim2.fromScale(0.7, 0.7)
	letter.BackgroundTransparency = 1
	letter.Text = "R"
	letter.Font = Enum.Font.GothamBlack -- Heavy weight is closest to the blocky Roblox logo
	letter.TextScaled = true -- Fills the label whatever the canvas size
	letter.TextColor3 = CONFIG.CoinRimColor
	letter.Rotation = -8 -- Slight tilt, like the real logo
	letter.Parent = disc
end

local function createCoinPart(size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = "Coin"
	part.Shape = Enum.PartType.Cylinder
	part.Size = size
	part.Color = CONFIG.CoinColor:Lerp(CONFIG.CoinRimColor, 0.4) -- The coin's edge is a darker gold than its face
	part.Material = Enum.Material.SmoothPlastic -- Smooth surface gives the shiny, toy-like look of the reference coin
	part.CanQuery = false -- Raycasts ignore coins, so spawn rays never land on another coin
	addCoinFace(part, Enum.NormalId.Right) -- A cylinder's flat ends are its Right and Left faces
	addCoinFace(part, Enum.NormalId.Left) -- Both sides get the artwork, since coins spin
	return part
end

local Coin = {} -- One coin: owns its part, its pickup logic and its respawn
Coin.__index = Coin

function Coin.new(folder: Folder, onCollected)
	local self = setmetatable({}, Coin)
	local part = createCoinPart(CONFIG.CoinSize)
	part.Anchored = true -- No physics cost; the client animates it visually
	part.CanCollide = false -- Players walk through it, only Touched is needed
	CollectionService:AddTag(part, CONFIG.CoinTag) -- Only pool coins are tagged, so the client never animates physics-driven bonus coins
	self.Part = part
	self.Folder = folder
	self.OnCollected = onCollected -- Callback that decides whether the pickup is valid
	self.Collected = false
	part.Touched:Connect(function(hit)
		self:OnTouched(hit)
	end)
	return self
end

function Coin:FindGroundPosition(): Vector3
	local half = CONFIG.AreaSize / 2
	for _ = 1, CONFIG.MaxSpawnAttempts do
		local origin = Vector3.new(
			CONFIG.AreaCenter.X + rng:NextNumber(-half, half),
			CONFIG.RaycastHeight,
			CONFIG.AreaCenter.Z + rng:NextNumber(-half, half)
		)
		local result = Workspace:Raycast(origin, Vector3.new(0, -CONFIG.RaycastHeight * 2, 0)) -- Direction is a vector, so its length is the ray distance
		if result then
			local model = result.Instance:FindFirstAncestorOfClass("Model")
			local hitCharacter = model and model:FindFirstChildOfClass("Humanoid")
			if not hitCharacter then
				return result.Position + Vector3.new(0, CONFIG.HoverHeight, 0) -- Surface point plus hover height
			end
		end
	end
	return CONFIG.AreaCenter + Vector3.new(0, CONFIG.HoverHeight, 0) -- Fallback keeps the coin in play even if every ray failed
end

function Coin:Spawn()
	local position = self:FindGroundPosition()
	self.Collected = false
	self.Part.Position = position
	self.Part:SetAttribute("Base", position) -- The client animates around this point, since the server part stays still
	self.Part.Parent = self.Folder -- Parented last so the client receives position and attribute together
end

function Coin:OnTouched(hit: BasePart)
	if self.Collected then
		return -- Several body parts touch in one frame; only the first may count
	end
	local player = Players:GetPlayerFromCharacter(hit.Parent) -- nil for accessories and non-player touches
	if not player then
		return
	end
	self.Collected = true -- Locked before the callback so a second player can't take the same coin
	if not self.OnCollected(player) then
		self.Collected = false -- Pickup was rejected, e.g. data still loading, so the coin stays available
		return
	end
	self.Part.Parent = nil -- Removing it from the world hides it on every client at once
	task.delay(CONFIG.RespawnDelay, function()
		self:Spawn()
	end)
end

local CoinGame = {} -- Owns players, saving and the coin pool
CoinGame.__index = CoinGame

function CoinGame.new()
	local self = setmetatable({}, CoinGame)
	self.Data = {} -- [Player] = PlayerData
	self.CoinFolder = Instance.new("Folder") -- Keeps Workspace tidy
	self.CoinFolder.Name = "Coins"
	self.CoinFolder.Parent = Workspace
	return self
end

function CoinGame:Load(player: Player)
	for attempt = 1, CONFIG.SaveRetries do
		local ok, saved = pcall(coinStore.GetAsync, coinStore, getKey(player)) -- pcall catches DataStore errors that would otherwise kill the thread
		if ok then
			return true, saved -- saved is nil for first-time players, which still counts as a successful load
		end
		warn(string.format("Load attempt %d failed for %s: %s", attempt, player.Name, tostring(saved))) -- On failure the second value is the error message
		task.wait(CONFIG.RetryDelay)
	end
	return false, nil
end

function CoinGame:Save(player: Player): boolean
	local data: PlayerData? = self.Data[player]
	if not data or not data.CanSave then
		return true -- Unloaded data must never be saved, it could overwrite real progress
	end
	if data.Saving then
		repeat
			task.wait()
		until not data.Saving -- A save is already in flight, so wait for it instead of sending a duplicate
		return true
	end
	if not data.Dirty then
		return true -- Nothing changed since the last save
	end
	data.Saving = true
	local snapshot = {Coins = data.Coins, BestCombo = data.BestCombo} -- Copied now because live values keep changing while we yield
	local saved = false
	for attempt = 1, CONFIG.SaveRetries do
		local ok, err = pcall(coinStore.UpdateAsync, coinStore, getKey(player), function()
			return snapshot -- UpdateAsync is atomic, so it is safer than SetAsync if two servers touch the same key
		end)
		if ok then
			saved = true
			break
		end
		warn(string.format("Save attempt %d failed for %s: %s", attempt, player.Name, tostring(err)))
		task.wait(CONFIG.RetryDelay)
	end
	data.Dirty = not saved or data.Coins ~= snapshot.Coins or data.BestCombo ~= snapshot.BestCombo -- Stays dirty if the save failed or more coins arrived mid-save
	data.Saving = false
	return saved
end

function CoinGame:AddCoins(player: Player, amount: number): boolean
	local data: PlayerData? = self.Data[player]
	if not data or not data.Ready then
		return false -- Pickups wait for the load, otherwise the loaded total would overwrite them
	end
	data.Coins += amount
	data.Dirty = true
	player.leaderstats.Coins.Value = data.Coins
	return true
end

function CoinGame:Burst(player: Player)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return -- The character may be respawning at the moment the combo is reached
	end
	for index = 0, CONFIG.BurstCount - 1 do
		local angle = index * (2 * math.pi / CONFIG.BurstCount) -- Equal angular steps spread the coins evenly around a full circle
		local direction = (CFrame.new(root.Position) * CFrame.Angles(0, angle, 0)).LookVector -- Rotating around Y turns the forward vector into a horizontal ring direction
		local part = createCoinPart(CONFIG.BonusCoinSize)
		part.Name = "BonusCoin"
		part.Position = root.Position + direction * CONFIG.BurstRadius
		part.Parent = self.CoinFolder
		part:SetNetworkOwner(nil) -- The server keeps simulating them, so Touched fires reliably instead of depending on a nearby client
		part:ApplyImpulse((direction * CONFIG.BurstSpeed + Vector3.new(0, CONFIG.BurstLift, 0)) * part.AssemblyMass) -- Impulse equals mass times velocity change, so the throw is identical for any coin size
		local claimed = false
		part.Touched:Connect(function(hit)
			local toucher = Players:GetPlayerFromCharacter(hit.Parent)
			if claimed or not toucher then
				return
			end
			if self:AddCoins(toucher, CONFIG.BonusCoinValue) then
				claimed = true -- Set before Destroy, because several parts of one character can touch in the same frame
				part:Destroy()
			end
		end)
		Debris:AddItem(part, CONFIG.BonusLifetime)
	end
end

function CoinGame:Collect(player: Player): boolean
	local data: PlayerData? = self.Data[player]
	if not data or not data.Ready then
		return false
	end
	local now = Workspace:GetServerTimeNow() -- Same clock the client reads, so the HUD countdown matches the server
	local previous = data.Combo
	local combo = if now <= data.ComboExpires then math.min(previous + 1, CONFIG.MaxCombo) else 1 -- A quick follow-up raises the combo, a late one restarts it
	data.Combo = combo
	data.ComboExpires = now + CONFIG.ComboWindow
	data.BestCombo = math.max(data.BestCombo, combo)
	self:AddCoins(player, combo) -- Each coin is worth the current multiplier
	player.leaderstats.BestCombo.Value = data.BestCombo
	player:SetAttribute("Combo", combo) -- Attributes replicate to the owner automatically, so no RemoteEvent is needed
	player:SetAttribute("ComboExpires", data.ComboExpires)
	if combo == CONFIG.MaxCombo and previous < CONFIG.MaxCombo then
		self:Burst(player) -- Only on the pickup that reaches the cap, not on every pickup while at the cap
	end
	return true
end

function CoinGame:ExpireCombos()
	local now = Workspace:GetServerTimeNow()
	for player, data in pairs(self.Data) do
		if data.Combo > 0 and now > data.ComboExpires then
			data.Combo = 0
			player:SetAttribute("Combo", 0) -- The HUD hides itself when it sees 0
		end
	end
end

function CoinGame:AddPlayer(player: Player)
	if self.Data[player] then
		return -- Already registered by the join event or the initial loop
	end
	local data: PlayerData = {
		Coins = 0, BestCombo = 0, Combo = 0, ComboExpires = 0,
		Ready = false, CanSave = false, Dirty = false, Saving = false,
	}
	self.Data[player] = data -- Registered before the yielding load so a second call can't start another load
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats" -- Roblox only shows a folder with exactly this name
	leaderstats.Parent = player
	local coinsStat = createStat(leaderstats, "Coins")
	local bestComboStat = createStat(leaderstats, "BestCombo")
	player:SetAttribute("ComboWindow", CONFIG.ComboWindow) -- Single source of truth for the HUD's bar length
	player:SetAttribute("Combo", 0)
	local ok, saved = self:Load(player)
	if self.Data[player] ~= data then
		return -- The player left while the data was loading
	end
	if ok then
		data.CanSave = true
		if saved then
			data.Coins = saved.Coins or 0
			data.BestCombo = saved.BestCombo or 0
		end
		coinsStat.Value = data.Coins
		bestComboStat.Value = data.BestCombo
	else
		warn("Data failed to load for " .. player.Name .. "; playing without saving to protect their stored progress")
	end
	data.Ready = true
end

function CoinGame:RemovePlayer(player: Player)
	self:Save(player) -- Yields, so the entry stays until the save finishes
	self.Data[player] = nil -- Drops the reference so the Player can be garbage collected
end

function CoinGame:Shutdown()
	local pending = 0
	for player in pairs(self.Data) do
		pending += 1
		task.spawn(function()
			self:Save(player) -- Saves run in parallel, so many players don't exhaust the shutdown window
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait() -- BindToClose allows about 30 seconds; the server must not exit mid-save
	end
end

function CoinGame:Start()
	for _ = 1, CONFIG.CoinCount do
		Coin.new(self.CoinFolder, function(player)
			return self:Collect(player)
		end):Spawn()
	end
	Players.PlayerAdded:Connect(function(player)
		self:AddPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:RemovePlayer(player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(self.AddPlayer, self, player) -- Own thread each, because loading yields
	end
	task.spawn(function()
		while true do
			task.wait(CONFIG.CheckInterval)
			self:ExpireCombos()
		end
	end)
	task.spawn(function()
		while true do
			task.wait(CONFIG.AutosaveInterval)
			for player in pairs(self.Data) do
				task.spawn(self.Save, self, player) -- Parallel saves, so one slow request doesn't delay the others
			end
		end
	end)
	game:BindToClose(function()
		self:Shutdown()
	end)
end

CoinGame.new():Start()
