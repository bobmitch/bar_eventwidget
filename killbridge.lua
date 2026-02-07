local socket = socket
-- Load the JSON utility
Json = Json or VFS.Include('common/luaUtilities/json.lua')
local json_util = Json

function widget:GetInfo()
    return {
        name    = "KillBridgeTCP",
        desc    = "TCP Network Bridge",
        author  = "FilthyMitch",
        enabled = true
    }
end

local client = nil
local lastConnAttempt = 0
local RECONNECT_INTERVAL = 5 
local lastUpdateFrame = -1

local function Connect()
    if not socket then return false end
    if client then client:close() end

    client = socket.tcp()
    client:settimeout(0)
    
    local success, err = client:connect("127.0.0.1", 5005)
    if success or err == "already connected" or err == "timeout" then
        Spring.Echo("KillBridge: Connected")
        return true
    end
    client = nil
    return false
end

function widget:Update(dt)
    if not client then
        lastConnAttempt = lastConnAttempt + dt
        if lastConnAttempt >= RECONNECT_INTERVAL then
            lastConnAttempt = 0
            Connect()
        end
    end
end

local function SendData(dataTable)
    if not client then return end

    local myPlayerID = Spring.GetMyPlayerID()
    local name, _, _, _, allyTeamID = Spring.GetPlayerInfo(myPlayerID)
    local myTeamID = Spring.GetMyTeamID()
    
    -- Enrich the table
    dataTable["playerName"] = name
    dataTable["allyTeamID"] = allyTeamID
    dataTable["myPlayerID"] = myPlayerID
    dataTable["myTeamID"] = myTeamID
    dataTable['gameTime'] = Spring.GetGameSeconds()

    -- Use the utility to encode the entire table
    -- We add the newline manually for the TCP receiver to know the message ended
    local status, jsonString = pcall(json_util.encode, dataTable)
    
    if not status then
        Spring.Echo("KillBridge: JSON Encoding Error: " .. tostring(jsonString))
        return
    end

    local success, err = client:send(jsonString .. "\n")
    if not success and err ~= "timeout" then
        Spring.Echo("KillBridge: Send failed (" .. tostring(err) .. ")")
        client:close()
        client = nil
    end
end

function widget:Initialize()
    -- Attempt initial connection
    Connect()
    if Spring.GetGameFrame() > 0 then
        -- widget started late or toggled on mid-game
        SendData({event="WidgetInitializedMidGame"})
    else
        SendData({event="WidgetInitializedPreGame"})
    end
end

function widget:GameStart()
    SendData({event="GameStart"})
end

local function GetUnitName(uDefID)
    -- might do this server-side instead
    local ud = UnitDefs[uDefID]
    if not ud then return "Unknown" end
    return ud.name
end

local function GetPlayerNameFromTeam(teamID)
    if teamID == nil then return "Unknown" end
    if teamID == Spring.GetGaiaTeamID() then return "Environment/Gaia" end

    -- leaderID is the PlayerID of the person controlling this team
    local _, leaderID, _, isAI, side, allyTeamID = Spring.GetTeamInfo(teamID)

    if isAI then
        -- For AIs, we get their name from GetAIInfo
        local _, name, _, shortName = Spring.GetAIInfo(teamID)
        return name or shortName or "AI"
    end

    if leaderID then
        local name = Spring.GetPlayerInfo(leaderID)
        return name or "Unknown Player"
    end

    return "No Player"
end



