local aura_env, aura_config = aura_env, aura_env.config
local tconcat, tinsert, tsort, twipe =  table.concat, table.insert, table.sort, table.wipe
local pairs, ipairs, stformat, next, select = pairs, ipairs, string.format, next, select
local GetSpellInfo, SendChatMessage, GetUnitName, GetTime = GetSpellInfo, SendChatMessage, GetUnitName, GetTime

--[[ CONFIGURATIONS --]]

local SPEC_IDENTIFICATION_TABLE = {
    HPALA = { 53563 },
    RETPALA = { 35395 },
    PROTPALA = { 48827 },
    DISC = { 53007 }
}

local COMPROMISING_SCENARIO_TABLE = {
    INFEST_COMPROMISED = { "DISC" },
    HOLY_WRATH_COMPROMISED = { "RETPALA", "PROTPALA" },
    TANK_HEALING_COMPROMISED = { "HPALA" }
}

local COMPROMISING_SCENARIO_UI_CONFIG_TABLE = {
    INFEST_COMPROMISED = { spellIcon = 70541, order = 1 },
    HOLY_WRATH_COMPROMISED = { spellIcon = 48817, order = 2 },
    TANK_HEALING_COMPROMISED = { spellIcon = 56539, order = 3 }
}

--[[ CUSTOM OPTIONS MAPPING --]]
local ANNOUNCE_CHANNEL_CUSTOM_OPTIONS = { "NONE", "PRINT", "WHISPER", "SAY", "RAID_WARNING" }

--[[ CONSTANTS --]]

-- sample record { HPALA: { "Beacon of Light" } }
local SPEC_IDENTIFICATION_TABLE_INTERNAL = {}
for spec, spellIds in pairs(SPEC_IDENTIFICATION_TABLE) do
    local localizedSpellNames = {}
    for _, spellId in ipairs(spellIds) do
        local localizedSpellName = GetSpellInfo(spellId)
        tinsert(localizedSpellNames, localizedSpellName)
    end
    SPEC_IDENTIFICATION_TABLE_INTERNAL[spec] = localizedSpellNames
end

-- sample record { scenario: { spec: true } }
local COMPROMISING_SCENARIO_TABLE_INTERNAL = {}
for scenario, specs in pairs(COMPROMISING_SCENARIO_TABLE) do
    local specTable = {}
    for _, spec in ipairs(specs) do
        specTable[spec] = true
    end
    COMPROMISING_SCENARIO_TABLE_INTERNAL[scenario] = specTable
end

-- sample record { spellName: spec }
local SPEC_IDENTIFYING_SPELL_NAMES = {}
for spec, spellNames in pairs(SPEC_IDENTIFICATION_TABLE_INTERNAL) do
    for _, spellName in ipairs(spellNames) do
        SPEC_IDENTIFYING_SPELL_NAMES[spellName] = spec
    end
end

local COMPROMISING_SCENARIO_UI_CONFIG_TABLE_INTERNAL = {}
for scenario, uiData in pairs(COMPROMISING_SCENARIO_UI_CONFIG_TABLE) do
    COMPROMISING_SCENARIO_UI_CONFIG_TABLE_INTERNAL[scenario] = {
        spellIcon = select(3, GetSpellInfo(uiData.spellIcon)),
        order = uiData.order
    }
end

local VALK_SUMMON_SPELL_ID = 69037
local REMORSELESS_WINTER_SPELL_NAME = GetSpellInfo(68981)

--[[ CACHES and STATES --]]

-- sample record { unitName:  spec }
local playerSpecCache = {}
-- sample record { unitName: true }
local valkGrabCache = {}
-- sample record { scenario: { unitName: true } }
local raidCompromisedCache = {}

-- non-nil means valk summon has started
local valkSummonLastCastTime = nil

local remorselessWinterCount = 0
local remorselessWinterLastCastTime = nil

