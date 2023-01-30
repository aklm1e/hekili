if UnitClassBase( 'player' ) ~= 'DRUID' then return end

local addon, ns = ...
local Hekili = _G[ addon ]
local class, state = Hekili.Class, Hekili.State

local FindUnitDebuffByID = ns.FindUnitDebuffByID

local spec = Hekili:NewSpecialization( 11 )

-- Idols
spec:RegisterGear( "idol_of_worship", 39757)
spec:RegisterGear( "idol_of_the_ravenous_beast", 40713)

-- Sets
spec:RegisterGear( "tier7", 39557, 39553, 39555, 39554, 39556, 40472, 40473, 40493, 40471, 40494 )
spec:RegisterGear( "tier8", 46260, 46262, 46265, 46267, 46269, 46158, 46161, 46160, 46159, 46157 )
spec:RegisterGear( "tier9", 48799, 48800, 48801, 48802, 48803, 48212, 48211, 48210, 48209, 48208 )
spec:RegisterGear( "tier10", 51140, 51142, 51143, 51144, 51141, 51299, 51297, 51296, 51295, 51298 )

-- Berserk tracker
local encounter_berserk_count = 0

-- Glyph of Shred helper
local tracked_rips = {}
Hekili.TR = tracked_rips;

local function NewRip( target )
    tracked_rips[ target ] = {
        extension = 0,
        applications = 0
    }
end

local function RipShred( target )
    if not tracked_rips[ target ] then
        NewRip( target )
    end
    if tracked_rips[ target ].applications < 3 then
        tracked_rips[ target ].extension = tracked_rips[ target ].extension + 2
        tracked_rips[ target ].applications = tracked_rips[ target ].applications + 1
    end
end

local function RemoveRip( target )
    tracked_rips[ target ] = nil
end

local function GetTrackedRip( target )
    if not tracked_rips[ target ] then
        NewRip( target )
    end
    return tracked_rips[ target ]
end


-- Combat log handlers
local attack_events = {
    SPELL_CAST_SUCCESS = true
}

local application_events = {
    SPELL_AURA_APPLIED      = true,
    SPELL_AURA_APPLIED_DOSE = true,
    SPELL_AURA_REFRESH      = true,
}

local removal_events = {
    SPELL_AURA_REMOVED      = true,
    SPELL_AURA_BROKEN       = true,
    SPELL_AURA_BROKEN_SPELL = true,
}

local death_events = {
    UNIT_DIED               = true,
    UNIT_DESTROYED          = true,
    UNIT_DISSIPATES         = true,
    PARTY_KILL              = true,
    SPELL_INSTAKILL         = true,
}

spec:RegisterCombatLogEvent( function( _, subtype, _, sourceGUID, sourceName, _, _, destGUID, destName, destFlags, _, spellID, spellName )
    if sourceGUID ~= state.GUID then
        return
    end

    if state.glyph.shred.enabled then
        if attack_events[subtype] then
            -- Track rip time extension from Glyph of Rip
            local rip = FindUnitDebuffByID( "target", 49800 )
            if rip and spellID == 48572 then
                RipShred( destGUID )
            end

            -- Track berserk usage
            if state.encounterDifficulty > 0 and spellID == 50334 then
                encounter_berserk_count = encounter_berserk_count + 1
            end
        end

        if application_events[subtype] then
            -- Remove previously tracked rip
            if spellID == 49800 then
                RemoveRip( destGUID )
            end
        end

        if removal_events[subtype] then
            -- Remove previously tracked rip
            if spellID == 49800 then
                RemoveRip( destGUID )
            end
        end

        if death_events[subtype] then
            -- Remove previously tracked rip
            if spellID == 49800 then
                RemoveRip( destGUID )
            end
        end
    end
end, false )

spec:RegisterHook( "UNIT_ELIMINATED", function( guid )
    RemoveRip( guid )
end )

local LastFinisherCp = 0
local LastSeenCp = 0
local CurrentCp = 0
local DruidFinishers = {
    [52610] = true,
    [48577] = true,
    [49800] = true,
    [49802] = true
}

spec:RegisterUnitEvent( "UNIT_SPELLCAST_SUCCEEDED", "player", "target", function(event, unit, _, spellID )
    if DruidFinishers[spellID] then
        LastSeenCp = GetComboPoints("player", "target")
    end
end)

spec:RegisterUnitEvent( "UNIT_POWER_UPDATE", "player", "COMBO_POINTS", function(event, unit)
    CurrentCp = GetComboPoints("player", "target")
    if CurrentCp == 0 and LastSeenCp > 0 then
        LastFinisherCp = LastSeenCp
    end
end)

spec:RegisterStateTable( "rip_tracker", setmetatable( {
    cache = {},
    reset = function( t )
        table.wipe(t.cache)
    end
    }, {
    __index = function( t, k )
        if not t.cache[k] then
            local tr = GetTrackedRip( k )
            if tr then
                t.cache[k] = { extension = tr.extension }
            end
        end
        return t.cache[k]
    end
}))

local lastfinishercp = nil
spec:RegisterStateExpr("last_finisher_cp", function()
    return lastfinishercp
end)

spec:RegisterStateFunction("set_last_finisher_cp", function(val)
    lastfinishercp = val
end)

local last_seen_encounterDifficulty = 0
local predatorsswiftness_spell_assigned = false
local rip_cp = 5 -- TODO: Implement rip CP toggle
local bite_cp = 5 -- TODO: Implement bite CP toggle
local use_rake = true -- TODO: Implement rake toggle
local ready_to_shift = false
local ready_to_gift = false
local do_gift_of_the_wild = false
local do_cat_form = false
local do_bear_form = false
spec:RegisterHook( "reset_precast", function()
    rip_tracker:reset()
    set_last_finisher_cp(LastFinisherCp)

    if IsCurrentSpell( class.abilities.maul.id ) then
        start_maul()
        Hekili:Debug( "Starting Maul, next swing in %.2f...", buff.maul.remains)
    end

    if not predatorsswiftness_spell_assigned then
        class.abilityList.predatorsswiftness_spell = "|cff00ccff[Assigned Predator's Swiftness Spell]|r"
        class.abilities.predatorsswiftness_spell = class.abilities[ settings.predatorsswiftness_spell or "regrowth" ]
        predatorsswiftness_spell_assigned = true
    end

    -- Reset NerdDruid vars
    if last_seen_encounterDifficulty > 0 and state.encounterDifficulty == 0 then
        encounter_berserk_count = 0
    end
end )

spec:RegisterStateFunction("init_rotation", function()
    ready_to_shift = false
    ready_to_gift = false
    do_gift_of_the_wild = false
    do_cat_form = false
    do_bear_form = false
end)

spec:RegisterStateExpr("execute_rotation", function()
    init_rotation()

    if ready_to_gift then
        do_gift_of_the_wild = true
        return
    end

    if ready_to_shift then
        do_cat_form, do_bear_form = player_shift(query_time, false)
        return
    end

    local end_thresh = 10
    local rip_now = (
        combo_points.current >= rip_cp and debuff.rip.down 
        and target.time_to_die >= end_thresh
        and buff.clearcasting.down
    )
    local bite_at_end = (
        combo_points.current >= bite_cp
        and (
            target.time_to_die < end_thresh or (
                debuff.rip.up and
                target.time_to_die - debuff.rip.remains < end_thresh
            )
        )
    )
    local mangle_now = (
        not rip_now and debuff.mangle.down
    )
    local bite_before_rip = (
        combo_points.current >= bite_cp and debuff.rip.up and buff.savage_roar.up
            and ferociousbite_enabled and can_bite(query_time)
    )
    local bite_now = (
        (bite_before_rip or bite_at_end) and buff.clearcasting.down
    )
    if bite_now and buff.berserk.up then
        bite_now = energy.current <= max_bite_energy
    end
    local rake_now = (
        use_rake and debuff.rake.down
        and target.time_to_die > 9
        and buff.clearcasting.down
    )
    if rake_now then
        local _, _, should_rake = calculate_ability_dpe()
        rake_now = set_bonus.tier9_2pc == 0 and set_bonus.tier10_4pc == 0 and should_rake
    end

    local berserk_dur = 15 + 5 * (glyph.berserk.enabled and 1 or 0)
    local wait_for_tf = (
        cooldown.tigers_fury.remains <= berserk_dur and
        cooldown.tigers_fury.remains + 1 < target.time_to_die - berserk_dur
    )
    local berserk_now = (
        cooldown.berserk.up and not wait_for_tf
    )
    -- TODO: End of fight berserk optimization

    local roar_now = combo_points.current > 1 and (
        buff.savage_roar.down or clip_roar()
    )

    local pending_actions = {}
    local rip_refresh_pending = false

    if debuff.rip.up and (debuff.rip.remains < target.time_to_die - end_thresh)
        local rip_cost = (
            berserk_expected_at(query_time, query_time + debuff.rip.remains)
                and 15
                or 30
        )  

        pending_actions[query_time + debuff.rip.remains] = rip_cost
        rip_refresh_pending = true
    end
    if debuff.rake.up and (debuff.rake.remains < target.time_to_die - 9)
        local rake_cost = (
            berserk_expected_at(query_time, query_time + debuff.rake.remains)
                and 17.5
                or 35
        )

        pending_actions[query_time + debuff.rake.remains] = rake_cost
    end
    if debuff.mangle.up and (debuff.mangle.remains < target.time_to_die - 1)
        local mangle_cost = (
            berserk_expected_at(query_time, query_time + debuff.mangle.remains)
                and 20
                or 40
        )

        pending_actions[query_time + debuff.mangle.remains] = mangle_cost
    end
    if buff.savage_roar.up then
        local roar_cost = (
            berserk_expected_at(query_time, query_time + buff.savage_roar.remains)
                and 12.5
                or 25
        )
    end

    local weave_energy = furor_cap - 30 - 20 * latency
    if talent.furor.rank > 3 then
        weave_energy = weave_energy - (
            bearweaving_lacerate_enabled and debuff.lacerate.down
                and 30
                or 15
        )
    end

    local weave_end = query_time + 4.5 * 2 * latency
    local bearweave_now = (
        bearweaving_enabled and energy.current < weave_energy
        and buff.clearcasting.down
        and (not rip_refresh_pending or query_time + debuff.rip.remains >= weave_end)
        and not buff.berserk.up
    )

    if bearweave_now and not bearweaving_lacerate_enabled then
        bearweave_now = not tf_expected_before(query_time, weave_end)
    end

    if bearweave_now then
        local energy_to_dump = energy.current + (weave_end - query_time) * 10
        bearweave_now = (
            weave_end + energy_to_dump / 42 < target.time_to_die
        )
    end

    local emergency_bearweave = (
        bearweaving_enabled and bearweaving_lacerate_enabled
        and debuff.lacerate.up
        and (query_time + debuff.lacerate.end - query_time < 2.5 + latency)
        and debuff.lacerate.remains < target.time_to_die
        and not buff.berserk.up
    )

    local flower_end = query_time + action.gift_of_the_wild.gcd + 1.5 + 2 * latency
    local flowershift_now = (
        flowerweaving_enabled and energy.current <= flowerweaving_energy
        and not buff.clearcasting.up
        and (not rip_refresh_pending or query_time + debuff.rip.remains >= flower_end)
        and not buff.berserk.up
        and not tf_expected_before(query_time, flower_end)
    )

    if flowershift_now then
        local energy_to_dump = energy.current + (flower_end + 1 - query_time) * 10
        flowershift_now = (
            flower_end + 1.0 + energy_to_dump / 42 < query_time + target.time_to_die
        )
    end

    local floating_energy = 0
    local previous_time = query_time
    local tf_pending = false
    local pending_keys = {}
    for k in pairs(pending_actions) do table.insert(pending_keys, k) end
    table.sort(pending_keys)
    for _, k in ipairs(pending_keys) do 
        local refresh_time = k
        local refresh_cost = pending_actions[k]
        local delta_t = refresh_time - previous_time

        if not tf_pending then
            tf_pending = tf_expected_before(query_time, refresh_time)

            if tf_pending then
                refresh_cost = refresh_cost - 60
            end
        end

        if delta_t < refresh_cost / 10 then
            floating_energy = floating_energy + refresh_cost - 10 * delta_t
            previous_time = refresh_time
        else
            previous_time = previous_time + refresh_cost / 10
        end
    end

    local excess_e = energy.current - floating_energy
    local time_to_next_action = 0
    if not buff.cat_form.up and flowerweaving_enabled then
        if flowershift_now then
            do_gift_of_the_wild = true
        else
            ready_to_shift = true
        end
    elseif not buff.cat_form.up then
        local shift_now = (
            energy.current + 15 + 10 * latency > furor_cap
            or rip_refresh_pending and debuff.rip.remains > 3
            or buff.berserk.up
        )
        local shift_next = (
            energy.current + 30 + 10 * latency > furor_cap
            or rip_refresh_pending and debuff.rip.remains > 4.5
            or buff.berserk.up
        )
    end
end)

