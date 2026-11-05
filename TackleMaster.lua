-- TackleMaster: one key to fish.
--
-- Awake, the add-on's own key (an override binding, not a game key binding,
-- so the key's usual action comes back when asleep) does the next step:
-- equip the best pole in the bags, put the best lure on it, cast, reel in.
-- Going to sleep takes the weapons the pole replaced back out of the bags.
--
-- Nothing here touches Blizzard frames or functions: the game's own UI must
-- never run code tainted by this add-on.

local _, ns = ...

local POLE_SLOT, OFF_SLOT = 16, 17
local FISHING_SKILL = 356
local TICK = 0.2
-- Soft interact lets the reel find the bobber with the mouse anywhere.
-- Held only while the line is out, then put back as it was.
local SOFT_CVARS = {
	SoftTargetInteract = "3",
	SoftTargetInteractRange = "15",
	SoftTargetInteractRangeIsHard = "0",
	SoftTargetInteractArc = "2",
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

-- The next step, and the item it uses.
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
	return "cast"
end

-- Soft interact -----------------------------------------------------------

local savedCVars

local function holdSoftInteract(on)
	if on and not savedCVars then
		savedCVars = {}
		for name, value in pairs(SOFT_CVARS) do
			local old = C_CVar.GetCVar(name)
			if old ~= value then
				savedCVars[name] = old
				C_CVar.SetCVar(name, value)
			end
		end
	elseif not on and savedCVars then
		for name, old in pairs(savedCVars) do
			C_CVar.SetCVar(name, old)
		end
		savedCVars = nil
	end
end

-- Weapons -----------------------------------------------------------------

-- Remembers what the pole is about to replace. Runs before the secure
-- click, once per swap: a pole replacing a pole keeps the first weapons.
button:SetScript("PreClick", function()
	if button:GetAttribute("step") ~= "pole" or char.weapons or equippedPole() then return end
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
	local step, item = decide()
	holdSoftInteract(step == "reel")
	if not db.key then
		if current then clear() end
	elseif (step ~= current or item ~= currentItem) and not keyHeld() then
		ClearOverrideBindings(owner)
		current, currentItem = step, item
		if step == "reel" then
			SetOverrideBinding(owner, true, db.key, "INTERACTMOUSEOVER")
		elseif step == "cast" then
			SetOverrideBindingSpell(owner, true, db.key, C_Spell.GetSpellName(7620))
		elseif step == "pole" then
			button:SetAttribute("step", step)
			button:SetAttribute("macrotext", "/equip item:" .. item)
			SetOverrideBindingClick(owner, true, db.key, button:GetName())
		elseif step == "lure" then
			button:SetAttribute("step", step)
			button:SetAttribute("macrotext", "/use item:" .. item .. "\n/use " .. POLE_SLOT)
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

-- Sleep and wake ----------------------------------------------------------

local pendingSleep

local function setAwake(awake)
	char.awake = awake
	if InCombatLockdown() then
		pendingSleep = not awake
	elseif awake then
		update()
	else
		holdSoftInteract(false)
		clear()
		restoreWeapons()
	end
	refresh()
end

-- UI ----------------------------------------------------------------------

local ui = CreateFrame("Frame", "TackleMasterFrame", UIParent, "BackdropTemplate")
ui:SetSize(150, 48)
ui:SetBackdrop({
	bgFile = "Interface/Tooltips/UI-Tooltip-Background",
	edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
	edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
ui:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
ui:SetBackdropBorderColor(0.5, 0.5, 0.55)
ui:SetClampedToScreen(true)
ui:SetMovable(true)
ui:EnableMouse(true)
ui:RegisterForDrag("LeftButton")
ui:SetScript("OnDragStart", ui.StartMoving)
ui:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	db.point = { point, relPoint, x, y }
end)

local function tooltip(frame, build)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		build()
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local toggle = CreateFrame("Button", nil, ui)
toggle:SetSize(36, 36)
toggle:SetPoint("LEFT", 6, 0)
toggle:RegisterForDrag("LeftButton")
toggle:SetScript("OnDragStart", function() ui:StartMoving() end)
toggle:SetScript("OnDragStop", function() ui:GetScript("OnDragStop")(ui) end)
toggle.icon = toggle:CreateTexture(nil, "ARTWORK")
toggle.icon:SetAllPoints()
toggle.icon:SetTexture(C_Spell.GetSpellTexture(7620))
toggle.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
toggle:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square", "ADD")
toggle.zzz = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
toggle.zzz:SetPoint("TOPRIGHT", 2, 2)
toggle.zzz:SetText("Zzz")
toggle:SetScript("OnClick", function() setAwake(not char.awake) end)
tooltip(toggle, function()
	GameTooltip:AddLine("TackleMaster")
	if char.awake then
		GameTooltip:AddLine("Awake: " .. (db.key and ("|cffffffff" .. GetBindingText(db.key) .. "|r fishes") or "set a key first"), 0.4, 1, 0.4)
		GameTooltip:AddLine("Click to sleep and get your weapons back.", 0.8, 0.8, 0.8)
	else
		GameTooltip:AddLine("Asleep: the key does its usual thing.", 0.6, 0.6, 0.6)
		GameTooltip:AddLine("Click to wake.", 0.8, 0.8, 0.8)
	end
	GameTooltip:AddLine("Drag to move.", 0.5, 0.5, 0.5)
end)

-- The key: click, then press a key or mouse button. Escape cancels,
-- right-click unbinds.
local keyButton = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
keyButton:SetSize(96, 20)
keyButton:SetPoint("TOPLEFT", toggle, "TOPRIGHT", 6, 0)
keyButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

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
keyButton:HookScript("OnMouseDown", function(self, mouse)
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
tooltip(keyButton, function()
	GameTooltip:AddLine("Fishing key")
	GameTooltip:AddLine("Click, then press a key or mouse button.", 1, 1, 1)
	GameTooltip:AddLine("Right-click to unbind.", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Only taken over while awake.", 0.8, 0.8, 0.8)
end)

local function checkbox(label, field, anchor, x, tip)
	local box = CreateFrame("CheckButton", nil, ui, "UICheckButtonTemplate")
	box:SetSize(20, 20)
	box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, -2)
	box.label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	box.label:SetPoint("LEFT", box, "RIGHT", 0, 1)
	box.label:SetText(label)
	box:SetHitRectInsets(0, -box.label:GetStringWidth() - 2, 0, 0)
	box:SetScript("OnClick", function(self)
		db[field] = self:GetChecked()
		update()
	end)
	tooltip(box, function()
		GameTooltip:AddLine(label)
		GameTooltip:AddLine(tip, 1, 1, 1, true)
	end)
	return box
end

local lureBox = checkbox("Lure", "autoLure", keyButton, -4,
	"Puts your best lure on the pole when it has none.")
local poleBox = checkbox("Pole", "autoPole", keyButton, 46,
	"Equips your best pole. Your weapons come back when you sleep.")

function refresh()
	if not char then return end
	local awake = char.awake
	toggle.icon:SetDesaturated(not awake)
	toggle.icon:SetAlpha(awake and 1 or 0.6)
	toggle.zzz:SetShown(not awake)
	if keyButton.listening then
		keyButton:SetText("Press a key")
	else
		keyButton:SetText(db.key and GetBindingText(db.key) or "Set key")
	end
	lureBox:SetChecked(db.autoLure)
	poleBox:SetChecked(db.autoPole)
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
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		TackleMasterDB = TackleMasterDB or { autoLure = true, autoPole = true }
		TackleMasterCharDB = TackleMasterCharDB or {}
		db, char = TackleMasterDB, TackleMasterCharDB
		if db.point then
			ui:ClearAllPoints()
			ui:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
		else
			ui:SetPoint("CENTER", 0, -200)
		end
		ui:SetShown(not db.hidden)
		update()
		refresh()
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- Fires just before the lockdown: the key goes back to its usual
		-- action for the fight.
		holdSoftInteract(false)
		clear()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingSleep then
			pendingSleep = nil
			setAwake(false)
		end
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
	else
		db.hidden = ui:IsShown()
		ui:SetShown(not db.hidden)
	end
end
