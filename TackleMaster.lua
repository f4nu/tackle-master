-- TackleMaster: one key to fish.
--
-- Awake, the add-on's own key (an override binding, not a game key binding,
-- so the key's usual action comes back when asleep) does the next step:
-- equip the best pole in the bags, put the best lure on it, cast, reel in.
-- Clams and chests fished up are opened between casts, and fishing loot
-- is taken. Going to sleep takes the weapons the pole replaced back out of
-- the bags.
--
-- Nothing here touches Blizzard frames or functions: the game's own UI must
-- never run code tainted by this add-on.

local _, ns = ...

local POLE_SLOT, OFF_SLOT = 16, 17
local FISHING_SKILL = 356
local TICK = 0.2
-- Game settings held while fishing, each group put back as it was when
-- let go: on sleep, in combat, and at login after a reload or crash.
local HOLDS = {
	-- While the line is out: the bobber becomes the soft interact target,
	-- which the reel uses wherever the mouse is, with a hook above it.
	soft = {
		SoftTargetInteract = "3",
		SoftTargetInteractRange = "15",
		SoftTargetInteractRangeIsHard = "0",
		SoftTargetInteractArc = "2",
		-- The game's hook icon above the bobber.
		SoftTargetIconGameObject = "1",
		SoftTargetIconInteract = "1",
	},
	-- While awake, as options.
	mobs = { SoftTargetEnemy = "0", SoftTargetFriend = "0" },
	plates = { nameplateShowEnemies = "0", nameplateShowFriendlyPlayers = "0", nameplateShowFriendlyNpcs = "0" },
}

local DEFAULTS = {
	autoLure = true, autoPole = true, autoLoot = true, openClams = true, openChests = true,
	ignoreMobs = true, hidePlates = true, shoulderCam = true,
}

local db, char

local owner = CreateFrame("Frame")

-- Equipping a pole and putting on a lure need a secure click: the key is
-- bound to this button, its macro set to the step.
local button = CreateFrame("Button", "TackleMasterButton", UIParent, "SecureActionButtonTemplate")
button:RegisterForClicks("AnyDown", "AnyUp")
button:SetAttribute("type", "macro")
button:Hide()

local function fishingRank()
	local info = C_SkillInfo.GetSkillLineInfoByID(FISHING_SKILL)
	return info and info.rank or 0
end

local function usable(data, rank)
	return data[2] <= UnitLevel("player") and data[3] <= rank
end

local function better(a, b)
	if a[1] ~= b[1] then return a[1] > b[1] end
	return a[4] > b[4]
end

local function equippedPole()
	local id = GetInventoryItemID("player", POLE_SLOT)
	return id and ns.POLES[id] and id
end

-- Best usable item from a data list in the bags, with its data.
local function bestInBags(list)
	local rank, best, bestData = fishingRank()
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local id = C_Container.GetContainerItemID(bag, slot)
			local data = id and list[id]
			if data and usable(data, rank) and (not bestData or better(data, bestData)) then
				best, bestData = id, data
			end
		end
	end
	return best, bestData
end

local function lured()
	for _, enchant in ipairs(C_Item.GetWeaponEnchantInfo(Enum.WeaponSlot.MainHand)) do
		if enchant.hasEnchant then return true end
	end
	return false
end

local function fishing()
	local spell = select(8, UnitChannelInfo("player"))
	return spell and ns.FISHING[spell] or false
end

-- Sea containers ----------------------------------------------------------

-- Items that wouldn't open (locked, bags full) are left alone this session.
local skip, opening, lootOpened = {}, nil, 0

-- Known containers, plus any fished item that turns out to open.
local function seaKind(id)
	local known = ns.SEA[id]
	if known then return not known[2] and known[1] end
	return db.fished[id] and "chest"
end

local function containerInBags()
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local kind = info and info.hasLoot and not skip[info.itemID] and seaKind(info.itemID)
			if kind == "clam" and db.openClams or kind == "chest" and db.openChests then
				return info.itemID
			end
		end
	end
end

-- An open that left the item in the bags didn't work: stop trying it.
local function checkOpening()
	if opening and GetTime() - opening.time > 2 then
		if C_Item.GetItemCount(opening.id) >= opening.count then skip[opening.id] = true end
		opening = nil
	end
end

-- The highest fishing rank known. By ID: right after a reload spell names
-- may not be loaded yet.
local function fishingSpell()
	local best
	for id in pairs(ns.FISHING) do
		if IsPlayerSpell(id) and (not best or id > best) then best = id end
	end
	return best
end

-- The next step, and the item (or spell) it uses.
local function decide()
	if not char.awake or UnitIsDeadOrGhost("player") or IsMounted() or UnitOnTaxi("player") then
		return nil
	end
	if fishing() then return "reel" end
	local pole = equippedPole()
	if db.autoPole then
		local best, data = bestInBags(ns.POLES)
		if best and (not pole or better(data, ns.POLES[pole])) then return "pole", best end
	end
	if db.autoLure and pole and not lured() then
		local best = bestInBags(ns.LURES)
		if best then return "lure", best end
	end
	if not opening and GetNumLootItems() == 0 then
		local box = containerInBags()
		if box then return "open", box end
	end
	-- Not knowing fishing leaves the key alone.
	local spell = fishingSpell()
	return spell and "cast", spell