spec:RegisterStateFunction("berserk_expected_at", function(current_time, future_time)
    if buff.berserk.up then
        return (
            future_time - current_time < buff.berserk.remains
            or future_time > current_time + cooldown.berserk.remains
        )
    end
    if cooldown.berserk.remains > 0 then
        return future_time > current_time + cooldown.berserk.remains
    end
    return future_time > current_time + cooldown.tigers_fury.remains
end)

spec:RegisterStateFunction("tf_expected_before", function(current_time, future_time)
    if cooldown.tigers_fury.remains > 0 then
        return current_time + cooldown.tigers_fury.remains < future_time
    end
    if buff.berserk.up then
        return current_time + buff.berserk.remains < future_time
    end
    return true
end)

spec:RegisterStateFunction("clip_roar", function()
    if debuff.rip.down or target.time_to_die - debuff.rip.remains < 10 then
        return false
    end

    if buff.savage_roar.remains > rip_maxremains then
        return false
    end

    return 14 + ((combo_points.current-1)*5) >= rip_maxremains + min_roar_offset
end)

spec:RegisterStateFunction("calculate_ability_dpe", function()
    local armor_pen = stat.armor_pen_rating
    local att_power = stat.attack_power
    local crit_pct = stat.crit / 100
    local boss_armor = 10643*(1-0.05*(debuff.armor_reduction.up and 1 or 0))*(1-0.2*(debuff.major_armor_reduction.up and 1 or 0))*(1-0.2*(debuff.shattering_throw.up and 1 or 0))
    local tigers_fury = buff.tigers_fury.up and 80 or 0
    local shred_idol = set_bonus.idol_of_the_ravenous_beast == 1 and 203 or 0
    local rake_dpe = 3*(358 + 6*att_power/100)/35
    local shred_dpe = ((54.5 + tigers_fury + att_power/14)*2.25 + 666 + shred_idol - 42/35*(att_power/100 + 176))*(1 + 1.266*crit_pct)*(1 - (boss_armor*(1 - armor_pen/1399))/((boss_armor*(1 - armor_pen/1399)) + 15232.5))/42
    return rake_dpe, shred_dpe, rake_dpe >= shred_dpe
end)

spec:RegisterStateFunction("player_shift", function(time, powershift)
    local rtn_cat_form = powershift and buff.cat_form.up or not powershift and buff.dire_bear_form.up
    local rtn_bear_form = powershift and buff.dire_bear_form.up or not powershift and buff.cat_form.up
    return rtn_cat_form, rtn_bear_form
end)

spec:RegisterStateFunction("can_bite", function(time)
    return debuff.rip.remains >= min_bite_rip_remains and buff.savage_roar.remains >= min_bite_sr_remains
end)

spec:RegisterStateFunction("calc_crit_multiplier", function()

end)

spec:RegisterStateExpr("do_gift_of_the_wild", function()
    return do_gift_of_the_wild
end)

spec:RegisterStateExpr("do_cat_form", function()
    return do_cat_form
end)

spec:RegisterStateExpr("do_bear_form", function()
    return do_bear_form
end)

spec:RegisterStateExpr("rip_maxremains", function()
    if debuff.rip.remains == 0 then
        return 0
    else
        return debuff.rip.remains + ((debuff.rip.up and glyph.shred.enabled and (6 - rip_tracker[target.unit].extension)) or 0)
    end
end)

-- APL expressions
spec:RegisterStateExpr( "furor_cap", function()
    return min(20 * talent.furor.rank, 85)
end)

spec:RegisterStateExpr( "flowerweaving_energy", function()
    return min(furor_cap, 75) - 10 * action.gift_of_the_wild.gcd - 20 * latency
end)

spec:RegisterStateExpr( "ready_to_gift", function()
    return ready_to_gift
end)

-- Settings
spec:RegisterStateExpr( "mainhand_remains", function()
    local next_swing, real_swing, pseudo_swing = 0, 0, 0
    if now == query_time then
        real_swing = nextMH - now
        next_swing = real_swing > 0 and real_swing or 0
    else
        if query_time <= nextMH then
            pseudo_swing = nextMH - query_time
        else
            pseudo_swing = (query_time - nextMH) % mainhand_speed
        end
        next_swing = pseudo_swing
    end
    return next_swing
end)

spec:RegisterStateExpr("min_roar_offset", function()
    return settings.min_roar_offset
end)

spec:RegisterStateExpr("ferociousbite_enabled", function()
    return settings.ferociousbite_enabled
end)

spec:RegisterStateExpr("min_bite_sr_remains", function()
    return settings.min_bite_sr_remains
end)

spec:RegisterStateExpr("min_bite_rip_remains", function()
    return settings.min_bite_rip_remains
end)

spec:RegisterStateExpr("max_bite_energy", function()
    return settings.max_bite_energy
end)

spec:RegisterStateExpr("flowerweaving_enabled", function()
    return settings.flowerweaving_enabled and (state.group_members >= flowerweaving_mingroupsize)
end)

spec:RegisterStateExpr("flowerweaving_mode", function()
    return settings.flowerweaving_mode
end)

spec:RegisterStateExpr("flowerweaving_mode_any", function()
    return settings.flowerweaving_mode == "any";
end)

spec:RegisterStateExpr("bearweaving_enabled", function()
    return settings.bearweaving_enabled and (settings.bearweaving_bossonly == false or state.encounterDifficulty > 0) and (settings.bearweaving_instancetype == "any" or (settings.bearweaving_instancetype == "dungeon" and (instanceType == "party" or instanceType == "raid")) or (settings.bearweaving_instancetype == "raid" and instanceType == "raid"))
end)

spec:RegisterStateExpr("bearweaving_lacerate_enabled", function()
    return bearweaving_enabled and settings.bearweaving_spell == "lacerate"
end)

spec:RegisterStateExpr("bearweaving_mangle_enabled", function()
    return bearweaving_enabled and settings.bearweaving_spell == "mangle"
end)

spec:RegisterStateExpr("predatorsswiftness_enabled", function()
    return settings.predatorsswiftness_enabled
end)

-- Resources
local function rage_amount()
    local d = UnitDamage( "player" ) * 0.7
    local c = ( state.level > 70 and 1.4139 or 1 ) * ( 0.0091107836 * ( state.level ^ 2 ) + 3.225598133 * state.level + 4.2652911 )
    local f = 3.5
    local s = 2.5

    return min( ( 15 * d ) / ( 4 * c ) + ( f * s * 0.5 ), 15 * d / c )
end

spec:RegisterResource( Enum.PowerType.Rage, {
    enrage = {
        aura = "enrage",

        last = function ()
            local app = state.buff.enrage.applied
            local t = state.query_time

            return app + floor( t - app )
        end,

        interval = 1,
        value = 2
    },

    mainhand = {
        swing = "mainhand",
        aura = "dire_bear_form",

        last = function ()
            local swing = state.combat == 0 and state.now or state.swings.mainhand
            local t = state.query_time

            return swing + ( floor( ( t - swing ) / state.swings.mainhand_speed ) * state.swings.mainhand_speed )
        end,

        interval = "mainhand_speed",

        stop = function () return state.swings.mainhand == 0 end,
        value = function( now )
            return state.buff.maul.expires < now and rage_amount() or 0
        end,
    },
} )
spec:RegisterResource( Enum.PowerType.Mana )
spec:RegisterResource( Enum.PowerType.ComboPoints )
spec:RegisterResource( Enum.PowerType.Energy )