--[[ LOCAL FUNCTIONS --]]
local function extract_sorted_table_keys(aTable)
    local keys = {}
    for key in pairs(aTable or {}) do
        tinsert(keys, key)
    end
    tsort(keys)
    return keys
end

local function clear_caches_and_states()
    twipe(playerSpecCache)
    twipe(valkGrabCache)
    twipe(raidCompromisedCache)
    valkSummonLastCastTime = nil
    remorselessWinterCount = 0
    remorselessWinterLastCastTime = nil
end

local function announce(message)
    local announceChannel = ANNOUNCE_CHANNEL_CUSTOM_OPTIONS[aura_config.announceChannel]
    if announceChannel then
        if announceChannel == "PRINT" then
            print(message)
        elseif announceChannel ~= "NONE" then
            SendChatMessage(message, announceChannel, nil, GetUnitName("player"));
        end
    end
end

local function debug(message)
    if aura_config.debugToggle then
        SendChatMessage(message, "WHISPER", "Common", GetUnitName("player"));
    end
end

local function clear_visuals(allstates)
    for _, state in pairs(allstates) do
        state.show = false;
        state.changed = true;
    end
    debug("all states cleared")
end

local function update_ui(allstates, affectedScenarios)
    for _, scenario in ipairs(affectedScenarios) do
        local state = allstates[scenario]
        if not state then
            local uiData = COMPROMISING_SCENARIO_UI_CONFIG_TABLE_INTERNAL[scenario]
            state = { icon = uiData.spellIcon, index = uiData.order, tooltip = scenario, tooltipWrap = true }
            allstates[scenario] = state
        end
        state.show = next(raidCompromisedCache) ~= nil and next(raidCompromisedCache[scenario]) ~= nil
        state.changed = true
        state.compromisedNames = tconcat(extract_sorted_table_keys(raidCompromisedCache[scenario]), ", ")
    end
end

local function increment_remorseless_winter_count(allstates)
    if not remorselessWinterLastCastTime or ((GetTime() - remorselessWinterLastCastTime) > 60) then
        remorselessWinterCount = remorselessWinterCount + 1
        remorselessWinterLastCastTime = GetTime()
        debug(stformat("remorseless winter: %s", remorselessWinterCount))
    end

    if remorselessWinterCount == 2 then
        clear_visuals(allstates)
    end
end

local function associate_spell_caster_with_spec(casterUid, spellName)
    local unitName = GetUnitName(casterUid)
    local playerSpec = SPEC_IDENTIFYING_SPELL_NAMES[spellName]

    if playerSpec and unitName and not playerSpecCache[unitName] then
        playerSpecCache[unitName] = playerSpec
        debug(stformat("%s associated with spec %s", unitName, playerSpec))
    end
end

local function is_valk_transition(event)
    return (event == "UNIT_ENTERING_VEHICLE" or event == "UNIT_EXITING_VEHICLE")
            and valkSummonLastCastTime ~= nil
            and remorselessWinterCount == 1
end

local function evaluate_raid_effect_on_player_incapacitation(unitName)
    if not playerSpecCache[unitName] then
        return {}
    end

    local affectedScenarios = {}
    local playerSpec = playerSpecCache[unitName]
    for scenario, specs in pairs(COMPROMISING_SCENARIO_TABLE_INTERNAL) do
        if specs[playerSpec] then
            tinsert(affectedScenarios, scenario)
        end
    end
    return affectedScenarios
end

local function process_raid_compromised_cache_changes(allstates, unitName)
    local affectedScenarios = evaluate_raid_effect_on_player_incapacitation(unitName)
    for _, scenario in ipairs(affectedScenarios) do
        announce(stformat("%s - %s grabbed", scenario, unitName))
        raidCompromisedCache[scenario] = raidCompromisedCache[scenario] or {}
        raidCompromisedCache[scenario][unitName] = true
    end

    if next(affectedScenarios) ~= nil then
        update_ui(allstates, affectedScenarios)
        return true
    end
end

