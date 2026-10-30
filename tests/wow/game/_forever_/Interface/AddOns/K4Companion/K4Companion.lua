-- K4 Companion: each character's state for k4 on the desktop (k4-wow, wow.py reads the
-- SavedVariables file WoW writes on logout and /reload). Nothing shows in the game; /played's
-- lines are kept out of the chat when the addon asks for them.
--   K4CompanionDB["Name-Realm"] = { name, realm, class, className, race, faction, level, gold,
--     zone, subzone, xp, xpMax, rested, resting, played, playedLevel, ilvl, bagsFree, bagsTotal,
--     professions = { { name, rank, max } },
--     lockouts = { { name, reset (unix), raid, bosses, killed, diff } },
--     cooldowns = { { name, ready (unix; 0 now) } }, seen (unix) }

K4CompanionDB = K4CompanionDB or {}

local frame = CreateFrame("Frame")
local played, playedLevel
local quiet = false

-- A call that may not exist in this client (Classic, Forever and retail differ): nil then.
local function try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d, e, f, g, h, i, j, k, l = pcall(fn, ...)
	if ok then return a, b, c, d, e, f, g, h, i, j, k, l end
end

-- Profession cooldowns worth knowing about (spell ids).
local COOLDOWNS = {
	[17187] = "Transmute: Arcanite", [11479] = "Transmute: Iron to Gold", [11480] = "Transmute: Mithril to Truesilver",
	[17559] = "Transmute: Air to Fire", [17566] = "Transmute: Earth to Life", [17561] = "Transmute: Earth to Water",
	[17560] = "Transmute: Fire to Earth", [17565] = "Transmute: Life to Earth", [17562] = "Transmute: Water to Air",
	[17563] = "Transmute: Undeath to Water", [17564] = "Transmute: Water to Undeath",
	[18560] = "Mooncloth", [19566] = "Salt Shaker",
}

local function spell_cooldown(id)
	if C_Spell and C_Spell.GetSpellCooldown then
		local c = try(C_Spell.GetSpellCooldown, id)
		if c then return c.startTime, c.duration end
	end
	return try(GetSpellCooldown, id)
end

local function known(id)
	if IsPlayerSpell and try(IsPlayerSpell, id) then return true end
	return IsSpellKnown and try(IsSpellKnown, id) and true or false
end

local function bags()
	local free, total = 0, 0
	local num = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
	local slots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
	for bag = 0, 4 do free, total = free + (try(num, bag) or 0), total + (try(slots, bag) or 0) end
	return free, total
end

-- Professions with their skill (the skill lines under Professions and Secondary Skills).
local function professions()
	local out, under = {}, false
	for i = 1, (try(GetNumSkillLines) or 0) do
		local name, header, _, rank, _, _, max = try(GetSkillLineInfo, i)
		if header then under = (name == TRADE_SKILLS or name == SECONDARY_SKILLS or name == "Professions" or name == "Secondary Skills")
		elseif under and name then table.insert(out, { name = name, rank = rank or 0, max = max or 0 }) end
	end
	return out
end

local function snapshot()
	local name, realm = UnitName("player"), GetRealmName()
	if not name or not realm or name == "" then return end
	local key = name .. "-" .. realm
	local c = K4CompanionDB[key] or {}
	local className, class = UnitClass("player")
	c.name, c.realm, c.class, c.className = name, realm, class, className
	c.race, c.faction, c.level = UnitRace("player"), UnitFactionGroup("player"), UnitLevel("player")
	c.gold = GetMoney()
	c.zone, c.subzone = GetRealZoneText(), GetSubZoneText()
	c.xp, c.xpMax, c.rested = UnitXP("player"), UnitXPMax("player"), GetXPExhaustion() or 0
	c.resting = IsResting() and true or false
	if played then c.played, c.playedLevel = played, playedLevel end
	local avg, equipped = try(GetAverageItemLevel)
	if equipped or avg then c.ilvl = math.floor((equipped or avg) + 0.5) end
	c.bagsFree, c.bagsTotal = bags()
	c.professions = professions()
	c.lockouts = {}
	for i = 1, (try(GetNumSavedInstances) or 0) do
		local iname, _, reset, _, locked, _, _, raid, _, diffName, bosses, killed = try(GetSavedInstanceInfo, i)
		if iname and locked then
			table.insert(c.lockouts, { name = iname, reset = time() + (reset or 0), raid = raid and true or false,
				bosses = bosses or 0, killed = killed or 0, diff = diffName or "" })
		end
	end
	c.cooldowns = {}
	for id, label in pairs(COOLDOWNS) do
		if known(id) then
			local start, duration = spell_cooldown(id)
			local ready = 0
			if start and duration and start > 0 and duration > 1.5 then ready = math.floor(time() + start + duration - GetTime()) end
			table.insert(c.cooldowns, { name = label, ready = ready })
		end
	end
	c.seen = time()
	K4CompanionDB[key] = c
end

-- /played without the chat lines: the next time-played message is ours.
local function ask_played()
	quiet = true
	try(RequestTimePlayed)
end

local show_played = ChatFrame_DisplayTimePlayed
if type(show_played) == "function" then
	ChatFrame_DisplayTimePlayed = function(...)
		if quiet then quiet = false; return end
		return show_played(...)
	end
end

frame:SetScript("OnEvent", function(_, event, a, b)
	if event == "TIME_PLAYED_MSG" then
		played, playedLevel = a, b
	elseif event == "PLAYER_LOGIN" then
		ask_played()
		if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(300, snapshot) end
	end
	snapshot()
end)

for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "TIME_PLAYED_MSG", "PLAYER_MONEY", "PLAYER_LEVEL_UP",
	"ZONE_CHANGED_NEW_AREA", "UPDATE_INSTANCE_INFO", "PLAYER_UPDATE_RESTING", "PLAYER_LEAVING_WORLD" }) do
	pcall(frame.RegisterEvent, frame, e)
end