-- pre-relation change version
--[[ function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam == Spring.GetMyTeamID() then
        local ud = UnitDefs[unitDefID]
        SendData({
            event         = "UnitFinished",
            unitName      = ud.name,
            unitID        = unitID,
            unitDefID     = unitDefID,
            unitTeam      = unitTeam,
            unitCategory  = ud.modCategories, -- json.lua handles this table automatically
            unitMetalCost = ud.metalCost
        })
    end
end ]]

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    local myTeamID = Spring.GetMyTeamID()
    local myAllyTeamID = Spring.GetMyAllyTeamID()
    local unitAllyTeamID = Spring.GetTeamAllyTeamID(unitTeam)
    local ud = unitDefID and UnitDefs[unitDefID]
    local tier = ud and ud.customParams and ud.customParams.techlevel or "1"

    local relation = "enemy"
    if unitTeam == myTeamID then
        relation = "self"
    elseif unitAllyTeamID == myAllyTeamID then
        relation = "ally"
    end

    local ud = UnitDefs[unitDefID]
    
    SendData({
        event         = "UnitFinished",
        relation      = relation, -- "self", "ally", or "enemy"
        unitName      = ud and ud.name or "Unknown",
        unitID        = unitID,
        unitTeam      = unitTeam,
        unitTier      = tier,
        unitDefID     = unitDefID or -1,
        unitCategory  = ud.modCategories, -- json.lua handles this table automatically
        unitMetalCost = ud and ud.metalCost or 0
    })
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
    local myTeamID = Spring.GetMyTeamID()
    -- if we have valid unitDefID then proceed
    if unitDefID then
        -- since we can only track damage TAKEN by any LOS unit, we limit to just our units
        if unitTeam ~= myTeamID then return end
        -- attacker team always nil
        SendData({
            event           = "UnitDamaged",
            unitID          = unitID or -1,
            unitDefID       = unitDefID or -1,
            unitTeam        = unitTeam or -1,
            damage          = damage or 0,
            paralyzer       = paralyzer or 0,
            weaponDefID     = weaponDefID or -1,
            projectileID    = projectileID or -1,
            attackerID      = attackerID or -1,
            attackerDefID   = attackerDefID or -1,
            attackerTeam    = attackerTeam or -1
        })
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
    -- try and get the best attacker info we can
    local actualAttackerID = attackerID or Spring.GetUnitLastAttacker(unitID)
    local actualAttackerTeam = attackerTeam
    local actualAttackerDefID = attackerDefID

    -- if we found an ID via fallback, we need to manually look up its Team and DefID
    if actualAttackerID and (not actualAttackerTeam or actualAttackerTeam == -1) then
        actualAttackerTeam = Spring.GetUnitTeam(actualAttackerID)
    end
    if actualAttackerID and (not actualAttackerDefID or actualAttackerDefID == -1) then
        actualAttackerDefID = Spring.GetUnitDefID(actualAttackerID)
    end

    -- self d issue, fog of war killer, ignore
    if actualAttackerID == nil or actualAttackerTeam == nil then return end

    local myTeamID = Spring.GetMyTeamID()

    -- only care about units I own killing or being killed
    if (unitTeam ~= myTeamID and actualAttackerTeam ~= myTeamID) then return end

    -- 3. RESOLVE DATA: Handle names and cumulative damage
    local myAllyTeamID = Spring.GetTeamAllyTeamID(myTeamID)
    local unitAllyTeamID = Spring.GetTeamAllyTeamID(unitTeam)
    local attackerAllyTeamID = actualAttackerTeam and Spring.GetTeamAllyTeamID(actualAttackerTeam) or -1

    local ud = unitDefID and UnitDefs[unitDefID]
    local aud = actualAttackerDefID and UnitDefs[actualAttackerDefID]

    local victimPlayerName = GetPlayerNameFromTeam(unitTeam)
    local attackerPlayerName = GetPlayerNameFromTeam(actualAttackerTeam)

    -- Get cumulative damage for the attacker (if it's our unit)
    local attackerTotalDamage = 0
    if actualAttackerTeam == myTeamID and actualAttackerID then
        attackerTotalDamage = Spring.GetUnitRulesParam(actualAttackerID, "damageDealt") or 0
    end

    -- don't even know what unit died 
    if not ud then 
        ud = {name="Unknown", metalCost=0, modCategories={}}
    end

    -- don't know what attacked?
    if not aud then 
        aud = nil
    end

    -- standard destruction
   
    SendData({
        event               = "UnitDestroyed",
        myAllyTeamID        = myAllyTeamID,
        unitAllyTeamID      = unitAllyTeamID,
        attackerAllyTeamID  = attackerAllyTeamID,
        
        unitID             = unitID,
        unitDefID          = unitDefID,
        unitName           = ud and ud.name or "Unknown",
        unitMetalCost      = ud and ud.metalCost or 0,
        unitCategory       = ud and ud.modCategories or {},
        unitTier           = ud and ud.customParams and ud.customParams.techlevel or "1",
        
        unitTeam           = unitTeam,
        victimPlayer       = victimPlayerName,
        
        attackerID         = actualAttackerID or -1,
        attackerDefID      = actualAttackerDefID or -1,
        attackerName       = aud and aud.name or "Explosion/Nature/Unknown",
        attackerTeam       = actualAttackerTeam or -1,
        attackerPlayer     = attackerPlayerName,
        attackerMetalCost   = aud and aud.metalCost or 0,
        attackerCategory    = aud and aud.modCategories or {},
        attackerTier        = aud and aud.customParams and aud.customParams.techlevel or "1",

        attackerCumulativeDamage = attackerTotalDamage
    })
end


function widget:GameFrame(frame)
    -- every 10 seconds worth of gameframes
    if frame % 300 == 0 then
        local teamID = Spring.GetMyTeamID()

        -- m
        local m_inc, m_use, m_stor, m_pull, m_share, m_sent, m_rec, m_excs = Spring.GetTeamResourceStats(teamID, "metal")
        
        -- e
        local e_inc, e_use, e_stor, e_pull, e_share, e_sent, e_rec, e_excs = Spring.GetTeamResourceStats(teamID, "energy")

        -- combat
        local dmg_dealt, dmg_rec = 0, 0
        if Spring.GetTeamDamageStats then
            dmg_dealt, dmg_rec = Spring.GetTeamDamageStats(teamID)
        end

        -- stats
        local u_killed, u_died, u_capBy, u_capFrom, u_rec, u_sent = Spring.GetTeamUnitStats(teamID)

        if SendData then
            SendData({
                event = "FullStatsUpdate",
                frame = frame,
                metal = {
                    income   = m_inc   or 0,
                    usage    = m_use   or 0,
                    storage  = m_stor  or 0,
                    pull     = m_pull  or 0,
                    share    = m_share or 0,
                    sent     = m_sent  or 0,
                    received = m_rec   or 0,
                    excess   = m_excs  or 0
                },
                energy = {
                    income   = e_inc   or 0,
                    usage    = e_use   or 0,
                    storage  = e_stor  or 0,
                    pull     = e_pull  or 0,
                    share    = e_share or 0,
                    sent     = e_sent  or 0,
                    received = e_rec   or 0,
                    excess   = e_excs  or 0
                },
                combat = {
                    damage_dealt    = dmg_dealt or 0,
                    damage_received = dmg_rec   or 0,
                    units_killed    = u_killed  or 0,
                    units_died      = u_died    or 0,
                    units_captured  = u_capBy   or 0,
                    units_lost      = u_capFrom or 0,
                    units_received  = u_rec     or 0,
                    units_sent      = u_sent    or 0
                }
            })
        end
    end
end


function widget:Shutdown()
    if client then client:close() end
end