-- Talents
spec:RegisterTalents( {
    balance_of_power            = {  1783, 2, 33592, 33596 },
    berserk                     = {  1927, 1, 50334 },
    brambles                    = {   782, 3, 16836, 16839, 16840 },
    brutal_impact               = {   797, 2, 16940, 16941 },
    celestial_focus             = {   784, 3, 16850, 16923, 16924 },
    dreamstate                  = {  1784, 3, 33597, 33599, 33956 },
    earth_and_moon              = {  1928, 3, 48506, 48510, 48511 },
    eclipse                     = {  1924, 3, 48516, 48521, 48525 },
    empowered_rejuvenation      = {  1789, 5, 33886, 33887, 33888, 33889, 33890 },
    empowered_touch             = {  1788, 2, 33879, 33880 },
    feral_aggression            = {   795, 5, 16858, 16859, 16860, 16861, 16862 },
    feral_charge                = {   804, 1, 49377 },
    feral_instinct              = {   799, 3, 16947, 16948, 16949 },
    feral_swiftness             = {   807, 2, 17002, 24866 },
    ferocity                    = {   796, 5, 16934, 16935, 16936, 16937, 16938 },
    force_of_nature             = {  1787, 1, 33831 },
    furor                       = {   822, 5, 17056, 17058, 17059, 17060, 17061 },
    gale_winds                  = {  1925, 2, 48488, 48514 },
    genesis                     = {  2238, 5, 57810, 57811, 57812, 57813, 57814 },
    gift_of_nature              = {   828, 5, 17104, 24943, 24944, 24945, 24946 },
    gift_of_the_earthmother     = {  1916, 5, 51179, 51180, 51181, 51182, 51183 },
    heart_of_the_wild           = {   808, 5, 17003, 17004, 17005, 17006, 24894 },
    improved_barkskin           = {  2264, 2, 63410, 63411 },
    improved_faerie_fire        = {  1785, 3, 33600, 33601, 33602 },
    improved_insect_swarm       = {  2239, 3, 57849, 57850, 57851 },
    improved_leader_of_the_pack = {  1798, 2, 34297, 34300 },
    improved_mangle             = {  1920, 3, 48532, 48489, 48491 },
    improved_mark_of_the_wild   = {   821, 2, 17050, 17051 },
    improved_moonfire           = {   763, 2, 16821, 16822 },
    improved_moonkin_form       = {  1912, 3, 48384, 48395, 48396 },
    improved_rejuvenation       = {   830, 3, 17111, 17112, 17113 },
    improved_tranquility        = {   842, 2, 17123, 17124 },
    improved_tree_of_life       = {  1930, 3, 48535, 48536, 48537 },
    infected_wounds             = {  1919, 3, 48483, 48484, 48485 },
    insect_swarm                = {   788, 1,  5570 },
    intensity                   = {   829, 3, 17106, 17107, 17108 },
    king_of_the_jungle          = {  1921, 3, 48492, 48494, 48495 },
    leader_of_the_pack          = {   809, 1, 17007 },
    living_seed                 = {  1922, 3, 48496, 48499, 48500 },
    living_spirit               = {  1797, 3, 34151, 34152, 34153 },
    lunar_guidance              = {  1782, 3, 33589, 33590, 33591 },
    mangle                      = {  1796, 1, 33917 },
    master_shapeshifter         = {  1915, 2, 48411, 48412 },
    moonfury                    = {   790, 3, 16896, 16897, 16899 },
    moonglow                    = {   783, 3, 16845, 16846, 16847 },
    moonkin_form                = {   793, 1, 24858 },
    natural_perfection          = {  1790, 3, 33881, 33882, 33883 },
    natural_reaction            = {  2242, 3, 57878, 57880, 57881 },
    natural_shapeshifter        = {   826, 3, 16833, 16834, 16835 },
    naturalist                  = {   824, 5, 17069, 17070, 17071, 17072, 17073 },
    natures_bounty              = {   825, 5, 17074, 17075, 17076, 17077, 17078 },
    natures_focus               = {   823, 3, 17063, 17065, 17066 },
    natures_grace               = {   789, 3, 16880, 61345, 61346 },
    natures_majesty             = {  1822, 2, 35363, 35364 },
    natures_reach               = {   764, 2, 16819, 16820 },
    natures_splendor            = {  2240, 1, 57865 },
    natures_swiftness           = {   831, 1, 17116 },
    nurturing_instinct          = {  1792, 2, 33872, 33873 },
    omen_of_clarity             = {   827, 1, 16864 },
    owlkin_frenzy               = {  1913, 3, 48389, 48392, 48393 },
    predatory_instincts         = {  1795, 3, 33859, 33866, 33867 },
    predatory_strikes           = {   803, 3, 16972, 16974, 16975 },
    primal_fury                 = {   801, 2, 37116, 37117 },
    primal_gore                 = {  2266, 1, 63503 },
    primal_precision            = {  1914, 2, 48409, 48410 },
    primal_tenacity             = {  1793, 3, 33851, 33852, 33957 },
    protector_of_the_pack       = {  2241, 3, 57873, 57876, 57877 },
    rend_and_tear               = {  1918, 5, 48432, 48433, 48434, 51268, 51269 },
    revitalize                  = {  1929, 3, 48539, 48544, 48545 },
    savage_fury                 = {   805, 2, 16998, 16999 },
    sharpened_claws             = {   798, 3, 16942, 16943, 16944 },
    shredding_attacks           = {   802, 2, 16966, 16968 },
    starfall                    = {  1926, 1, 48505 },
    starlight_wrath             = {   762, 5, 16814, 16815, 16816, 16817, 16818 },
    subtlety                    = {   841, 3, 17118, 17119, 17120 },
    survival_instincts          = {  1162, 1, 61336 },
    survival_of_the_fittest     = {  1794, 3, 33853, 33855, 33856 },
    swiftmend                   = {   844, 1, 18562 },
    thick_hide                  = {   794, 3, 16929, 16930, 16931 },
    tranquil_spirit             = {   843, 5, 24968, 24969, 24970, 24971, 24972 },
    tree_of_life                = {  1791, 1, 65139 },
    typhoon                     = {  1923, 1, 50516 },
    vengeance                   = {   792, 5, 16909, 16910, 16911, 16912, 16913 },
    wild_growth                 = {  1917, 1, 48438 },
    wrath_of_cenarius           = {  1786, 5, 33603, 33604, 33605, 33606, 33607 },
} )


-- Glyphs
spec:RegisterGlyphs( {
    [57856] = "aquatic_form",
    [63057] = "barkskin",
    [62969] = "berserk",
    [57858] = "challenging_roar",
    [67598] = "claw",
    [59219] = "dash",
    [54760] = "entangling_roots",
    [62080] = "focus",
    [54810] = "frenzied_regeneration",
    [54812] = "growling",
    [54825] = "healing_touch",
    [54831] = "hurricane",
    [54832] = "innervate",
    [54830] = "insect_swarm",
    [54826] = "lifebloom",
    [54813] = "mangle",
    [54811] = "maul",
    [63056] = "monsoon",
    [54829] = "moonfire",
    [52084] = "natural_force",
    [62971] = "nourish",
    [54821] = "rake",
    [71013] = "rapid_rejuvenation",
    [54733] = "rebirth",
    [54743] = "regrowth",
    [54754] = "rejuvenation",
    [54818] = "rip",
    [63055] = "savage_roar",
    [54815] = "shred",
    [54828] = "starfall",
    [54845] = "starfire",
    [65243] = "survival_instincts",
    [54824] = "swiftmend",
    [58136] = "bear_cub",
    [58133] = "forest_lynx",
    [52648] = "penguin",
    [54912] = "red_lynx",
    [57855] = "wild",
    [57862] = "thorns",
    [62135] = "typhoon",
    [57857] = "unburdened_rebirth",
    [62970] = "wild_growth",
    [54756] = "wrath",
} )


