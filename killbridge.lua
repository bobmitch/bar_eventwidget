local socket = socket
-- Load the JSON utility
Json = Json or VFS.Include('common/luaUtilities/json.lua')
local json_util = Json

local overflowFramesMetal = 0
local overflowFramesEnergy = 0
local lastMetalOverflow = false
local lastEnergyOverflow = false

local THRESHOLD_METAL_COST = 3000
local seenUnitTypes = {} -- Tracks unitDefIDs already reported

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
local unitDefsSent = false

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

local function SendFilteredUnitDefs()
    Spring.Echo("KillBridge: Preparing to send filtered UnitDefs...")
    if not client then return end
    
    local filteredDefs = {}
    
    Spring.Echo("KillBridge: Compiling filtered UnitDefs...")

    for id, ud in pairs(UnitDefs) do
        -- Ensure we are looking at a valid unit definition table
        if type(ud) == "table" then
            filteredDefs[tostring(id)] = {
                id                 = id,
                name               = ud.name,
                canFight           = ud.canFight,
                canCloak           = ud.canCloak,
                canFly             = ud.canFly,
                canSubmerge        = ud.canSubmerge,
                metalCost          = ud.metalCost,
                energyCost         = ud.energyCost,
                health             = ud.health,
                isAirUnit          = ud.isAirUnit,
                isBomber           = ud.isBomber,
                isBuilder          = ud.isBuilder,
                isBuilding         = ud.isBuilding,
                isExtractor        = ud.isExtractor,
                isFactory          = ud.isFactory,
                isFeature          = ud.isFeature,
                isFighterAirUnit   = ud.isFighterAirUnit,
                isFirePlatform     = ud.isFirePlatform,
                isGroundUnit       = ud.isGroundUnit,
                isHoveringAirUnit  = ud.isHoveringAirUnit,
                isImmobile         = ud.isImmobile,
                isMobileBuilder    = ud.isMobileBuilder,
                isStaticBuilder    = ud.isStaticBuilder,
                isStrafingAirUnit  = ud.isStrafingAirUnit,
                isTransport        = ud.isTransport,
                techLevel          = (ud.customParams and ud.customParams.techlevel) or "1"
            }
        end
    end

    SendData({
        event = "AllUnits",
        unitDefs = filteredDefs
    })
    
    Spring.Echo("KillBridge: Filtered UnitDefs sent.")
end

function widget:Initialize()
    -- Attempt initial connection
    Connect()
    if Spring.GetGameFrame() > 0 then
        -- widget started late or toggled on mid-game
        SendData({event="WidgetInitializedMidGame"})
    else
        -- set timeout to 2 seconds for possible large packets
        client:settimeout(2)

        SendData({event="WidgetInitializedPreGame"})
        -- safe to send all unit defs now since we haven't started the game yet
        -- JS has cached version of this, but nice to have 'live'
        SendFilteredUnitDefs()

        -- set timeout back to non-blocking for regular updates
        client:settimeout(0)
    end
end

function widget:GameStart()
    seenUnitTypes = {}
    SendData({event="GameStart"})
end

function widget:GamePaused(playerID, isPaused)
    local playerName = Spring.GetPlayerInfo(playerID) or "Unknown"
    
    if isPaused then
        SendData({event = "GamePaused", player = playerName})
    else
        SendData({event = "GameResumed", player = playerName})
    end
end

local gameEnded = false
function widget:GameOver(winningAllyTeams)
    if gameEnded then return end
    gameEnded = true

    local myAllyTeamID = Spring.GetMyAllyTeamID()
    local iAmWinner = false
    for _, allyID in ipairs(winningAllyTeams) do
        if allyID == myAllyTeamID then
            iAmWinner = true
            break
        end
    end

    local teamID = Spring.GetMyTeamID()
    local history = Spring.GetTeamStatsHistory(teamID)

    SendData({
        event = "GameOver",
        victory = iAmWinner,
        duration = Spring.GetGameSeconds(),
        winningTeams = winningAllyTeams,
        history = history
    })
end

function widget:UnitEnteredLos(unitID, allyTeam)
    local unitDefID = Spring.GetUnitDefID(unitID)
    if not unitDefID or seenUnitTypes[unitDefID] then 
        return -- Exit if unknown or already "discovered" this game
    end

    local ud = UnitDefs[unitDefID]
    
    -- Filter by Metal Cost
    if ud and ud.metalCost >= THRESHOLD_METAL_COST then
        -- Mark as seen immediately to avoid race conditions or double-processing
        seenUnitTypes[unitDefID] = true
        
        local unitTeam = Spring.GetUnitTeam(unitID)
        local tier = ud.customParams and ud.customParams.techlevel or "1"
        
        SendData({
            event         = "UnitEnteredLos",
            subEvent      = "FirstDetection", -- Helpful for your relay app logic
            unitID        = unitID,
            unitDefID     = unitDefID,
            unitName      = ud.name,
            unitTeam      = unitTeam,
            unitTier      = tier,
            unitMetalCost = ud.metalCost,
            ownerName     = GetPlayerNameFromTeam(unitTeam)
        })
        
        Spring.Echo("KillBridge: First " .. ud.name .. " detected! Alerting relay.")
    end
