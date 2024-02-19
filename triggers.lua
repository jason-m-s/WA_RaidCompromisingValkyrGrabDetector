--TSU UNIT_SPELLCAST_START, UNIT_SPELLCAST_SUCCEEDED
    --TSU COMBAT_LOG_EVENT_UNFILTERED:SPELL_SUMMON
--TSU UNIT_ENTERING_VEHICLE, UNIT_EXITING_VEHICLE
--TSU ZONE_CHANGED, ZONE_CHANGED_INDOORS, PLAYER_ALIVE

--UNIT_SPELLCAST_START, UNIT_SPELLCAST_SUCCEEDED, COMBAT_LOG_EVENT_UNFILTERED:SPELL_SUMMON, UNIT_ENTERING_VEHICLE, UNIT_EXITING_VEHICLE, ZONE_CHANGED, ZONE_CHANGED_INDOORS, PLAYER_ALIVE

function(allstates, event, ...)
    if event == "OPTIONS" then
        return aura_env.mock_ui(allstates)
    end

    if aura_env.can_reset_caches(event) then
        aura_env.reset_aura(allstates)
        return
    end

    if aura_env.is_aura_deactivated() then
        return
    end

    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
        local casterUid, spellName = ...
        aura_env.process_spell_cast(event, casterUid, spellName)
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subEvent, _, _, _, _, _, _, spellId = ...
        if subEvent == "SPELL_SUMMON" and spellId ~= nil then
            aura_env.process_summon(allstates, spellId)
        end
        return
    end

    if event == "UNIT_ENTERING_VEHICLE" or event == "UNIT_EXITING_VEHICLE" then
        local uid = ...
        return aura_env.handle_vehicle_transitioning(allstates, event, uid)
    end
end