-- Auras
spec:RegisterAuras( {
    -- Attempts to cure $3137s1 poison every $t1 seconds.
    abolish_poison = {
        id = 2893,
        duration = 12,
        tick_time = 3,
        max_stack = 1,
    },
    -- Immune to Polymorph effects.  Increases swim speed by $5421s1% and allows underwater breathing.
    aquatic_form = {
        id = 1066,
        duration = 3600,
        max_stack = 1,
    },
    -- All damage taken is reduced by $s2%.  While protected, damaging attacks will not cause spellcasting delays.
    barkskin = {
        id = 22812,
        duration = function() return 12 + ((set_bonus.tier7_4pc == 1 and 3) or 0) end,
        max_stack = 1,
    },
    -- Stunned.
    bash = {
        id = 5211,
        duration = function() return 4 + ( 0.5 * talent.brutal_impact.rank ) end,
        max_stack = 1,
        copy = { 5211, 6798, 8983, 58861 },
    },
    bear_form = {
        id = 5487,
        duration = 3600,
        max_stack = 1,
        copy = { 5487, 9634 }
    },
    -- Immune to Fear effects.
    berserk = {
        id = 50334,
        duration = function() return glyph.berserk.enabled and 20 or 15 end,
        max_stack = 1,
    },
    -- Immunity to Polymorph effects.  Increases melee attack power by $3025s1 plus Agility.
    cat_form = {
        id = 768,
        duration = 3600,
        max_stack = 1,
    },
    -- Taunted.
    challenging_roar = {
        id = 5209,
        duration = 6,
        max_stack = 1,
    },
    -- Your next damage or healing spell or offensive ability has its mana, rage or energy cost reduced by $s1%.
    clearcasting = {
        id = 16870,
        duration = 15,
        max_stack = 1,
        copy = "omen_of_clarity"
    },
    -- Invulnerable, but unable to act.
    cyclone = {
        id = 33786,
        duration = 6,
        max_stack = 1,
    },
    -- Increases movement speed by $s1% while in Cat Form.
    dash = {
        id = 33357,
        duration = 15,
        max_stack = 1,
        copy = { 1850, 9821, 33357 },
    },
    -- Dazed.
    dazed = {
        id = 50411,
        duration = 3,
        max_stack = 1,
        copy = { 50411, 50259 },
    },
    -- Decreases melee attack power by $s1.
    demoralizing_roar = {
        id = 48560,
        duration = 30,
        max_stack = 1,
        copy = { 99, 1735, 9490, 9747, 9898, 26998, 48559, 48560 },
    },
    -- Immune to Polymorph effects.  Increases melee attack power by $9635s3, armor contribution from cloth and leather items by $9635s1%, and Stamina by $9635s2%.
    dire_bear_form = {
        id = 9634,
        duration = 3600,
        max_stack = 1,
    },
    -- Increases spell damage taken by $s1%.
    earth_and_moon = {
        id = 60433,
        duration = 12,
        max_stack = 1,
        copy = { 60433, 60432, 60431 },
    },
    -- Starfire critical hit +40%.
    eclipse_lunar = {
        id = 48518,
        duration = 15,
        max_stack = 1,
        copy = "lunar_eclipse",
    },
    -- Wrath damage bonus.
    eclipse_solar = {
        id = 48517,
        duration = 15,
        max_stack = 1,
        copy = "eclipse_solar",
    },
    -- Gain $/10;s1 rage per second.  Base armor reduced.
    enrage = {
        id = 5229,
        duration = 10,
        tick_time = 1,
        max_stack = 1,
    },
    -- Rooted.  Causes $s2 Nature damage every $t2 seconds.
    entangling_roots = {
        id = 19975,
        duration = 12,
        max_stack = 1,
        copy = { 339, 1062, 5195, 5196, 9852, 9853, 19970, 19971, 19972, 19973, 19974, 19975, 26989, 27010, 53308, 53313, 65857, 66070 },
    },
    feline_grace = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=20719)
        id = 20719,
        duration = 3600,
        max_stack = 1,
    },
    feral_aggression = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=16862)
        id = 16862,
        duration = 3600,
        max_stack = 1,
        copy = { 16862, 16861, 16860, 16859, 16858 },
    },
    -- Immobilized.
    feral_charge_effect = {
        id = 45334,
        duration = 4,
        max_stack = 1,
        copy = { 45334, 19675 },
    },
    flight_form = {
        id = 33943,
        duration = 3600,
        max_stack = 1,
    },
    force_of_nature = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=33831)
        id = 33831,
        duration = 30,
        max_stack = 1,
    },
    form = {
        alias = { "aquatic_form", "cat_form", "bear_form", "dire_bear_form", "flight_form", "moonkin_form", "swift_flight_form", "travel_form"  },
        aliasType = "buff",
        aliasMode = "first"
    },
    -- Converting rage into health.
    frenzied_regeneration = {
        id = 22842,
        duration = 10,
        tick_time = 1,
        max_stack = 1,
        copy = { 22842, 22895, 22896, 26999 },
    },
    -- Taunted.
    growl = {
        id = 6795,
        duration = 3,
        max_stack = 1,
    },
    -- Asleep.
    hibernate = {
        id = 2637,
        duration = 20,
        max_stack = 1,
        copy = { 2637, 18657, 18658 },
    },
    -- $42231s1 damage every $t3 seconds, and time between attacks increased by $s2%.$?$w1<0[ Movement slowed by $w1%.][]
    hurricane = {
        id = 16914,
        duration = 10,
        max_stack = 1,
        copy = { 16914, 17401, 17402, 27012, 48467 },
    },
    improved_moonfire = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=16822)
        id = 16822,
        duration = 3600,
        max_stack = 1,
        copy = { 16822, 16821 },
    },
    improved_rejuvenation = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=17113)
        id = 17113,
        duration = 3600,
        max_stack = 1,
        copy = { 17113, 17112, 17111 },
    },
    -- Movement speed slowed by $s1% and attack speed slowed by $s2%.
    infected_wounds = {
        id = 58181,
        duration = 12,
        max_stack = 1,
        copy = { 58181, 58180, 58179 },
    },
    -- Regenerating mana.
    innervate = {
        id = 29166,
        duration = 10,
        tick_time = 1,
        max_stack = 1,
    },
    -- Chance to hit with melee and ranged attacks decreased by $s2% and $s1 Nature damage every $t1 sec.
    insect_swarm = {
        id = 5570,
        duration = 12,
        tick_time = 2,
        max_stack = 1,
        copy = { 5570, 24974, 24975, 24976, 24977, 27013, 48468 },
    },
    -- $s1 damage every $t sec
    lacerate = {
        id = 48568,
        duration = 15,
        tick_time = 3,
        max_stack = 5,
        copy = { 33745, 48567, 48568 },
    },
    -- Heals $s1 every second and $s2 when effect finishes or is dispelled.
    lifebloom = {
        id = 33763,
        duration = function() return glyph.lifebloom.enabled and 8 or 7 end,
        tick_time = 1,
        max_stack = 3,
        copy = { 33763, 48450, 48451 },
    },
    living_spirit = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=34153)
        id = 34153,
        duration = 3600,
        max_stack = 1,
        copy = { 34153, 34152, 34151 },
    },
    maul = {
        duration = function () return swings.mainhand_speed end,
        max_stack = 1,
    },
    -- $s1 Arcane damage every $t1 seconds.
    moonfire = {
        id = 8921,
        duration = 9,
        tick_time = 3,
        max_stack = 1,
        copy = { 8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835, 26987, 26988, 48462, 48463, 65856 },
    },
    -- Increases spell critical chance by $s1%.
    moonkin_aura = {
        id = 24907,
        duration = 3600,
        max_stack = 1,
    },
    -- Immune to Polymorph effects.  Armor contribution from items is increased by $24905s1%.  Damage taken while stunned reduced $69366s1%.  Single target spell criticals instantly regenerate $53506s1% of your total mana.
    moonkin_form = {
        id = 24858,
        duration = 3600,
        max_stack = 1,
    },
    -- Reduces all damage taken by $s1%.
    natural_perfection = {
        id = 45283,
        duration = 8,
        max_stack = 3,
        copy = { 45281, 45282, 45283 },
    },
    natural_shapeshifter = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=16835)
        id = 16835,
        duration = 6,
        max_stack = 1,
        copy = { 16835, 16834, 16833 },
    },
    naturalist = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=17073)
        id = 17073,
        duration = 3600,
        max_stack = 1,
        copy = { 17073, 17072, 17071, 17070, 17069 },
    },
    -- Spell casting speed increased by $s1%.
    natures_grace = {
        id = 16886,
        duration = 3,
        max_stack = 1,
    },
    -- Melee damage you take has a chance to entangle the enemy.
    natures_grasp = {
        id = 16689,
        duration = 45,
        max_stack = 1,
        copy = { 16689, 16810, 16811, 16812, 16813, 17329, 27009, 53312, 66071 },
    },
    -- Your next Nature spell will be an instant cast spell.
    natures_swiftness = {
        id = 17116,
        duration = 3600,
        max_stack = 1,
    },
    -- Damage increased by $s2%, $s3% base mana is restored every $T3 sec, and damage done to you no longer causes pushback.
    owlkin_frenzy = {
        id = 48391,
        duration = 10,
        max_stack = 1,
    },
    -- Stunned.
    pounce = {
        id = 49803,
        duration = 3,
        max_stack = 1,
        copy = { 9005, 9823, 9827, 27006, 49803 },
    },
    -- Bleeding for $s1 damage every $t1 seconds.
    pounce_bleed = {
        id = 49804,
        duration = 18,
        tick_time = 3,
        max_stack = 1,
        copy = { 9007, 9824, 9826, 27007, 49804 },
    },
    -- Your next Nature spell will be an instant cast spell.
    predators_swiftness = {
        id = 69369,
        duration = 8,
        max_stack = 1,
    },
    -- Stealthed.  Movement speed slowed by $s2%.
    prowl = {
        id = 5215,
        duration = 3600,
        max_stack = 1,
    },
    -- Bleeding for $s2 damage every $t2 seconds.
    rake = {
        id = 48574,
        duration = function() return 9 + ((set_bonus.tier9_2pc == 1 and 3) or 0) end,
        max_stack = 1,
        copy = { 1822, 1823, 1824, 9904, 27003, 48573, 48574, 59881, 59882, 59883, 59884, 59885, 59886 },
    },
    -- Heals $s2 every $t2 seconds.
    regrowth = {
        id = 8936,
        duration = 21,
        max_stack = 1,
        copy = { 8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858, 26980, 48442, 48443, 66067 },
    },
    -- Heals $s1 damage every $t1 seconds.
    rejuvenation = {
        id = 774,
        duration = 15,
        tick_time = 3,
        max_stack = 1,
        copy = { 774, 1058, 1430, 2090, 2091, 3627, 8070, 8910, 9839, 9840, 9841, 25299, 26981, 26982, 48440, 48441 },
    },
    -- Bleed damage every $t1 seconds.
    rip = {
        id = 49800,
        duration = function() return 12 + ((glyph.rip.enabled and 4) or 0) + ((set_bonus.tier7_2pc == 1 and 4) or 0) end,
        tick_time = 2,
        max_stack = 1,
        copy = { 1079, 9492, 9493, 9752, 9894, 9896, 27008, 49799, 49800 },
    },
    -- Absorbs physical damage equal to $s1% of your attack power for 1 hit.
    savage_defense = {
        id = 62606,
        duration = 10,
        max_stack = 1,
    },
    -- Physical damage done increased by $s2%.
    savage_roar = {
        id = 52610,
        duration = 14,
        max_stack = 1,
        copy = { 52610 },
    },
    sharpened_claws = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=16944)
        id = 16944,
        duration = 3600,
        max_stack = 1,
        copy = { 16944, 16943, 16942 },
    },
    shredding_attacks = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=16968)
        id = 16968,
        duration = 3600,
        max_stack = 1,
        copy = { 16968, 16966 },
    },
    -- Reduced distance at which target will attack.
    soothe_animal = {
        id = 2908,
        duration = 15,
        max_stack = 1,
        copy = { 2908, 8955, 9901, 26995 },
    },
    -- Summoning stars from the sky.
    starfall = {
        id = 48505,
        duration = 10,
        tick_time = 1,
        max_stack = 1,
        copy = { 48505, 50286, 50288, 50294, 53188, 53189, 53190, 53191, 53194, 53195, 53196, 53197, 53198, 53199, 53200, 53201 },
    },
    starlight_wrath = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=16818)
        id = 16818,
        duration = 3600,
        max_stack = 1,
        copy = { 16818, 16817, 16816, 16815, 16814 },
    },
    -- Health increased by 30% of maximum while in Bear Form, Cat Form, or Dire Bear Form.
    survival_instincts = {
        id = 61336,
        duration = 20,
        max_stack = 1,
    },
    -- Immune to Polymorph effects.  Movement speed increased by $40121s2% and allows you to fly.
    swift_flight_form = {
        id = 40120,
        duration = 3600,
        max_stack = 1,
    },
    -- Causes $s1 Nature damage to attackers.
    thorns = {
        id = 467,
        duration = function() return glyph.thorns.enabled and 6000 or 600 end,
        max_stack = 1,
        copy = { 467, 782, 1075, 8914, 9756, 9910, 16877, 26992, 53307, 66068 },
    },
    -- Increases damage done by $s1.
    tigers_fury = {
        id = 50213,
        duration = 6,
        max_stack = 1,
        copy = { 5217, 6793, 9845, 9846, 50212, 50213 },
    },
    -- Tracking humanoids.
    track_humanoids = {
        id = 5225,
        duration = 3600,
        max_stack = 1,
    },
    -- Heals nearby party members for $s1 every $t2 seconds.
    tranquility = {
        id = 740,
        duration = 8,
        max_stack = 1,
        copy = { 740, 8918, 9862, 9863, 26983, 48446, 48447 },
    },
    -- Immune to Polymorph effects.  Movement speed increased by $5419s1%.
    travel_form = {
        id = 783,
        duration = 3600,
        max_stack = 1,
    },
    -- Immune to Polymorph effects. Increases healing received by $34123s1% for all party and raid members within $34123a1 yards.
    tree_of_life = {
        id = 33891,
        duration = 3600,
        max_stack = 1,
    },
    -- Dazed.
    typhoon = {
        id = 61391,
        duration = 6,
        max_stack = 1,
        copy = { 53227, 61387, 61388, 61390, 61391 },
    },
    -- Stunned.
    war_stomp = {
        id = 20549,
        duration = 2,
        max_stack = 1,
    },
    -- Heals $s1 damage every $t1 second.
    wild_growth = {
        id = 48438,
        duration = 7,
        tick_time = 1,
        max_stack = 1,
        copy = { 48438, 53248, 53249, 53251 },
    },
    wrath_of_cenarius = { -- TODO: Check Aura (https://wowhead.com/wotlk/spell=33607)
        id = 33607,
        duration = 3600,
        max_stack = 1,
        copy = { 33607, 33606, 33605, 33604, 33603 },
    },

    rupture = {
        id = 48672,
        duration = 6,
        max_stack = 1,
        shared = "target",
        copy = { 1943, 8639, 8640, 11273, 11274, 11275, 26867, 48671 }
    },
    garrote = {
        id = 48676,
        duration = 18,
        max_stack = 1,
        shared = "target",
        copy = { 703, 8631, 8632, 8633, 11289, 11290, 26839, 26884, 48675 }
    },
    rend = {
        id = 47465,
        duration = 15,
        max_stack = 1,
        shared = "target",
        copy = { 772, 6546, 6547, 6548, 11572, 11573, 11574, 25208 }
    },
    deep_wound = {
        id = 43104,
        duration = 12,
        max_stack = 1,
        shared = "target"
    },
    bleed = {
        alias = { "lacerate", "pounce_bleed", "rip", "rake", "deep_wound", "rend", "garrote", "rupture" },
        aliasType = "debuff",
        aliasMode = "longest"
    }
} )


-- Form Helper
spec:RegisterStateFunction( "swap_form", function( form )
    removeBuff( "form" )
    removeBuff( "maul" )

    if form == "bear_form" or form == "dire_bear_form" then
        spend( rage.current, "rage" )
        if talent.furor.rank==5 then
            gain( 10, "rage" )
        end
    end
    
    if form then
        applyBuff( form )
    end
end )

-- Maul Helper
local finish_maul = setfenv( function()
    spend( (buff.clearcasting.up and 0) or ((15 - talent.ferocity.rank) * ((buff.berserk.up and 0.5) or 1)), "rage" )
end, state )

spec:RegisterStateFunction( "start_maul", function()
    local next_swing = mainhand_remains
    if next_swing <= 0 then
        next_swing = mainhand_speed
    end
    applyBuff( "maul", next_swing )
    state:QueueAuraExpiration( "maul", finish_maul, buff.maul.expires )
end )