end


function widget:Shutdown()
    -- send a final goodbye so the Go relay knows we didn't just crash
    if client then
        SendData({event = "SocketClosing", reason = "Widget Shutdown"})
        client:close()
        client = nil
    end
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
        -- attacker team always nil, only send data needed for damage to our units, and we can get the attacker info later when/if the unit dies
        SendData({
            event           = "UnitDamaged",
            unitID          = unitID or -1,
            unitDefID       = unitDefID or -1,
            damage          = damage or 0
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
    -- new - send unitXP for triggers (pacifist, or maybe killing high value targets) 
    SendData({
        event               = "UnitDestroyed",
        myAllyTeamID        = myAllyTeamID,
        unitAllyTeamID      = unitAllyTeamID,
        attackerAllyTeamID  = attackerAllyTeamID,
        
        unitID             = unitID,
        unitDefID          = unitDefID,
        unitXP            = Spring.GetUnitExperience(unitID) or 0,
        
        unitTeam           = unitTeam,
        victimPlayer       = victimPlayerName,
        
        attackerID         = actualAttackerID or -1,
        attackerDefID      = actualAttackerDefID or -1,
        attackerTeam       = actualAttackerTeam or -1,
        attackerPlayer     = attackerPlayerName,

        attackerCumulativeDamage = attackerTotalDamage
    })
end


function widget:GameFrame(frame)
    -- get vars used in multiple places
    local teamID = Spring.GetMyTeamID()
    -- m
    local m_inc, m_use, m_stor, m_pull, m_share, m_sent, m_rec, m_excs = Spring.GetTeamResourceStats(teamID, "metal")
    -- e
    local e_inc, e_use, e_stor, e_pull, e_share, e_sent, e_rec, e_excs = Spring.GetTeamResourceStats(teamID, "energy")

    -- Check Metal Status
    local isMetalOverflowing = (m_excs or 0 > 0)
    if isMetalOverflowing then
        overflowFramesMetal = 0
        if not lastMetalOverflow then
            SendData({event="OverflowStatusChanged", resource="metal", status="1"})
            lastMetalOverflow = true
        end
    else
        overflowFramesMetal = overflowFramesMetal + 1
        if lastMetalOverflow then
            SendData({event="OverflowStatusChanged", resource="metal", status="0"})
            lastMetalOverflow = false
        end
    end

    -- Check Energy Status
    local isEnergyOverflowing = (e_excs or 0 > 0)
    if isEnergyOverflowing then
        overflowFramesEnergy = 0
        if not lastEnergyOverflow then
            SendData({event="OverflowStatusChanged", resource="energy", status="1"})
            lastEnergyOverflow = true
        end
    else
        overflowFramesEnergy = overflowFramesEnergy + 1
        if lastEnergyOverflow then
            SendData({event="OverflowStatusChanged", resource="energy", status="0"})
            lastEnergyOverflow = false
        end
    end

    -- Full Stats Update: Send a comprehensive stats update every 10 seconds (300 frames at 30 FPS)
    -- every 10 seconds worth of gameframes
    if frame % 300 == 0 then

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

        -- get ally stats too

        local myAllyTeamID = Spring.GetMyAllyTeamID()
        local teamList = Spring.GetTeamList(myAllyTeamID)
        local allTeamStats = {}

        for i=1, #teamList do
            local teamID = teamList[i]
            local m_inc, m_use, m_stor, m_pull, m_share, m_sent, m_rec, m_excs = Spring.GetTeamResourceStats(teamID, "metal")
            local e_inc, e_use, e_stor, e_pull, e_share, e_sent, e_rec, e_excs = Spring.GetTeamResourceStats(teamID, "energy")
            
            -- Get the name for the JS side
            local name = GetPlayerNameFromTeam(teamID)

            allTeamStats[teamID] = {
                playerName = name,
                metal = { income = m_inc, usage = m_use, storage = m_stor, pull = m_pull, sent = m_sent },
                energy = { income = e_inc, usage = e_use, storage = e_stor, pull = e_pull, sent = e_sent }
            }
        end

        SendData({
            event = "AllyStatsUpdate",
            frame = frame,
            teams = allTeamStats
        })
    end
end


function widget:Shutdown()
    if client then client:close() end
end