end

-- Held settings -----------------------------------------------------------

-- The old values live in the saved variables, so a reload while holding
-- still gets them back.
local function hold(group, on)
	local held = db.held
	if on and not held[group] then
		local old = {}
		for name, value in pairs(HOLDS[group]) do
			local was = C_CVar.GetCVar(name)
			if was and was ~= value then
				old[name] = was
				C_CVar.SetCVar(name, value)
			end
		end
		held[group] = old
	elseif not on and held[group] then
		for name, was in pairs(held[group]) do
			C_CVar.SetCVar(name, was)
		end
		held[group] = nil
	end
end

-- Shoulder camera ---------------------------------------------------------

-- While the line is out the camera zooms in and pans over the shoulder, as
-- DialogueUI does for talks. It lets go a moment after the line comes in,
-- so casting again straight away keeps the view.
local CAM_ZOOM, CAM_LINGER = 4, 2.5
local cam = CreateFrame("Frame")
local camZoom, camOutAt, camTick = nil, nil, 0
-- Zooming by hand voids the view until the line comes in. camOwn marks
-- the zooms made here.
local camVoid, camOwn = false, false

-- DialogueUI's fit: the offset that puts the character aside at a zoom.
local function shoulderFor(zoom)
	return zoom * 0.4314 + 0.1057
end

-- "Keep character centred" overrides the pan: off while it runs, as
-- DialogueUI does.
local CAM_CVARS = { CameraKeepCharacterCentered = "0", CameraReduceUnexpectedMovement = "0" }

local function camRelease()
	local held = db.held.cam
	if not held then return end
	C_CVar.SetCVar("test_cameraOverShoulder", held.shoulder)
	for name, was in pairs(held.cvars or {}) do
		C_CVar.SetCVar(name, was)
	end
	db.held.cam = nil
	cam:Hide()
	-- After a reload there is no zoom to go back to.
	if camZoom and camZoom > GetCameraZoom() + 0.1 then
		camOwn = true
		CameraZoomOut(camZoom - GetCameraZoom())
		camOwn = false
	end
	camZoom, camOutAt = nil, nil
end

local function camIn()
	camOutAt = nil
	if db.held.cam or camVoid then return end
	local held = { shoulder = C_CVar.GetCVar("test_cameraOverShoulder") or "0", cvars = {} }
	for name, value in pairs(CAM_CVARS) do
		local was = C_CVar.GetCVar(name)
		if was and was ~= value then
			held.cvars[name] = was
			C_CVar.SetCVar(name, value)
		end
	end
	db.held.cam = held
	camZoom = GetCameraZoom()
	if camZoom > CAM_ZOOM + 0.1 then
		camOwn = true
		CameraZoomIn(camZoom - CAM_ZOOM)
		camOwn = false
	end
	cam:Show()
end

local function camOut()
	camVoid = false
	if db.held.cam and not camOutAt then camOutAt = GetTime() + CAM_LINGER end
end

-- The offset follows the zoom as it glides in, so the pan is smooth.
cam:Hide()
cam:SetScript("OnUpdate", function(_, dt)
	if camOutAt and GetTime() >= camOutAt then
		if not InCombatLockdown() then camRelease() end
		return
	end
	camTick = camTick + dt
	if camTick < 0.03 then return end
	camTick = 0
	C_CVar.SetCVar("test_cameraOverShoulder", shoulderFor(GetCameraZoom()))
end)

-- A zoom by hand keeps the zoom it chose and drops the pan.
local function camManual()
	if camOwn or not (db and db.held.cam) then return end
	camVoid, camZoom = true, nil
	camRelease()
end
hooksecurefunc("CameraZoomIn", camManual)
hooksecurefunc("CameraZoomOut", camManual)

local function releaseAll()
	for group in pairs(HOLDS) do hold(group, false) end
	camRelease()
end

-- Weapons -----------------------------------------------------------------

-- Remembers what the pole is about to replace. Runs before the secure
-- click, once per swap: a pole replacing a pole keeps the first weapons.
button:SetScript("PreClick", function()
	local step = button:GetAttribute("step")
	if step == "open" and not opening then
		local id = button:GetAttribute("item")
		opening = { id = id, count = C_Item.GetItemCount(id), time = GetTime() }
		lootOpened = GetTime() + 3
	end
	if step ~= "pole" or char.weapons or equippedPole() then return end
	char.weapons = {
		main = GetInventoryItemLink("player", POLE_SLOT),
		off = GetInventoryItemLink("player", OFF_SLOT),
	}
end)

local function freeBag()
	for bag = 0, NUM_BAG_SLOTS do
		local free, family = C_Container.GetContainerNumFreeSlots(bag)
		if free > 0 and family == 0 then return bag end
	end
end