-- Abilities
spec:RegisterAbilities( {
    -- Attempts to cure 1 poison effect on the target, and 1 more poison effect every 3 seconds for 12 sec.
    abolish_poison = {
        id = 2893,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.13,
        spendType = "mana",

        startsCombat = true,
        texture = 136068,

        handler = function ()
        end,
    },


    -- Shapeshift into aquatic form, increasing swim speed by 50% and allowing the druid to breathe underwater.  Also protects the caster from Polymorph effects.    The act of shapeshifting frees the caster of Polymorph and Movement Impairing effects.
    aquatic_form = {
        id = 1066,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.13,
        spendType = "mana",

        startsCombat = true,
        texture = 132112,

        handler = function ()
            swap_form( "aquatic_form" )
        end,
    },


    -- The druid's skin becomes as tough as bark.  All damage taken is reduced by 20%.  While protected, damaging attacks will not cause spellcasting delays.  This spell is usable while stunned, frozen, incapacitated, feared or asleep.  Usable in all forms.  Lasts 12 sec.
    barkskin = {
        id = 22812,
        cast = 0,
        cooldown = function() return 60 - ((set_bonus.tier9_4pc == 1 and 12) or 0) end,
        gcd = "off",

        startsCombat = true,
        texture = 136097,

        toggle = "cooldowns",

        handler = function ()
        end,
    },


    -- Stuns the target for 4 sec and interrupts non-player spellcasting for 3 sec.
    bash = {
        id = 8983,
        cast = 0,
        cooldown = 60,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 10 end,
        spendType = "rage",

        startsCombat = true,
        texture = 132114,

        toggle = "cooldowns",

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },

    -- When activated, this ability causes your Mangle (Bear) ability to hit up to 3 targets and have no cooldown, and reduces the energy cost of all your Cat Form abilities by 50%.  Lasts 15 sec.  You cannot use Tiger's Fury while Berserk is active.     Clears the effect of Fear and makes you immune to Fear for the duration.
    berserk = {
        id = 50334,
        cast = 0,
        cooldown = 180,
        gcd = "totem",

        spend = 0,
        spendType = "energy",

        talent = "berserk",
        startsCombat = true,
        texture = 236149,

        toggle = "cooldowns",

        handler = function ()
            applyBuff( "berserk" )
        end,
    },


    -- Shapeshift into cat form, increasing melee attack power by 160 plus Agility.  Also protects the caster from Polymorph effects and allows the use of various cat abilities.    The act of shapeshifting frees the caster of Polymorph and Movement Impairing effects.
    cat_form = {
        id = 768,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return 0.35 * ((talent.king_of_the_jungle.rank > 0 and 0.60) or 1) * ((talent.natural_shapeshifter.rank > 0 and 0.30) or 1) end,
        spendType = "mana",

        startsCombat = true,
        texture = 132115,

        handler = function ()
            swap_form( "cat_form" )
        end,
    },


    -- Forces all nearby enemies within 10 yards to focus attacks on you for 6 sec.
    challenging_roar = {
        id = 5209,
        cast = 0,
        cooldown = function() return glyph.challenging_roar.enabled and 150 or 180 end,
        gcd = "spell",

        spend = 15,
        spendType = "rage",

        startsCombat = true,
        texture = 132117,

        toggle = "cooldowns",

        handler = function ()
        end,
    },


    -- Claw the enemy, causing 370 additional damage.  Awards 1 combo point.
    claw = {
        id = 48570,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function() return (buff.clearcasting.up and 0) or (((glyph.claw.enabled and 40) or 45) * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132140,

        handler = function ()
            removeBuff( "clearcasting" )
            gain( 1, "combo_points" )
        end,
    },


    -- Cower, causing no damage but lowering your threat a large amount, making the enemy less likely to attack you.
    cower = {
        id = 48575,
        cast = 0,
        cooldown = 10,
        gcd = "totem",

        spend = function() return 20 * ((buff.berserk.up and 0.5) or 1) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132118,

        handler = function ()
        end,
    },


    -- Cures 1 poison effect on the target.
    cure_poison = {
        id = 8946,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.13,
        spendType = "mana",

        startsCombat = true,
        texture = 136067,

        handler = function ()
        end,
    },


    -- Tosses the enemy target into the air, preventing all action but making them invulnerable for up to 6 sec.  Only one target can be affected by your Cyclone at a time.
    cyclone = {
        id = 33786,
        cast = 1.5,
        cooldown = 0,
        gcd = "spell",

        spend = 0.08,
        spendType = "mana",

        startsCombat = true,
        texture = 136022,

        handler = function ()
        end,
    },


    -- Increases movement speed by 70% while in Cat Form for 15 sec.  Does not break prowling.
    dash = {
        id = 33357,
        cast = 0,
        cooldown = function() return 180 * ( glyph.dash.enabled and 0.8 or 1 ) end,
        gcd = "off",

        spend = 0,
        spendType = "energy",

        startsCombat = true,
        texture = 132120,

        toggle = "cooldowns",

        handler = function ()
        end,
    },


    -- The druid roars, decreasing nearby enemies' melee attack power by 411.  Lasts 30 sec.
    demoralizing_roar = {
        id = 48560,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 10 end,
        spendType = "rage",

        startsCombat = true,
        texture = 132121,

        handler = function ()
            removeBuff( "clearcasting" )
            applyDebuff( "demoralizing_roar" )
        end,
    },


    -- Shapeshift into dire bear form, increasing melee attack power, armor contribution from cloth and leather items, and Stamina. Also protects the caster from Polymorph effects and allows the use of various bear abilities. The act of shapeshifting frees the caster of Polymorph and Movement Impairing effects.
    dire_bear_form = {
        id = 9634,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return 0.35 * ((talent.king_of_the_jungle.rank > 0 and 0.60) or 1) * ((talent.natural_shapeshifter.rank > 0 and 0.30) or 1) end,
        spendType = "mana",

        startsCombat = true,
        texture = 132276,

        handler = function ()
            swap_form( "dire_bear_form" )
        end,
    },


    -- Generates 20 rage, and then generates an additional 10 rage over 10 sec, but reduces base armor by 27% in Bear Form and 16% in Dire Bear Form.
    enrage = {
        id = 5229,
        cast = 0,
        cooldown = 60,
        gcd = "off",

        spend = 0,
        spendType = "rage",

        startsCombat = true,
        texture = 132126,

        toggle = "cooldowns",

        handler = function ()
            gain(20, "rage" )
            applyBuff( "enrage" )
        end,
    },

    -- Roots the target in place and causes 20 Nature damage over 12 sec.  Damage caused may interrupt the effect.
    entangling_roots = {
        id = 339,
        cast = 1.5,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.07 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136100,

        handler = function ()
            removeBuff( "clearcasting" )
            applyDebuff( "target", "entangling_roots", 27 )
        end,

        copy = { 1062, 5195, 5196, 9852, 9853, 26989, 53308 },
    },


    -- Decrease the armor of the target by 5% for 5 min.  While affected, the target cannot stealth or turn invisible.
    faerie_fire = {
        id = 770,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.08,
        spendType = "mana",

        startsCombat = true,
        texture = 136033,

        handler = function ()
            removeDebuff( "armor_reduction" )
            applyDebuff( "target", "faerie_fire", 300 )
        end,
    },


    -- Decrease the armor of the target by 5% for 5 min.  While affected, the target cannot stealth or turn invisible.  Deals 26 damage and additional threat when used in Bear Form or Dire Bear Form.
    faerie_fire_feral = {
        id = 16857,
        cast = 0,
        cooldown = 6,
        gcd = "totem",

        spend = 0,
        spendType = "energy",

        startsCombat = true,
        texture = 136033,

        handler = function ()
            removeDebuff( "armor_reduction" )
            applyDebuff( "target", "faerie_fire_feral", 300 )
        end,
    },


    -- Finishing move that causes damage per combo point and converts each extra point of energy (up to a maximum of 30 extra energy) into 9.8 additional damage.  Damage is increased by your attack power.     1 point  : 422-562 damage     2 points: 724-864 damage     3 points: 1025-1165 damage     4 points: 1327-1467 damage     5 points: 1628-1768 damage
    ferocious_bite = {
        id = 48577,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function() return (buff.clearcasting.up and 0) or (35 * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132127,

        usable = function() return combo_points.current > 0, "requires combo_points" end,

        handler = function ()
            removeBuff( "clearcasting" )
            if combo_points.current == 5 then
                applyBuff("predators_swiftness")
            end
            set_last_finisher_cp(combo_points.current)
            spend( combo_points.current, "combo_points" )
            spend( min( 30, energy.current ), "energy" )
        end,
    },


    -- Summons 3 treants to attack enemy targets for 30 sec.
    force_of_nature = {
        id = 33831,
        cast = 0,
        cooldown = 180,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.12 end,
        spendType = "mana",

        talent = "force_of_nature",
        startsCombat = true,
        texture = 132129,

        toggle = "cooldowns",

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Converts up to 10 rage per second into health for 10 sec.  Each point of rage is converted into 0.3% of max health.
    frenzied_regeneration = {
        id = 22842,
        cast = 0,
        cooldown = 180,
        gcd = "spell",

        spend = 0,
        spendType = "rage",

        startsCombat = true,
        texture = 132091,

        toggle = "cooldowns",

        handler = function ()
            applyBuff( "frenzied_regeneration" )
        end,
    },


    -- Gives the Gift of the Wild to all party and raid members, increasing armor by 240, all attributes by 10 and all resistances by 15 for 1 |4hour:hrs;.
    gift_of_the_wild = {
        id = 21849,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return glyph.wild.enabled and 0.32 or 0.64 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136038,

        handler = function ()
            applyBuff( "gift_of_the_wild" )
            swap_form( "" )
            if (flowerweaving_enabled and (flowerweaving_mode_any or state.active_enemies > 2) and state.group_members >= flowerweaving_mingroupsize) then
                applyBuff("clearcasting")
            end
        end,

        copy = { 21850, 26991, 48470 },
    },


    -- Taunts the target to attack you, but has no effect if the target is already attacking you.
    growl = {
        id = 6795,
        cast = 0,
        cooldown = function() return 8 - ((set_bonus.tier9_2pc == 1 and 2) or 0) end,
        gcd = "off",

        spend = 0,
        spendType = "rage",

        startsCombat = true,
        texture = 132270,

        handler = function ()
        end,
    },


    -- Heals a friendly target for 40 to 55.
    healing_touch = {
        id = 5185,
        cast = function() return glyph.healing_touch.enabled and 1.5 or 3 end,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.17 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136041,

        handler = function ()
            removeBuff( "clearcasting" )
        end,

        copy = { 5186, 5187, 5188, 5189, 6778, 8903, 9758, 9888, 9889, 25297, 26978, 26979, 48377, 48378 },
    },


    -- Forces the enemy target to sleep for up to 20 sec.  Any damage will awaken the target.  Only one target can be forced to hibernate at a time.  Only works on Beasts and Dragonkin.
    hibernate = {
        id = 2637,
        cast = 1.5,
        cooldown = 0,
        gcd = "spell",

        spend = 0.07,
        spendType = "mana",

        startsCombat = true,
        texture = 136090,

        handler = function ()
        end,

        copy = { 18657, 18658 },
    },


    -- Creates a violent storm in the target area causing 101 Nature damage to enemies every 1 sec, and increasing the time between attacks of enemies by 20%.  Lasts 10 sec.  Druid must channel to maintain the spell.
    hurricane = {
        id = 16914,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.81 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136018,

        handler = function ()
            removeBuff( "clearcasting" )
        end,

        copy = { 17401, 17402, 27012, 48467 },
    },


    -- Causes the target to regenerate mana equal to 225% of the casting Druid's base mana pool over 10 sec.
    innervate = {
        id = 29166,
        cast = 0,
        cooldown = 180,
        gcd = "spell",

        startsCombat = true,
        texture = 136048,

        toggle = "cooldowns",

        handler = function ()
            applyBuff( "innervate" )
        end,
    },


    -- The enemy target is swarmed by insects, decreasing their chance to hit by 3% and causing 144 Nature damage over 12 sec.
    insect_swarm = {
        id = 5570,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.08 end,
        spendType = "mana",

        talent = "insect_swarm",
        startsCombat = true,
        texture = 136045,

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Lacerates the enemy target, dealing 88 damage and making them bleed for 320 damage over 15 sec and causing a high amount of threat.  Damage increased by attack power.  This effect stacks up to 5 times on the same target.
    lacerate = {
        id = 48568,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or (15 - talent.shredding_attacks.rank) end, 
        spendType = "rage",

        startsCombat = true,
        texture = 132131,

        handler = function ()
            removeBuff( "clearcasting" )
            applyDebuff( "target", "lacerate", 15, min( 5, debuff.lacerate.stack + 1 ) )
        end,
    },


    -- Heals the target for 224 over 7 sec.  When Lifebloom completes its duration or is dispelled, the target instantly heals themself for 480 and the Druid regains half the cost of the spell.  This effect can stack up to 3 times on the same target.
    lifebloom = {
        id = 33763,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.28 end,
        spendType = "mana",

        startsCombat = true,
        texture = 134206,

        handler = function ()
            removeBuff( "clearcasting" )
        end,

        copy = { 48450, 48451 },
    },

    -- Finishing move that causes damage and stuns the target.  Non-player victim spellcasting is also interrupted for 3 sec.  Causes more damage and lasts longer per combo point:     1 point  : 249-250 damage, 1 sec     2 points: 407-408 damage, 2 sec     3 points: 565-566 damage, 3 sec     4 points: 723-724 damage, 4 sec     5 points: 881-882 damage, 5 sec
    maim = {
        id = 49802,
        cast = 0,
        cooldown = 10,
        gcd = "totem",

        spend = function() return (buff.clearcasting.up and 0) or (35 * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132134,

        usable = function() return combo_points.current > 0, "requires combo_points" end,

        handler = function ()
            applyDebuff( "target", "maim", combo_points.current )
            removeBuff( "clearcasting" )
            if combo_points.current == 5 then
                applyBuff("predators_swiftness")
            end
            set_last_finisher_cp(combo_points.current)
            spend( combo_points.current, "combo_points" )
        end,
    },


    -- Mangle (Bear)
    mangle_bear = {
        id = 33878,
        cast = 0,
        cooldown = 6,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or (20 - talent.ferocity.rank) end,
        spendType = "rage",

        startsCombat = true,
        texture = 132135,

        handler = function()
            removeDebuff( "mangle" )
            applyDebuff( "target", "mangle_bear", 60 )
            removeBuff( "clearcasting" )
        end,

        copy = { 33878, 33986, 33987, 48563, 48564 }
    },


    -- Mangle (Cat)
    mangle_cat = {
        id = 33876,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function () return (buff.clearcasting.up and 0) or (40 * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132135,

        handler = function()
            removeDebuff( "target", "mangle" )
            applyDebuff( "target", "mangle_cat" )
            removeBuff( "clearcasting" )
            gain( 1, "combo_points" )
        end,

        copy = { 33982, 33983, 48565, 48566 }
    },


    -- A strong attack that increases melee damage and causes a high amount of threat. Effects which increase Bleed damage also increase Maul damage.
    maul = {
        id = 48480,
        cast = 0,
        cooldown = 0,
        gcd = "off",

        spend = function()
            return (buff.clearcasting.up and 0) or ((15 - talent.ferocity.rank) * ((buff.berserk.up and 0.5) or 1))
        end,
        spendType = "rage",

        startsCombat = true,
        texture = 132136,

        nobuff = "maul",

        usable = function() return not buff.maul.up end,
        readyTime = function() return buff.maul.expires end,

        handler = function( rank )
            gain( (buff.clearcasting.up and 0) or ((15 - talent.ferocity.rank) * ((buff.berserk.up and 0.5) or 1)), "rage" )
            start_maul()
        end,

        copy = { 6807, 6808, 6809, 8972, 9745, 9880, 9881, 26996, 48479 }
    },


    -- Increases the friendly target's armor by 25 for 30 min.
    mark_of_the_wild = {
        id = 1126,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return glyph.wild.enabled and 0.12 or 0.24 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136078,

        handler = function ()
            applyBuff( "mark_of_the_wild" )
        end,

        copy = { 5232, 6756, 5234, 8907, 9884, 9885, 26990, 48469 },
    },


    -- Burns the enemy for 9 to 12 Arcane damage and then an additional 12 Arcane damage over 9 sec.
    moonfire = {
        id = 8921,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.18 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136096,

        handler = function ()
            removeBuff( "clearcasting" )
            applyDebuff( "target", "moonfire" )
        end,

        copy = { 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835, 26987, 26988, 48462, 48463 },
    },


    -- Shapeshift into Moonkin Form.  While in this form the armor contribution from items is increased by 370%, damage taken while stunned is reduced by 15%, and all party and raid members within 100 yards have their spell critical chance increased by 5%.  Single target spell critical strikes in this form instantly regenerate 2% of your total mana.  The Moonkin can not cast healing or resurrection spells while shapeshifted.    The act of shapeshifting frees the caster of Polymorph and Movement Impairing effects.
    moonkin_form = {
        id = 24858,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.13,
        spendType = "mana",

        talent = "moonkin_form",
        startsCombat = true,
        texture = 136036,

        handler = function ()
            swap_form( "moonkin_form" )
        end,
    },


    -- While active, any time an enemy strikes the caster they have a 100% chance to become afflicted by Entangling Roots (Rank 1). 3 charges.  Lasts 45 sec.
    natures_grasp = {
        id = 16689,
        cast = 0,
        cooldown = 60,
        gcd = "spell",

        startsCombat = true,
        texture = 136063,

        toggle = "cooldowns",

        handler = function ()
            applyBuff( "natures_grasp" )
        end,

        copy = { 16810, 16811, 16812, 16813, 17329, 27009, 53312 },
    },


    -- When activated, your next Nature spell with a base casting time less than 10 sec. becomes an instant cast spell.
    natures_swiftness = {
        id = 17116,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        talent = "natures_swiftness",
        startsCombat = true,
        texture = 136076,

        toggle = "cooldowns",

        handler = function ()
            applyBuff( "natures_swiftness" )
        end,
    },


    -- Heals a friendly target for 1883 to 2187. Heals for an additional 20% if you have a Rejuvenation, Regrowth, Lifebloom, or Wild Growth effect active on the target.
    nourish = {
        id = 50464,
        cast = 1.5,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.18 end,
        spendType = "mana",

        startsCombat = true,
        texture = 236162,

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Pounce, stunning the target for 3 sec and causing 2100 damage over 18 sec.  Must be prowling.  Awards 1 combo point.
    pounce = {
        id = 49803,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function() return (buff.clearcasting.up and 0) or (50 * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132142,

        handler = function ()
            removeBuff( "clearcasting" )
            applyDebuff( "target", "pounce", 3)
            applyDebuff( "target", "pounce_bleed", 18 )
            gain( 1, "combo_points" )
        end,
    },


    -- Allows the Druid to prowl around, but reduces your movement speed by 30%.  Lasts until cancelled.
    prowl = {
        id = 5215,
        cast = 0,
        cooldown = 10,
        gcd = "off",

        spend = 0,
        spendType = "energy",

        startsCombat = true,
        texture = 132089,

        handler = function ()
            applyBuff( "prowl" )
        end,
    },


    -- Rake the target for 178 bleed damage and an additional 1104 damage over 9 sec.  Awards 1 combo point.
    rake = {
        id = 48574,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function () return (buff.clearcasting.up and 0) or ((40 - talent.ferocity.rank) * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132122,

        readyTime = function() return debuff.rake.remains end,

        handler = function ()
            applyDebuff( "target", "rake" )
            removeBuff( "clearcasting" )
            gain( 1, "combo_points" )
        end,
    },


    -- Ravage the target, causing 385% damage plus 1771 to the target.  Must be prowling and behind the target.  Awards 1 combo point.
    ravage = {
        id = 48579,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function() return (buff.clearcasting.up and 0) or (60 * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132141,

        buff = "prowl",

        handler = function ()
            removeBuff( "clearcasting" )
            gain( 1, "combo_points" )
        end,
    },


    -- Returns the spirit to the body, restoring a dead target to life with 400 health and 700 mana.
    rebirth = {
        id = 20484,
        cast = 2,
        cooldown = 600,
        gcd = "spell",

        spend = 0.68,
        spendType = "mana",

        startsCombat = true,
        texture = 136080,

        toggle = "cooldowns",

        handler = function ()
            -- glyph.unburdened_rebirth.enabled removes reagent requirement; doesn't matter because addon shouldn't recommend rebirth.
        end,

        copy = { 20739, 20742, 20747, 20748, 26994, 48477 },
    },


    -- Heals a friendly target for 93 to 107 and another 98 over 21 sec.
    regrowth = {
        id = 8936,
        cast = 2,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.29 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136085,

        handler = function ()
            removeBuff( "clearcasting" )
            removeBuff( "predators_swiftness" )
        end,

        copy = { 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858, 26980, 48442, 48443 },
    },


    -- Heals the target for 40 over 15 sec.
    rejuvenation = {
        id = 774,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.18 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136081,

        handler = function ()
            removeBuff( "clearcasting" )
        end,

        copy = { 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299, 26981, 26982, 48440, 48441 },
    },


    -- Dispels 1 Curse from a friendly target.
    remove_curse = {
        id = 2782,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.08,
        spendType = "mana",

        startsCombat = true,
        texture = 135952,

        handler = function ()
        end,
    },


    -- Returns the spirit to the body, restoring a dead target to life with 65 health and 120 mana.  Cannot be cast when in combat.
    revive = {
        id = 50769,
        cast = 10,
        cooldown = 0,
        gcd = "spell",

        spend = 0.72,
        spendType = "mana",

        startsCombat = true,
        texture = 132132,

        handler = function ()
        end,

        copy = { 50768, 50767, 50766, 50765, 50764, 50763 },
    },


    -- Finishing move that causes damage over time.  Damage increases per combo point and by your attack power:     1 point: 784 damage over 12 sec.     2 points: 1352 damage over 12 sec.     3 points: 1920 damage over 12 sec.     4 points: 2488 damage over 12 sec.     5 points: 3056 damage over 12 sec.
    rip = {
        id = 49800,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function () return (buff.clearcasting.up and 0) or ((30 - ((set_bonus.tier10_2pc == 1 and 10) or 0)) * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 132152,

        usable = function() return combo_points.current > 0, "requires combo_points" end,
        readyTime = function() return debuff.rip.remains end, -- Clipping rip is a DPS loss and an unpredictable recommendation. AP snapshot on previous rip will prevent overriding

        handler = function ()
            applyDebuff( "target", "rip" )
            removeBuff( "clearcasting" )
            if combo_points.current == 5 then
                applyBuff("predators_swiftness")
            end
            set_last_finisher_cp(combo_points.current)
            spend( combo_points.current, "combo_points" )
            rip_tracker[target.unit].extension = 0
        end,
    },


    -- Finishing move that increases physical damage done by 30%.  Only useable while in Cat Form.  Lasts longer per combo point:     1 point  : 14 seconds     2 points: 19 seconds     3 points: 24 seconds     4 points: 29 seconds     5 points: 34 seconds
    savage_roar = {
        id = 52610,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function() return 25 * ((buff.berserk.up and 0.5) or 1) end,
        spendType = "energy",

        startsCombat = false,
        texture = 236167,

        usable = function() return combo_points.current > 0, "requires combo_points" end,

        handler = function ()
            applyBuff( "savage_roar" )
            if combo_points.current == 5 then
                applyBuff("predators_swiftness")
            end
            set_last_finisher_cp(combo_points.current)
            spend( combo_points.current, "combo_points" )
        end,
    },


    -- Shred the target, causing 225% damage plus 666 to the target.  Must be behind the target.  Awards 1 combo point.  Effects which increase Bleed damage also increase Shred damage.
    shred = {
        id = 48572,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function () return (buff.clearcasting.up and 0) or ((60 * ((buff.berserk.up and 0.5) or 1)) - (talent.shredding_attacks.rank * 9)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 136231,

        handler = function ()
            if glyph.shred.enabled and debuff.rip.up and rip_tracker[target.unit].extension < 6 then
                rip_tracker[target.unit].extension = rip_tracker[target.unit].extension + 2
                applyDebuff( "target", "rip", debuff.rip.remains + 2)
            end
            gain( 1, "combo_points" )
            removeBuff( "clearcasting" )
        end,
    },


    -- Soothes the target beast, reducing the range at which it will attack you by 10 yards.  Only affects Beast and Dragonkin targets level 40 or lower.  Lasts 15 sec.
    soothe_animal = {
        id = 2908,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.06,
        spendType = "mana",

        startsCombat = true,
        texture = 132163,

        handler = function ()
        end,

        copy = { 8955, 9901, 26995 },
    },


    -- You summon a flurry of stars from the sky on all targets within 30 yards of the caster, each dealing 145 to 167 Arcane damage. Also causes 26 Arcane damage to all other enemies within 5 yards of the enemy target. Maximum 20 stars. Lasts 10 sec.  Shapeshifting into an animal form or mounting cancels the effect. Any effect which causes you to lose control of your character will suppress the starfall effect.
    starfall = {
        id = 48505,
        cast = 0,
        cooldown = function() return glyph.starfall.enabled and 60 or 90 end,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.35 end,
        spendType = "mana",

        talent = "starfall",
        startsCombat = true,
        texture = 236168,

        toggle = "cooldowns",

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Causes 127 to 155 Arcane damage to the target.
    starfire = {
        id = 2912,
        cast = 3.5,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.16 end,
        spendType = "mana",

        startsCombat = true,
        texture = 135753,

        handler = function ()
            removeBuff( "clearcasting" )
            if glyph.starfire.enabled and debuff.moonfire.up then
                debuff.moonfire.expires = debuff.moonfire.expires + 3
                -- TODO: Cap at 3 applications.
            end
        end,

        copy = { 8949, 8950, 8951, 9875, 9876, 25298, 26986, 48464, 48465 },
    },


    -- When activated, this ability temporarily grants you 30% of your maximum health for 20 sec while in Bear Form, Cat Form, or Dire Bear Form.  After the effect expires, the health is lost.
    survival_instincts = {
        id = 61336,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        spend = 0,
        spendType = "energy",

        talent = "survival_instincts",
        startsCombat = true,
        texture = 236169,

        toggle = "cooldowns",

        handler = function ()
            applyBuff( "survival_instincts" )
        end,
    },


    -- Shapeshift into swift flight form, increasing movement speed by 280% and allowing you to fly.  Cannot use in combat.  Can only use this form in Outland or Northrend.    The act of shapeshifting frees the caster of Polymorph and Movement Impairing effects.
    swift_flight_form = {
        id = 40120,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.13,
        spendType = "mana",

        startsCombat = true,
        texture = 132128,

        handler = function ()
            swap_form( "swift_flight_form" )
        end,
    },


    -- Consumes a Rejuvenation or Regrowth effect on a friendly target to instantly heal them an amount equal to 12 sec. of Rejuvenation or 18 sec. of Regrowth.
    swiftmend = {
        id = 18562,
        cast = 0,
        cooldown = 15,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.16 end,
        spendType = "mana",

        talent = "swiftmend",
        startsCombat = true,
        texture = 134914,

        handler = function ()
            removeBuff( "clearcasting" )
            if glyph.swiftmend.enabled then return end
            if buff.rejuvenation.up then removeBuff( "rejuvenation" )
            elseif buff.regrowth.up then removeBuff( "regrowth" ) end
        end,
    },


    -- Swipe nearby enemies, inflicting 108 damage.  Damage increased by attack power.
    swipe_bear = {
        id = 48562,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or (20 - talent.ferocity.rank) end,
        spendType = "rage",

        startsCombat = true,
        texture = 134296,

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Swipe nearby enemies, inflicting 250% weapon damage.
    swipe_cat = {
        id = 62078,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function () return (buff.clearcasting.up and 0) or ((50 - talent.ferocity.rank) * ((buff.berserk.up and 0.5) or 1)) end,
        spendType = "energy",

        startsCombat = true,
        texture = 134296,

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Thorns sprout from the friendly target causing 3 Nature damage to attackers when hit.  Lasts 10 min.
    thorns = {
        id = 467,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.17 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136104,

        handler = function ()
            removeBuff( "clearcasting" )
            applyBuff( "thorns" )
        end,

        copy = { 782, 1075, 8914, 9756, 9910, 26992, 53307 },
    },


    -- Increases damage done by 80 for 6 sec.
    tigers_fury = {
        id = 50213,
        cast = 0,
        cooldown = function() return 30 - ((set_bonus.tier7_4pc == 1 and 3) or 0) end,
        gcd = "off",

        spend = 0,
        spendType = "energy",

        startsCombat = true,
        texture = 132242,

        usable = function() return not buff.berserk.up end,

        handler = function ()
            gain( 60, "energy" )
        end,
    },


    -- Shows the location of all nearby humanoids on the minimap.  Only one type of thing can be tracked at a time.
    track_humanoids = {
        id = 5225,
        cast = 0,
        cooldown = 1.5,
        gcd = "off",

        spend = 0,
        spendType = "energy",

        startsCombat = true,
        texture = 132328,

        handler = function ()
        end,
    },


    -- Heals all nearby group members for 364 every 2 seconds for 8 sec.  Druid must channel to maintain the spell.
    tranquility = {
        id = 740,
        cast = 0,
        cooldown = 480,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.7 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136107,

        toggle = "cooldowns",

        handler = function ()
            removeBuff( "clearcasting" )
        end,

        copy = { 8918, 9862, 9863, 26983, 48446 },
    },


    -- Shapeshift into travel form, increasing movement speed by 40%.  Also protects the caster from Polymorph effects.  Only useable outdoors.    The act of shapeshifting frees the caster of Polymorph and Movement Impairing effects.
    travel_form = {
        id = 783,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.13,
        spendType = "mana",

        startsCombat = true,
        texture = 132144,

        handler = function ()
            swap_form( "travel_form" )
        end,
    },


    -- You summon a violent Typhoon that does 400 Nature damage when in contact with hostile targets, knocking them back and dazing them for 6 sec.
    typhoon = {
        id = 50516,
        cast = 0,
        cooldown = function() return glyph.monsoon.enabled and 17 or 20 end,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or (0.25 * ( glyph.typhoon.enabled and 0.92 or 1 )) end,
        spendType = "mana",

        talent = "typhoon",
        startsCombat = true,
        texture = 236170,

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Stuns up to 5 enemies within 8 yds for 2 sec.
    war_stomp = {
        id = 20549,
        cast = 0.5,
        cooldown = 120,
        gcd = "off",

        startsCombat = true,
        texture = 132368,

        toggle = "cooldowns",

        handler = function ()
        end,
    },


    -- Heals up to 5 friendly party or raid members within 15 yards of the target for 686 over 7 sec. The amount healed is applied quickly at first, and slows down as the Wild Growth reaches its full duration.
    wild_growth = {
        id = 48438,
        cast = 0,
        cooldown = 6,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.23 end,
        spendType = "mana",

        talent = "wild_growth",
        startsCombat = true,
        texture = 236153,

        handler = function ()
            removeBuff( "clearcasting" )
        end,
    },


    -- Causes 18 to 21 Nature damage to the target.
    wrath = {
        id = 5176,
        cast = 1.5,
        cooldown = 0,
        gcd = "spell",

        spend = function() return (buff.clearcasting.up and 0) or 0.08 end,
        spendType = "mana",

        startsCombat = true,
        texture = 136006,

        handler = function ()
            removeBuff( "clearcasting" )
            removeBuff( "predators_swiftness" )
        end,

        copy = { 5177, 5178, 5179, 5180, 6780, 8905, 9912, 26984, 26985, 48459, 48461 },
    },
} )


-- Settings
local bearweaving_spells = {}
local bearweaving_instancetypes = {}
local predatorsswiftness_spells = {}
local flowerweaving_modes = {}

spec:RegisterSetting("min_roar_offset", 14, {
    type = "range",
    name = "Minimum Roar Offset",
    desc = "Sets the minimum number of seconds over the current rip duration required for Savage Roar recommendations",
    width = "full",
    min = 0,
    softMax = 14,
    step = 1,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.min_roar_offset = val
    end
})

spec:RegisterSetting("ferociousbite_enabled", true, {
    type = "toggle",
    name = "Ferocious Bite: Enabled?",
    desc = "Select whether or not ferocious bite should be used",
    width = "full",
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.ferociousbite_enabled = val
    end
})

spec:RegisterSetting("min_bite_sr_remains", 10, {
    type = "range",
    name = "Minimum Roar Remains For Bite",
    desc = "Sets the minimum number of seconds left on Savage Roar when deciding whether to recommend Ferocious Bite",
    width = "full",
    min = 0,
    softMax = 14,
    step = 1,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.min_bite_sr_remains = val
    end
})

spec:RegisterSetting("min_bite_rip_remains", 10, {
    type = "range",
    name = "Minimum Rip Remains For Bite",
    desc = "Sets the minimum number of seconds left on Rip when deciding whether to recommend Ferocious Bite",
    width = "full",
    min = 0,
    softMax = 14,
    step = 1,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.min_bite_rip_remains = val
    end
})

spec:RegisterSetting("max_bite_energy", 25, {
    type = "range",
    name = "Maximum Energy Used For Bite",
    desc = "Sets the energy allowed for Ferocious Bite recommendations during Berserk.\n\nWhen Berserk is down, any energy level is allowed as long as Minimum Rip and Minimum Roar settings are satisfied",
    width = "full",
    min = 18,
    softMax = 65,
    step = 1,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.max_bite_energy = val
    end
})

spec:RegisterSetting("flowerweaving_enabled", false, {
    type = "toggle",
    name = "Flowerweaving: Enabled?",
    desc = "Select whether or not flowerweaving should be used in AOE situations",
    width = "full",
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.flowerweaving_enabled = val
    end
})

spec:RegisterSetting("flowerweaving_mingroupsize", 10, {
    type = "range",
    name = "Flowerweaving: Minimum Group Size",
    desc = "Select the minimum number of players present in a group before flowerweaving will be recommended",
    width = "full",
    min = 0,
    softMax = 40,
    step = 1,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.flowerweaving_mingroupsize = val
    end
})

spec:RegisterSetting("flowerweaving_mode", "any", {
    type = "select",
    name = "Flowerweaving: Mode",
    desc = "Select the flowerweaving mode that determines when flowerweaving is recommended\n\n" ..
        "Selecting AOE will recommend flowerweaving in only AOE situations. Selecting Any will recommend flowerweaving in any situation.\n\n",
    width = "full",
    values = function()
        table.wipe(flowerweaving_modes)
        flowerweaving_modes.any = "any"
        flowerweaving_modes.dungeon = "aoe"
        return flowerweaving_modes
    end,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.flowerweaving_mode = val
    end
})

spec:RegisterSetting("bearweaving_enabled", false, {
    type = "toggle",
    name = "Bearweaving: Enabled?",
    desc = "Select whether or not bearweaving should be used",
    width = "full",
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.bearweaving_enabled = val
    end
})

spec:RegisterSetting("bearweaving_spell", "lacerate", {
    type = "select",
    name = "Bearweaving: Spell",
    desc = "Select the type of bearweaving that you want Hekili to recommend.\n\n" ..
        "In default priorities, selecting Lacerate will recommend your |cff00ccff[bear_lacerate]|r action list. " ..
        "Selecting Mangle will recommend your |cff00ccff[bear_mangle]|r action list. " ..
        "Custom priorities may ignore this setting.",
    width = "full",
    values = function()
            table.wipe(bearweaving_spells)
            bearweaving_spells.lacerate = class.abilityList.lacerate
            bearweaving_spells.mangle = class.abilityList.mangle_bear
            return bearweaving_spells
    end,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.bearweaving_spell = val
    end
})

spec:RegisterSetting("bearweaving_instancetype", "raid", {
    type = "select",
    name = "Bearweaving: Instance Type",
    desc = "Select the type of instance that is required before the addon recomments your |cff00ccff[bear_lacerate]|r or |cff00ccff[bear_mangle]|r\n\n" ..
        "Selecting party will work for a 5 person group or greater. Selecting raid will work for only 10 or 25 man groups. Selecting any will recommend bearweaving in any situation.\n\n",
    width = "full",
    values = function()
        table.wipe(bearweaving_instancetypes)
        bearweaving_instancetypes.any = "any"
        bearweaving_instancetypes.dungeon = "dungeon"
        bearweaving_instancetypes.raid = "raid"
        return bearweaving_instancetypes
    end,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.bearweaving_instancetype = val
    end
})

spec:RegisterSetting("bearweaving_bossonly", true, {
    type = "toggle",
    name = "Bearweaving: Boss Only?",
    desc = "Select whether or not bearweaving should be used in only boss fights, or whether it can be recommended in any engagement",
    width = "full",
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.bearweaving_bossonly = val
    end
})

spec:RegisterSetting("predatorsswiftness_enabled", false, {
    type = "toggle",
    name = "Predator's Swiftness: Enabled?",
    desc = "Select whether or not predator's swiftness procs should be consumed by casting a nature spell",
    width = "full",
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.predatorsswiftness_enabled = val
    end
})

spec:RegisterSetting("predatorsswiftness_spell", "regrowth", {
    type = "select",
    name = "Predator's Swiftness: Spell",
    desc = "Select which spell should be recommended when predator's swiftness consumption is recommended",
    width = "full",
    values = function()
        table.wipe(predatorsswiftness_spells)
        predatorsswiftness_spells.regrowth = class.abilityList.regrowth
        predatorsswiftness_spells.wrath = class.abilityList.wrath
        return predatorsswiftness_spells
    end,
    set = function( _, val )
        Hekili.DB.profile.specs[ 11 ].settings.predatorsswiftness_spell = val
        class.abilities.predatorsswiftness_spell = class.abilities[ val ]
    end
})


-- Options
spec:RegisterOptions( {
    enabled = true,

    aoe = 3,

    gcd = 1126,

    nameplates = true,
    nameplateRange = 8,

    damage = false,
    damageExpiration = 6,

    potion = "speed",

    -- package = "",
    -- package1 = "",
    -- package2 = "",
    -- package3 = "",
} )


-- Default Packs
spec:RegisterPack( "Balance (IV)", 20220926, [[Hekili:vwvtVTnpm4Flffiyd71oF12To0MdfDhsp0EWf9OSKLPteISKHKCmYf9BFuoFzNLG3weGaBrYh9qYhstgtENKKZCa51jJMmz09tUlE8VMo5M7jjUnvajPIXxXwGpOyL4)pXKmfV98nsnlpeVvxBchT05QS)E4WMMMybFt0AqOSXCD5WgTtUkIlzwRGpmBlgr5MArEuELnQAnez0oMtOvrCTwMRBu2iwMqkCcWssYQfs3Cfj7809NilQao51XJrEiYZHTUcwoj59LcRNwzeAJWTXtdVLXSqUNQvEQBj4PZ5OHpce2txG0cIXu0OlesmXU(ApDxI7PphyTN(T5F8D)lbltUZttGkhuMbg8vKy(x8VW4HSXgxzaSeKXC)4XHLATALqLwOnLxWdMzvQUifjvAJqM3bj0AbdmciTqyG)tu8OJjbLlwuImDnKN2XCmOyzsiFWvobhVYfdwy01vPLTS0o72EWQX(x4wvmxTb6AY6yMcMu29muySetKadchUgsbfuITPzJhGUVaCX5cmqSC9W0rDJCzTXi4mfCUy76i2haUl12WmLbFZQlkIbUuuzHuzTIzIdsKdzx3ydf59vOs96wRH(07V98B)2t)JAHqbyHcpN6eQvy5iERhDikQ9nOIclQmohKGH50g7fOsDv37VgpxGQHpN3Tf4DS9moBGsgwmMXzwxQtu2R50GSA5)eOvlpxGKeSyQWSgNMMxwPnUWaWK9zTNkXEwOsqsy1ULAd62HHcssR12TfqbRw6WhFTD7XoHg5jschNVWcld3D8)Rm90bE6vHwW2oy41EAupDMNElYMw(rs6GbXHlacx(bB9vWDzf660UUUxrFIp3CXCPVoTLvJBz7jADp9bpD6OJ30U5Ka63(Lq)iehgycGC3fb5cJhNuIpcB3XRaY)8IiVDa6yK7hUcr9RVcFQRocYHjKak3)vqzNQUTm1rz3R3UJDJh95aU34YLaUDsdr1f(QWUT1hMa6wB2VD)e1vpX6P74777(FK)(d]] )

spec:RegisterPack( "Feral DPS (IV)", 20230106, [[Hekili:vVXARTTs2FlHlySAAuLSTsAa7a7YLfA2lDl4YE)MEe5XoIklzgjNCZsq)23ZmJgPrZlzN0TWcHMynN58(Tvd9d)E46nj1OWVoZB2CpFVRD9UD21ZMfUU(LdOW1hss)rYo4pks2d)7)aHtYBI)9VTUjE6x(3oeaEjVmzdbrvLhXPaqHRF4ywE9xkcFqp29bypGsd)Qp8xpMTzdIbkQknC9Fww)h)ZMyoLWhZ20e)nCwjoRodv1CFZ9FVC3UCutCYMNsksrW54Y6K6SYc4VqPL73Jk2q)CvtCg8W6hbOtZtQGpxEGEGlW64YTz5ad)BnX)TV9hnXpn3DHR3v(U(UZAI)TM7tszWEGI1hsQVC1N2NG)ru52iaNrpNLV5JzBxDXXdtU4HJB36UlBBT4PUhpOhn1pwIlQAVSEqstQJ2wI3BfOdLu5((UtHNDScfLvJ2xj(qoG9pztggf9akb3rfYhEgL8uwXUO8KuWeuJIqfjpKJ20kGdVeiEtMUbrpHFb3QAWPzvWRVYUXdiCfc)dauNjYGIr7tYkQwo3nW0z357giY1YAycFVnV8zuhNpKH5Sj7tP5aRNMuvda2)0EwCsAzz(MYNlCRZ2bpnA7r8lDSYQfaFIkq4DV4MEeJrf1lVoyYuc39ertH2dUO3n71xhYr7l3GIskEzY0lALsC2bg12)qz0HYSI6QomcAUHqj8joNamIdGnBgSoSiBymQPVXXrutJpweX(uuEwv9hjPaOUir7tkGaqzpg2t7u)6DxoncWzTrDkFJebIGGeeL4QQNb3Pcufnsu9PdPt35rDaqmpqEfiqnRiR6reok9aOH17SP3Al7qTWBu2NKziPKPDOeQntbHiY(INcY0HiX7PKjQpxuknl02eeodbkbWqSLK5MczRFwcEFjoc0DhP3HWK1j4DOA3YJ1vzBqZKrNqS3hjjZk3UnAx6Mv(e0kPUM7nACWfYo8hpyi4y5Q5QNWdpcCK5Z28geUYEEd)a5REaGh0jSAMFeuUrfO)QMjHuYxL8eu4ncxMG7stYqXGJGcPfB(KVNm(fGrP(HwigMYrHf09Sw26k4oqW)FX5YvEtg(Kl3NvqVbXqwHQx6V4YPt1fnCLVZhuvZvpcop9(OsrvTmoyQrdl3oUIwnXkxftEKjvlCgVOVozyLITgN8de)gAfBsk)HU1xX5d4Qmg5svM9d(E3TsMHv0ENGcGL5wwh0MphWIrvrpiIb8TOJeLnvpfKt6DLbs(MfAijuzAw5XQOhYyLr6Ec5bD511BaNmvkjZkWzoQ9IKd01BZqF(7wrC6PxHCq7tngdjaEfMd97nlRsZnss1nQzn4rA6dpn7NsV4zAZK1Y2WfjmqhY6cpCCKzTv(EkYNAlVtNAT)IPYEcZuBFIv5yoWaYaVWtpW3TAUdHHNAP9jfu54yOTc9ThQy9L1f6AKEqHuoNOV7AdD4Q2D8pTgV)P28SupmK2PoZgpw4PddV1wcAV(iLTBHsSGYf6kvRvNRLEpNDGMVv3HN(OwMS6c2xtTepIvx0ony0aG)qfyqOh1qf4zWjWmM3NCmxfVx0wk7yUzbsB2KQhlpMVjICtZ0uCMhsJcD1kF9vkLysBVY5ZUIDkjJnXw2hQpU7gVbXiDZG3sNEBgjbLLeoN8CLRU1cJkk26ZSgySL8L3AZestNsESzGoDpCdP707eOgoC(QmfhFMa9Z3TVdVVDNEs3cTXXcQDYjuxwUJ3QzbQfjn6o6i700XOVDFBJzehsa12eeLJL(EtmiVMvTMCg7a5xMR4fNjVZ9nfDiv3uczqd11NaTMLN3n5M(9NmcwL29q46NG8ta40LkpZF2SBdx)CcUaK3QW1Fz)HsCnzLW30eZWBtmzxhvUn3hUM(xKDvdyf(1xPlaVvVg(3HhJHoWXzjHRVOj2yJ1nXtAILwHr4Ag1cxR0LEynWRgj0qdut8YM45EukmTjg4cBTN2e)6RuGuxWb7iTPDaASciIEi4JEeFxtCqtStVCjuHoCTqAcIweKW5gLqB14b6a8IFqpzAl)qq5cjuYbzWeTIusPvOoQSK7nOU8KM4pbCGhy4AhnUvGcS5BqCe5SJagj37AJ3BqJPutSME30)8ob5QM4HdAYSMmpg5tUSjwA1lunH)c6rtP)ORlAkz8bRFt8hKDdKK2BmkTAt4s4sPf2iGAYGFeK(5Z1WRMYx0K3nYPjt9T2n1uUwVEcu9c(UaHiOdOW44ZOQFjvJtInLtnCvVe1n3l1sQt8)arszHxQQbb7jbvuMwox4PQ0hUAhr9U82CmP(9nNDSp3w3sLy6MPYhis)aQg2S6tLXENkXEesLhZ5c1UfQr8V4UlkvkGdL2lvxbbwew)S)KqznjiicMU9unssObxRFFvc1ahS(nQoroz(zuQvN8OX(cg(B8gPoSV5S62shEkXKcRT6n6pzYqponewpMwIiKUWH(JorHui2Ztt6yFZL0ykn79OmHxQrJbBwGyjbL(uOTP40fXRbbl8SHG7wXXGJiEmV2ntoweY4WnrC)rlf3gy1HwPiJDP3vUxFpCQdQI3C1vPodfzFTtnO5e(KdMK5RdgvAnezoEhFC9XuX2xfAmASWq1BytXlKPwEmRqsgBOu2wya3(rc4q39MuiAf4TZ3xGK97bqyUeWOblCLQ6xRDRgZGZ(QoTJ5cagB3NeQ5QpyuuD67gyZH1CsEZoLCMvui)FQpNzx9PSmM9F95uzEgtPAj45xKxSaTgFQqRojJyLVHLSZAuJL5Jgj9QENBHosh(wkWMApI9cOjSAc7ZAnAu27Ml4y1(uqMFNs65cd7fHCU87wIGb0wmInhp9ral8onrxvE0nWM8uGcVwje6Rli70iF7xoH9H2KP5jJ6tz4TEKXPaRes3lLNU9k1pNWWxEq2l9ieTZow3BHO(Ph5gFnVVH2x3KKmWEneTxWYSyZY3BRoyDVjZ662gXJCKDpzwChVQGHDpDYQdP9HyDmhjJNMf)yiOwDC9arnF33INutiMtpAUC84nckv41EEOXu)leBOqFZzAs5y1xYsovb9iAhU856hpROLHr8I1IoxN7aVrk33tu2x3Z552ZTjTFTnJAN4Z(Q)lgGaH4xacZYnlW2OzKUi8u6Yzq7MYnzqy2ZBZYVjIso1EmMsgoTeFOgzjBO7jg1I2ABEqWSW1(jeoBPRvBoewZcmQeQRDXBeLXUENKlwmSZQ)ppQsBpOcVlaVhx)(axPfF25Ep89fGfZ(zPPHf7H1SN(7lmtSCbF)lM0yV9HwaqUDGOjgeBEufZlEkyKVFmaKB1RiV(0IMnpZWVWO53NcFKk3K45Kk0M)vHU)NdLCK08z46FhT9)KK(if(W)7]] )