local function process_raid_compromised_cache_recovery(allstates, unitName)
    if raidCompromisedCache == nil or next(raidCompromisedCache) == nil then
        return
    end

    local affectedScenarios = {}
    for scenario, compromisedNames in pairs(raidCompromisedCache) do
        if compromisedNames[unitName] ~= nil then
            debug(stformat("%s - %s dropped", scenario, unitName))

            compromisedNames[unitName] = nil
            if next(compromisedNames) == nil then
                raidCompromisedCache[scenario] = nil
            end
            tinsert(affectedScenarios, scenario)
        end
    end

    if next(affectedScenarios) ~= nil then
        update_ui(allstates, affectedScenarios)
        return true
    end
end

local function process_valk_cache_changes(allstates, event, unitName)
    local valkGrabInfo = valkGrabCache[unitName]
    if event == "UNIT_EXITING_VEHICLE" and valkGrabInfo ~= nil
            and (GetTime() - valkGrabInfo.grabbedTime > 3)
            and (valkGrabInfo.droppedTime == nil) then
        --if valk grabbed detected before, and the exiting event was fired >1s after the grabbed time, then it's a real exit
        valkGrabCache[unitName].droppedTime = GetTime()
        debug(stformat("valk dropped player: %s", unitName))
        return process_raid_compromised_cache_recovery(allstates, unitName)
    elseif event == "UNIT_ENTERING_VEHICLE" and valkGrabInfo == nil then
        --testing shows a spam of both event fired when grabbed. we use both to identify a grab
        valkGrabCache[unitName] = {
            grabbedTime = GetTime(),
            droppedTime = nil
        }
        debug(stformat("valk grabbed player: %s", unitName))
        return process_raid_compromised_cache_changes(allstates, unitName)
    end
end

local function is_boss_lich_king()
    local bossName = GetUnitName("boss1")
    return bossName and bossName == "The Lich King"
end

aura_env.can_reset_caches = function(event)
    return event == "ZONE_CHANGED"
            or event == "ZONE_CHANGED_INDOORS"
            --we do not want to reset caches if player is battle ressed. Identified by active boss exists
            or (event == "PLAYER_ALIVE" and not is_boss_lich_king())
end

aura_env.is_aura_deactivated = function()
    return not is_boss_lich_king() or remorselessWinterCount > 1
end

aura_env.reset_aura = function(allstates)
    clear_caches_and_states()
    clear_visuals(allstates)
    debug("resetting aura")
end

aura_env.process_spell_cast = function(allstates, event, casterUid, spellName)
    if event == "UNIT_SPELLCAST_START" and spellName == REMORSELESS_WINTER_SPELL_NAME then
        increment_remorseless_winter_count(allstates)
    elseif valkSummonLastCastTime == nil and SPEC_IDENTIFYING_SPELL_NAMES[spellName] then
        associate_spell_caster_with_spec(casterUid, spellName)
    end
end

aura_env.process_summon = function(allstates, spellId)
    if spellId == VALK_SUMMON_SPELL_ID then
        if valkSummonLastCastTime == nil or ((GetTime() - valkSummonLastCastTime) > 5) then
            valkSummonLastCastTime = GetTime()
            twipe(valkGrabCache)
            twipe(raidCompromisedCache)
            debug("resetting valk grab caches")
        end
    end
end

aura_env.handle_vehicle_transitioning = function(allstates, event, uid)
    if is_valk_transition(event) then
        local unitName = GetUnitName(uid)
        return process_valk_cache_changes(allstates, event, unitName)
    end
end

aura_env.mock_ui = function(allstates)
    for scenario, uiData in pairs(COMPROMISING_SCENARIO_UI_CONFIG_TABLE_INTERNAL) do
        allstates[scenario] = {
            icon = uiData.spellIcon,
            index = uiData.order,
            show = true,
            changed = true,
            compromisedNames = "Test Player Name",
            tooltip = scenario,
            tooltipWrap = true
        }
    end
    return true
end