local function restoreWeapons()
	local weapons = char.weapons
	if not weapons then return end
	char.weapons = nil
	if not equippedPole() then return end
	if weapons.main then
		C_Item.EquipItemByName(weapons.main, POLE_SLOT)
	else
		local bag = freeBag()
		if bag then
			PickupInventoryItem(POLE_SLOT)
			if bag == 0 then PutItemInBackpack() else PutItemInBag(C_Container.ContainerIDToInventoryID(bag)) end
		end
	end
	if weapons.off then
		-- After the main hand, which may have been two-handed and taken
		-- the off hand slot with it.
		C_Timer.After(0.5, function()
			if not InCombatLockdown() then C_Item.EquipItemByName(weapons.off, OFF_SLOT) end
		end)
	end
end

-- Binding -----------------------------------------------------------------

local current, currentItem

local function keyHeld()
	-- IsKeyDown wants the key without its modifiers.
	local key = db.key and db.key:match("([^-]+)$") or db.key
	return key and IsKeyDown(key)
end

local function clear()
	ClearOverrideBindings(owner)
	current, currentItem = nil, nil
end

local refresh

-- Never rebinds while the key is down: the press would finish on another
-- action. The ticker tries again once it is up.
local function update()
	if InCombatLockdown() then return end
	checkOpening()
	local step, item = decide()
	hold("soft", step == "reel")
	hold("mobs", char.awake and db.ignoreMobs)
	hold("plates", char.awake and db.hidePlates)
	if step == "reel" and db.shoulderCam then camIn() else camOut() end
	if not db.key then
		if current then clear() end
	elseif (step ~= current or item ~= currentItem) and not keyHeld() then
		ClearOverrideBindings(owner)
		current, currentItem = step, item
		if step == "reel" then
			-- The soft interact target only: the bobber, never a mob under
			-- the mouse.
			SetOverrideBinding(owner, true, db.key, "INTERACTTARGET")
		elseif step == "cast" then
			button:SetAttribute("step", step)
			button:SetAttribute("type", "spell")
			button:SetAttribute("spell", item)
			SetOverrideBindingClick(owner, true, db.key, button:GetName())
		elseif step == "pole" then
			button:SetAttribute("step", step)
			button:SetAttribute("type", "macro")
			button:SetAttribute("macrotext", "/equip item:" .. item)
			SetOverrideBindingClick(owner, true, db.key, button:GetName())
		elseif step == "lure" then
			button:SetAttribute("step", step)
			button:SetAttribute("type", "macro")
			button:SetAttribute("macrotext", "/use item:" .. item .. "\n/use " .. POLE_SLOT)
			SetOverrideBindingClick(owner, true, db.key, button:GetName())
		elseif step == "open" then
			button:SetAttribute("step", step)
			button:SetAttribute("type", "macro")
			button:SetAttribute("item", item)
			button:SetAttribute("macrotext", "/use item:" .. item)
			SetOverrideBindingClick(owner, true, db.key, button:GetName())
		end
	end
	refresh()
end

local elapsed = 0
owner:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed < TICK then return end
	elapsed = 0
	if char and char.awake then update() end
end)

-- Loot --------------------------------------------------------------------

-- Takes fishing loot, and the loot of a container just opened; learns what
-- was fished, so fished containers outside the known list open too.
local function loot()
	if not char.awake then return end
	local fished = IsFishingLoot()
	if not fished and GetTime() > lootOpened then return end
	for i = GetNumLootItems(), 1, -1 do
		if fished and not InCombatLockdown() then
			local link = GetLootSlotLink(i)
			local id = link and C_Item.GetItemInfoInstant(link)
			if id then db.fished[id] = true end
		end
		if db.autoLoot then LootSlot(i) end
	end
end

-- Sleep and wake ----------------------------------------------------------

local pendingSleep

local function setAwake(awake)
	char.awake = awake
	if InCombatLockdown() then
		pendingSleep = not awake
	elseif awake then
		update()
	else
		releaseAll()
		clear()
		restoreWeapons()
	end
	refresh()
end

-- UI ----------------------------------------------------------------------
--
-- The game's own looks, from its atlases: an action button to wake and
-- sleep, and an options window in the game's seafaring dress. Only art
-- and templates are borrowed; no Blizzard function runs from here.

-- An atlas this client lacks must not raise an error.
local function setAtlas(texture, name, useSize)
	if not C_Texture.GetAtlasInfo(name) then return false end
	texture:SetAtlas(name, useSize == true)
	return true
end

local function tooltip(frame, anchor, build)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, anchor)
		build(self)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local toggleOptions

-- The button, in the action buttons' own dress. Left-click wakes
-- and sleeps, right-click opens the options, dragging moves it.
local toggle = CreateFrame("Button", "TackleMasterFrame", UIParent)
toggle:SetSize(45, 45)
-- Twice an action button: it is the only thing on screen.
toggle:SetScale(2)
toggle:SetClampedToScreen(true)
toggle:SetMovable(true)
toggle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
toggle:RegisterForDrag("LeftButton")
toggle:SetScript("OnDragStart", toggle.StartMoving)
toggle:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	db.point = { point, relPoint, x, y }
end)

toggle.slot = toggle:CreateTexture(nil, "BACKGROUND", nil, -1)
toggle.slot:SetAllPoints()
setAtlas(toggle.slot, "UI-HUD-ActionBar-IconFrame-Background")
toggle.icon = toggle:CreateTexture(nil, "BACKGROUND")
toggle.icon:SetAllPoints()
toggle.icon:SetTexture(C_Spell.GetSpellTexture(7620))
local mask = toggle:CreateMaskTexture()
mask:SetPoint("CENTER", toggle.icon)
if setAtlas(mask, "UI-HUD-ActionBar-IconFrame-Mask", true) then toggle.icon:AddMaskTexture(mask) end

-- Frame, pressed and mouseover art, laid out as on the game's buttons.
local function buttonArt(name, set, get)
	if not C_Texture.GetAtlasInfo(name) then return end
	set(toggle, name)
	local tex = get(toggle)
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT")
	tex:SetSize(46, 45)
end
buttonArt("UI-HUD-ActionBar-IconFrame", toggle.SetNormalAtlas, toggle.GetNormalTexture)
buttonArt("UI-HUD-ActionBar-IconFrame-Down", toggle.SetPushedAtlas, toggle.GetPushedTexture)
-- Hovering brightens the icon itself, under the same mask: the game's
-- square mouseover glow sits a pixel off the bevelled frame, and at twice
-- the size it shows.
toggle:SetHighlightTexture(C_Spell.GetSpellTexture(7620), "ADD")
toggle.glow = toggle:GetHighlightTexture()
toggle.glow:ClearAllPoints()
toggle.glow:SetAllPoints(toggle.icon)
toggle.glow:SetAlpha(0.35)
if toggle.icon:GetNumMaskTextures() > 0 then toggle.glow:AddMaskTexture(mask) end

-- Awake: the frame itself turns gold (a separate rim texture sat off the
-- bevel). Asleep: the icon greys out and dozes under the
-- player frame's own floating Zzz.

local zzz = toggle:CreateTexture(nil, "OVERLAY", nil, 2)
if setAtlas(zzz, "UI-HUD-UnitFrame-Player-Rest-Flipbook") then
	zzz:SetSize(30, 30)
	zzz:SetPoint("CENTER", toggle, "TOPLEFT", 14, -14)
	local anim = toggle:CreateAnimationGroup()
	anim:SetLooping("REPEAT")
	local flip = anim:CreateAnimation("FlipBook")
	flip:SetTarget(zzz)
	flip:SetFlipBookRows(7)
	flip:SetFlipBookColumns(6)
	flip:SetFlipBookFrames(42)
	flip:SetDuration(1.5)
	flip:SetSmoothing("NONE")
	toggle.sleepAnim = anim
else
	zzz = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	zzz:SetPoint("TOPLEFT", 5, -4)
	zzz:SetText("Zzz")
end
toggle.zzz = zzz

-- The key, small, centred along the bottom.
-- On a half-scale layer, so the button's size doesn't blow the text up.
local keyLayer = CreateFrame("Frame", nil, toggle)
keyLayer:SetScale(0.5)
keyLayer:SetAllPoints()
keyLayer:SetFrameLevel(toggle:GetFrameLevel() + 5)
toggle.key = keyLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
toggle.key:SetSize(76, 10)
toggle.key:SetPoint("BOTTOM", 0, 10)
toggle.key:SetJustifyH("CENTER")

toggle:SetScript("OnClick", function(_, mouse)
	if mouse == "RightButton" then
		toggleOptions()
	else
		setAwake(not char.awake)
		PlaySound(char.awake and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
	end
end)
tooltip(toggle, "ANCHOR_TOP", function()
	GameTooltip:AddLine("TackleMaster")
	if char.awake then
		GameTooltip:AddLine("Awake: " .. (db.key and ("|cffffffff" .. GetBindingText(db.key) .. "|r fishes") or "set a key in the options"), 0.4, 1, 0.4)
		GameTooltip:AddLine("Left-click to sleep and get your weapons back.", 0.8, 0.8, 0.8)
	else
		GameTooltip:AddLine("Asleep: the key does its usual thing.", 0.6, 0.6, 0.6)
		GameTooltip:AddLine("Left-click to wake.", 0.8, 0.8, 0.8)
	end
	GameTooltip:AddLine("Right-click for options.", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Drag to move.", 0.5, 0.5, 0.5)
end)

-- Options window ----------------------------------------------------------
--
-- A fisherman's card. The dress is the game's own nautical frame kit, the
-- one its player-choice window wears at sea: weathered planks lashed with
-- rope, barnacles, a starfish, a crab in the corner; inside, a sea-stained
-- parchment with the title on a scroll across the top plank. The options
-- are written on the parchment in the kit's ink.

local WIDTH = 260
local LEFT, RIGHT = 30, 30
local INNER = WIDTH - LEFT - RIGHT
local PLANK = 17
local INK = { 0.192, 0.051, 0.008 }
local INK_SOFT = { 0.36, 0.21, 0.07 }
local PALE_SOFT = { 0.86, 0.82, 0.72 }

local options = CreateFrame("Frame", "TackleMasterOptions", UIParent)
options:SetWidth(WIDTH)
options:SetFrameStrata("DIALOG")
options:SetClampedToScreen(true)
options:SetClampRectInsets(0, 3, 3, 0)
options:EnableMouse(true)
options:Hide()
-- Dragged anywhere on the window; once moved it stays where it was put.
options:SetMovable(true)
options:SetDontSavePosition(true)
options:RegisterForDrag("LeftButton")
local function dragStart()
	options:StartMoving()
end
local function dragStop()
	options:StopMovingOrSizing()
	local point, _, relPoint, x, y = options:GetPoint()
	db.optionsPoint = { point, relPoint, x, y }
	local cx = options:GetCenter()
	options.side = cx and cx > UIParent:GetWidth() / 2 and "left" or "right"
end
options:SetScript("OnDragStart", dragStart)
options:SetScript("OnDragStop", dragStop)

-- The controls cover most of the card: a drag on them moves the window.
local function draggable(frame)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", dragStart)
	frame:SetScript("OnDragStop", dragStop)
end

-- The parchment, the planks over its edges, the ribbon over the top
-- plank. Returns the frame above the planks, for the close button.
local function dress(frame, title)
	local card = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
	card:SetPoint("TOPLEFT", 6, -6)
	card:SetPoint("BOTTOMRIGHT", -6, 6)
	if not setAtlas(card, "UI-Frame-Marine-CardParchment") then
		card:SetColorTexture(0.78, 0.7, 0.52)
	end

	-- The kit's slices are cut for a window three times this size: on a
	-- half-scale layer the planks come out 17 pixels wide.
	local border = CreateFrame("Frame", nil, frame)
	border:SetScale(0.55)
	border:SetPoint("TOPLEFT")
	border:SetPoint("BOTTOMRIGHT")
	border:SetFrameLevel(frame:GetFrameLevel() + 5)
	local function corner(name, point)
		local tex = border:CreateTexture(nil, "OVERLAY")
		setAtlas(tex, name, true)
		tex:SetPoint(point)
		return tex
	end
	local function edge(name, vertical, point, from, fromPoint, point2, to, toPoint)
		local tex = border:CreateTexture(nil, "OVERLAY")
		if vertical then tex:SetVertTile(true) else tex:SetHorizTile(true) end
		setAtlas(tex, name, true)
		tex:SetPoint(point, from, fromPoint)
		tex:SetPoint(point2, to, toPoint)
	end
	local tl = corner("Marine-NineSlice-CornerTopLeft", "TOPLEFT")
	local tr = corner("Marine-NineSlice-CornerTopRight", "TOPRIGHT")
	local bl = corner("Marine-NineSlice-CornerBottomLeft", "BOTTOMLEFT")
	local br = corner("Marine-NineSlice-CornerBottomRight", "BOTTOMRIGHT")
	edge("_Marine-NineSlice-EdgeTop", false, "TOPLEFT", tl, "TOPRIGHT", "TOPRIGHT", tr, "TOPLEFT")
	edge("_Marine-NineSlice-EdgeBottom", false, "BOTTOMLEFT", bl, "BOTTOMRIGHT", "BOTTOMRIGHT", br, "BOTTOMLEFT")
	edge("!Marine-NineSlice-EdgeLeft", true, "TOPLEFT", tl, "BOTTOMLEFT", "BOTTOMLEFT", bl, "TOPLEFT")
	edge("!Marine-NineSlice-EdgeRight", true, "TOPRIGHT", tr, "BOTTOMRIGHT", "BOTTOMRIGHT", br, "TOPRIGHT")

	local band = CreateFrame("Frame", nil, frame)
	band:SetAllPoints()
	band:SetFrameLevel(border:GetFrameLevel() + 1)
	local ribbon = band:CreateTexture(nil, "ARTWORK")
	ribbon:SetSize(169, 50)
	ribbon:SetPoint("TOP", 0, 1)
	setAtlas(ribbon, "UI-Frame-Marine-Ribbon")
	local text = band:CreateFontString(nil, "OVERLAY", "GameFontBlackMedium")
	text:SetPoint("CENTER", ribbon, "CENTER", 13, 1)
	text:SetTextColor(unpack(INK))
	text:SetText(title)
	local icon = band:CreateTexture(nil, "OVERLAY")
	icon:SetSize(22, 22)
	icon:SetPoint("RIGHT", text, "LEFT", -4, 0)
	icon:SetTexture("Interface/AddOns/TackleMaster/Media/icon")
	return band
end

local band = dress(options, "TackleMaster")
local closeRing = band:CreateTexture(nil, "ARTWORK")
setAtlas(closeRing, "UI-Frame-Marine-ExitButtonBorder", true)
closeRing:SetPoint("TOPRIGHT", 3, 3)
local close = CreateFrame("Button", "TackleMasterOptionsClose", band, "UIPanelCloseButton")
close:SetSize(24, 24)
close:SetPoint("CENTER", closeRing)
close:SetScript("OnClick", function() options:Hide() end)

-- Tooltips sit beside the window, on the side away from the button.
local function optionTip(frame, build)
	tooltip(frame, "ANCHOR_NONE", function()
		if options.side == "left" then
			GameTooltip:SetPoint("TOPRIGHT", options, "TOPLEFT", -12, 16)
		else
			GameTooltip:SetPoint("TOPLEFT", options, "TOPRIGHT", 12, 16)
		end
		build()
	end)
end

local y = -50

-- A section's name, on the kit's green band.
local function header(title)
	local strip = options:CreateTexture(nil, "ARTWORK")
	strip:SetSize(INNER + 10, 20)
	strip:SetPoint("TOPLEFT", LEFT - 5, y)
	if not setAtlas(strip, "UI-Frame-Marine-Subtitle") then
		strip:SetColorTexture(0.1, 0.35, 0.25, 0.7)
	end
	local text = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("CENTER", strip)
	text:SetText(title)
	y = y - 23
end

header("Fishing key")

-- The key, on a rope-framed plate next to the fishing icon, the way the
-- action button shows it. Click, then press a key or mouse button.
-- Escape cancels, right-click unbinds.
local PLATE_W, PLATE_H = 160, 54
local keyButton = CreateFrame("Button", nil, options)
keyButton:SetSize(PLATE_W, PLATE_H)
keyButton:SetPoint("TOP", 0, y)
keyButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
draggable(keyButton)
y = y - PLATE_H

-- Dark water inside the plate, trimmed round at the corners like the
-- plate itself.
local fill = keyButton:CreateTexture(nil, "BACKGROUND")
fill:SetPoint("TOPLEFT", 4, -4)
fill:SetPoint("BOTTOMRIGHT", -4, 4)
if not setAtlas(fill, "UI-Frame-Marine-BackgroundTile") then
	fill:SetColorTexture(0.04, 0.08, 0.08)
end
local fillMask = keyButton:CreateMaskTexture()
fillMask:SetAllPoints(fill)
local trimmed = setAtlas(fillMask, "UI-Frame-IconMask")
local function trim(tex)
	if trimmed then tex:AddMaskTexture(fillMask) end
end
trim(fill)
-- Lit while listening for the key.
local glow = keyButton:CreateTexture(nil, "BORDER")
glow:SetAllPoints(fill)
glow:SetColorTexture(1, 0.82, 0, 0.25)
glow:Hide()
trim(glow)
local pulse = keyButton:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetTarget(glow)
fade:SetFromAlpha(0.4)
fade:SetToAlpha(1)
fade:SetDuration(0.7)
-- Brighter under the mouse.
local hover = keyButton:CreateTexture(nil, "BORDER", nil, 1)
hover:SetAllPoints(fill)
hover:SetColorTexture(1, 0.9, 0.6, 0.12)
hover:Hide()
trim(hover)
local plate = keyButton:CreateTexture(nil, "ARTWORK")
plate:SetAllPoints()
setAtlas(plate, "UI-Frame-Marine-Portrait")
keyButton.icon = keyButton:CreateTexture(nil, "ARTWORK", nil, 1)
keyButton.icon:SetSize(30, 30)
keyButton.icon:SetPoint("LEFT", 11, 0)
keyButton.icon:SetTexture(C_Spell.GetSpellTexture(7620))
local iconMask = keyButton:CreateMaskTexture()
iconMask:SetAllPoints(keyButton.icon)
if setAtlas(iconMask, "UI-HUD-ActionBar-IconFrame-Mask") then keyButton.icon:AddMaskTexture(iconMask) end
keyButton.text = keyButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
keyButton.text:SetPoint("LEFT", keyButton.icon, "RIGHT", 8, 0)
keyButton.text:SetWidth(PLATE_W - 11 - 30 - 8 - 8)
keyButton.text:SetJustifyH("LEFT")
keyButton.text:SetWordWrap(true)
keyButton.text:SetMaxLines(2)
-- How to, under the plate.
keyButton.hint = options:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
keyButton.hint:SetPoint("TOP", keyButton, "BOTTOM", 0, -3)
keyButton.hint:SetJustifyH("CENTER")
keyButton.hint:SetTextColor(unpack(INK_SOFT))
y = y - 34

local function stopListening()
	keyButton.listening = false
	keyButton:EnableKeyboard(false)
	refresh()
end

local function setKey(key)
	if InCombatLockdown() then return end
	clear()
	db.key = key
	stopListening()
	update()
end

local MODIFIERS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, UNKNOWN = true }
local MOUSE = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local function withModifiers(key)
	return (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
		.. (IsShiftKeyDown() and "SHIFT-" or "") .. key
end

keyButton:SetScript("OnKeyDown", function(self, key)
	if not self.listening or MODIFIERS[key] then return end
	if key == "ESCAPE" then stopListening() else setKey(withModifiers(key)) end
end)
-- Setting OnKeyDown turns the keyboard on, which would take every key
-- while the window is open: only on while listening.
keyButton:EnableKeyboard(false)
keyButton:SetScript("OnMouseDown", function(self, mouse)
	if self.listening and MOUSE[mouse] then setKey(withModifiers(MOUSE[mouse])) end
end)
keyButton:SetScript("OnClick", function(self, mouse)
	if InCombatLockdown() then return end
	if mouse == "RightButton" then
		setKey(nil)
	elseif not self.listening then
		self.listening = true
		self:EnableKeyboard(true)
		self:SetPropagateKeyboardInput(false)
		refresh()
	end
end)
keyButton:SetScript("OnHide", stopListening)
optionTip(keyButton, function()
	GameTooltip:AddLine("Fishing key")
	GameTooltip:AddLine("Click, then press a key or mouse button.", 1, 1, 1)
	GameTooltip:AddLine("Right-click to unbind.", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Only taken over while awake.", 0.8, 0.8, 0.8)
end)
keyButton:HookScript("OnEnter", function() hover:Show() end)
keyButton:HookScript("OnLeave", function() hover:Hide() end)

local boxes = {}

-- An option on a row of its own: the box, its name, a few words on what
-- it does. The whole row takes the click. The parchment darkens towards
-- the bottom: the last rows are written in white.
local function row(label, field, tip, note, pale)
	local box = CreateFrame("CheckButton", nil, options)
	box:SetSize(INNER + 6, 22)
	box:SetPoint("TOPLEFT", LEFT - 3, y)
	box:SetNormalTexture("Interface/Buttons/UI-CheckBox-Up")
	box:SetPushedTexture("Interface/Buttons/UI-CheckBox-Down")
	box:SetCheckedTexture("Interface/Buttons/UI-CheckBox-Check")
	box:SetDisabledCheckedTexture("Interface/Buttons/UI-CheckBox-Check-Disabled")
	for _, tex in ipairs({ box:GetNormalTexture(), box:GetPushedTexture(), box:GetCheckedTexture(), box:GetDisabledCheckedTexture() }) do
		tex:ClearAllPoints()
		tex:SetPoint("LEFT", 3, 0)
		tex:SetSize(22, 22)
	end
	-- An ink wash under the mouse.
	local wash = box:CreateTexture(nil, "BACKGROUND")
	wash:SetAllPoints()
	wash:SetColorTexture(0.24, 0.14, 0.04, 0.12)
	wash:Hide()
	local text = box:CreateFontString(nil, "OVERLAY", pale and "GameFontHighlight" or "GameFontBlack")
	text:SetPoint("LEFT", 29, 0)
	if not pale then text:SetTextColor(unpack(INK)) end
	text:SetText(label)
	local words = box:CreateFontString(nil, "OVERLAY", pale and "GameFontHighlightSmall" or "GameFontBlackSmall")
	words:SetPoint("LEFT", text, "RIGHT", 7, -1)
	words:SetTextColor(unpack(pale and PALE_SOFT or INK_SOFT))
	words:SetText(note)
	box.field = field
	box:SetScript("OnClick", function(self)
		local on = self:GetChecked()
		PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		db[field] = on
		update()
	end)
	optionTip(box, function()
		GameTooltip:AddLine(label)
		GameTooltip:AddLine(tip, 1, 1, 1, true)
	end)
	box:HookScript("OnEnter", function() wash:Show() end)
	box:HookScript("OnLeave", function() wash:Hide() end)
	draggable(box)
	boxes[#boxes + 1] = box
	y = y - 22
end

header("Automatic")
row("Lure", "autoLure", "Puts your best lure on the pole when it has none.", "best lure on the pole")
row("Pole", "autoPole", "Equips your best pole. Your weapons come back when you sleep.", "best pole in the bags")
row("Loot", "autoLoot", "Takes everything you fish up, and what's in the clams and chests it opens.", "takes what you fish up")
y = y - 6
header("Open")
row("Clams", "openClams", "Opens fished-up clams between casts.", "opened between casts")
row("Chests", "openChests", "Opens fished-up crates, chests, trunks and bottles between casts. Locked ones are left alone.", "crates, trunks and bottles")
y = y - 6
header("While fishing")
row("No mobs", "ignoreMobs", "While awake, mobs and NPCs aren't soft-targeted. Back as it was when you sleep.", "never soft-targeted", true)
row("No plates", "hidePlates", "While awake, nameplates are hidden. Back as it was when you sleep, and during fights.", "nameplates hidden", true)
row("Shoulder", "shoulderCam", "While the line is out, the camera zooms in over your shoulder. Back as it was after the catch, or as soon as you zoom yourself.", "camera closes in", true)
options:SetHeight(-y + 10 + PLANK)

-- Escape closes the window through a binding held while it is open. The
-- window takes no keyboard: keys passed on from an add-on's handler reach
-- the game tainted, and the fishing key's secure click is then blocked.
-- Bindings can't change in combat, so Escape is the game's there.
local function escapeBinding()
	if InCombatLockdown() then return end
	ClearOverrideBindings(options)
	if options:IsShown() then
		SetOverrideBindingClick(options, true, "ESCAPE", close:GetName())
	end
end

options:SetScript("OnShow", function(self)
	escapeBinding()
	PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
	refresh()
end)
options:SetScript("OnHide", function(self)
	escapeBinding()
	PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
end)

-- Opens where it was last dragged, or beside the button, towards the
-- middle of the screen.
function toggleOptions()
	if options:IsShown() then
		options:Hide()
		return
	end
	options:ClearAllPoints()
	local saved = db.optionsPoint
	if saved then
		options:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
		options:Show()
		local x = options:GetCenter()
		options.side = x and x > UIParent:GetWidth() / 2 and "left" or "right"
		return
	end
	local x = toggle:GetCenter()
	options.side = x and x > UIParent:GetWidth() / 2 and "left" or "right"
	if options.side == "left" then
		options:SetPoint("RIGHT", toggle, "LEFT", -12, 0)
	else
		options:SetPoint("LEFT", toggle, "RIGHT", 12, 0)
	end
	options:Show()
end

-- The plate's type steps down for a long key, two lines at most.
local function fitKey(shown)
	local text = keyButton.text
	if text.shown == shown then return end
	text.shown = shown
	text:SetFontObject("GameFontHighlightMedium")
	if text:IsTruncated() then text:SetFontObject("GameFontHighlight") end
	if text:IsTruncated() then text:SetFontObject("GameFontHighlightSmall") end
end

function refresh()
	if not char then return end
	local awake = char.awake
	toggle.icon:SetDesaturated(not awake)
	toggle.glow:SetDesaturated(not awake)
	toggle.icon:SetAlpha(awake and 1 or 0.5)
	if toggle:GetNormalTexture() then
		if awake then
			toggle:GetNormalTexture():SetVertexColor(1, 0.8, 0.25)
		else
			toggle:GetNormalTexture():SetVertexColor(1, 1, 1)
		end
	end
	toggle.zzz:SetShown(not awake)
	if toggle.sleepAnim then
		if awake then
			toggle.sleepAnim:Stop()
		elseif not toggle.sleepAnim:IsPlaying() then
			toggle.sleepAnim:Play()
		end
	end
	local shade = awake and 1 or 0.6
	toggle.key:SetText(db.key and GetBindingText(db.key, 1) or "")
	toggle.key:SetTextColor(shade, shade, shade)
	local text, hint = keyButton.text
	if keyButton.listening then
		text:SetText("Press a key...")
		text:SetTextColor(1, 0.82, 0)
		hint = "Any key or mouse button.\nEscape cancels."
	elseif db.key then
		text:SetText(GetBindingText(db.key))
		text:SetTextColor(1, 1, 1)
		hint = "Click, then press a key or mouse button.\nRight-click to unbind."
	else
		text:SetText("Set a key")
		text:SetTextColor(0.6, 0.6, 0.6)
		hint = "Click, then press a key or mouse button."
	end
	fitKey(text:GetText())
	keyButton.hint:SetText(hint)
	if keyButton.listening then
		glow:Show()
		if not pulse:IsPlaying() then pulse:Play() end
	else
		glow:Hide()
		if pulse:IsPlaying() then pulse:Stop() end
	end
	for _, box in ipairs(boxes) do
		box:SetChecked(db[box.field])
	end
end

-- Events ------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("LOOT_READY")
events:RegisterEvent("LOOT_CLOSED")
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		TackleMasterDB = TackleMasterDB or {}
		TackleMasterCharDB = TackleMasterCharDB or {}
		db, char = TackleMasterDB, TackleMasterCharDB
		for field, value in pairs(DEFAULTS) do
			if db[field] == nil then db[field] = value end
		end
		db.fished = db.fished or {}
		db.held = db.held or {}
		releaseAll()
		toggle:ClearAllPoints()
		if db.point then
			toggle:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
		else
			toggle:SetPoint("CENTER", 0, -200)
		end
		toggle:SetShown(not db.hidden)
		update()
		refresh()
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- Fires just before the lockdown: the key and the settings go back
		-- to normal for the fight.
		releaseAll()
		clear()
		ClearOverrideBindings(options)
	elseif event == "LOOT_READY" then
		loot()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingSleep then
			pendingSleep = nil
			setAwake(false)
		end
		escapeBinding()
		update()
	elseif char and char.awake then
		update()
	end
end)

SLASH_TACKLEMASTER1 = "/tm"
SLASH_TACKLEMASTER2 = "/tacklemaster"
SlashCmdList.TACKLEMASTER = function(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	if msg == "wake" or msg == "sleep" then
		setAwake(msg == "wake")
	elseif msg == "toggle" then
		setAwake(not char.awake)
	elseif msg == "options" then
		toggleOptions()
	else
		db.hidden = toggle:IsShown()
		toggle:SetShown(not db.hidden)
	end
end
