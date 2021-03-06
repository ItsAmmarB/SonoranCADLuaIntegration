---------------------------------------------------------------------------
-- EDIT CONFIG IN config.lua BEFORE USING!
---------------------------------------------------------------------------

--[[
    CUSTOM EVENT DOCUMENTATION

 SERVER EVENT ONLY

 EVENT: cadIncomingCall
 PARAMS:
      emergency = true/false (911 or 311 call)
      caller = name of caller
      location = street / cross street string
      description = description of call
      source = playerId

--]]
---------------------------------------------------------------------------
-- Server Event Handling **DO NOT EDIT UNLESS YOU KNOW WHAT YOU ARE DOING**
---------------------------------------------------------------------------

if debugMode == nil then
    debugMode = false
end

function debugPrint(msg)
    if debugMode then
        print(msg)
    end
end
        ---------------------------------
        -- Unit Panic
        ---------------------------------
-- shared function to send panic signals
function sendPanic(source)
    -- Determine identifier
    local identifier = GetIdentifiers(source)[primaryIdentifier]
    -- Process panic POST request
    PerformHttpRequest(apiURL, function(statusCode, res, headers) 
        if statusCode ~= 200 then
            print(("[SonoranCAD] API error sending panic button: %s %s %s"):format(statusCode, res, headers))
        end
    end, "POST", json.encode({['id'] = communityID, ['key'] = apiKey, ['type'] = 'UNIT_PANIC', ['data'] = {{ ['isPanic'] = true, ['apiId'] = identifier}}}), {["Content-Type"]="application/json"})
end

-- Creation of a /panic command
RegisterCommand('panic', function(source, args, rawCommand)
    sendPanic(source)
end, false)

-- Client Panic request (to be used by other resources)
RegisterServerEvent('cadSendPanicApi')
AddEventHandler('cadSendPanicApi', function(source)
    sendPanic(source)
end)

-- Toggles API sender.
RegisterServerEvent("cadToggleApi")
AddEventHandler("cadToggleApi", function()
    apiSendEnabled = not apiSendEnabled
end)

-- Toggles Postal Sender
RegisterNetEvent("getShouldSendPostal")
AddEventHandler("getShouldSendPostal", function()
    TriggerClientEvent("getShouldSendPostalResponse", source, prefixPostal)
end)

        ---------------------------------
        -- Unit Location Update
        ---------------------------------

-- Pending location updates array
LocationCache = {}

-- Main api POST function
local function SendLocations()
    local payload = json.encode({['id'] = communityID,['key'] = apiKey,['type'] = 'UNIT_LOCATION',['data'] = LocationCache})
    debugPrint(("[SonoranCAD:DEBUG] SendLocations payload: %s"):format(payload))
    PerformHttpRequest(apiURL, function(statusCode, res, headers) 
        if statusCode ~= 200 then
            print(("[SonoranCAD] API error sending locations: %s %s"):format(statusCode, res))
        end
    end, "POST", payload, {["Content-Type"]="application/json"})
end

-- Main update thread sending api location update POST requests per the postTime interval
Citizen.CreateThread(function()
    Wait(0)
    while true do
        if #LocationCache > 0 then
            -- Make API request if 1 or more updates exist
            SendLocations()
            -- Clear pending location calls
            LocationCache = {}
        end
        -- Wait the (5000ms) delay to check for pending location calls
        Citizen.Wait(postTime)
    end
end)

-- Helper function to determine index of given steamHex
local function findIndex(identifier)
    for i,loc in ipairs(LocationCache) do
        if loc.apiId == identifier then
            return i
        end
    end
end

-- Event from client when location changes occur
RegisterServerEvent('cadSendLocation')
AddEventHandler('cadSendLocation', function(currentLocation)
    -- Does this client location already exist in the pending location array?
    local identifier = GetIdentifiers(source)[primaryIdentifier]
    if serverType == "esx" then
        identifier = ("%s:%s"):format(primaryIdentifier, identifier)
    end
    local index = findIndex(identifier)
    if index then
        -- Location already in pending array -> Update
        LocationCache[index].location = currentLocation
    else
        -- Location does not exist in pending array -> Insert new location object
        table.insert(LocationCache, {['apiId'] = identifier, ['location'] = currentLocation})
    end
end)

TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
-- Helper function to get the ESX Identity object
local function getIdentity(source)
    local identifier = GetIdentifiers(source)[primaryIdentifier]
    if primaryIdentifier == "steam" then
        identifier = ("steam:%s"):format(identifier)
    end
    local result = MySQL.Sync.fetchAll("SELECT * FROM users WHERE identifier = @identifier", {['@identifier'] = identifier})
    if result[1] ~= nil then
        local identity = result[1]

        return {
            identifier = identity['identifier'],
            firstname = identity['firstname'],
            lastname = identity['lastname'],
            dateofbirth = identity['dateofbirth'],
            sex = identity['sex'],
            height = identity['height']
        }
    else
        return nil
    end
end

-- 911/311 Handler
function HandleCivilianCall(type, source, args, rawCommand)
    -- Getting the user's Steam Hexidecimal and getting their location from the table.
    local isEmergency = type == "911" and true or false
    local identifier = GetIdentifiers(source)[primaryIdentifier]
    local index = findIndex(identifier)
    if index then
        callLocation = LocationCache[index].location
    else
        callLocation = 'Unknown'
    end 
    -- Checking if there are any description arguments.
    if args[1] then
        local description = table.concat(args, " ")
        if type == "511" then
            description = "(511 CALL) "..description
        end
        local caller = nil
        -- Checking wether you have set it to standalone or esx.
        if serverType == "standalone" then
            -- Getting the Steam Name
            caller = GetPlayerName(source) 
        elseif serverType == "esx" then
            -- Getting the ESX Identity Name
            local name = getIdentity(source)
            if name ~= nil then
                caller = ("%s %s"):format(name.firstname,name.lastname)
            else
                debugPrint("[SenoranCAD] Warning: Unable to get a proper identity for the caller. Falling back to player name.")
                caller = GetPlayerName(source)
            end
        else
            print("ERROR: Improper serverType was specified in configuration. Please check it!")
            return
        end
        -- Sending the API event
        TriggerEvent('cadSendCallApi', isEmergency, caller, callLocation, description, source)
        -- Sending the user a message stating the call has been sent
        TriggerClientEvent("chat:addMessage", source, {args = {"^0^5^*[SonoranCAD]^r ", "^7Your call has been sent to dispatch. Help is on the way!"}})
    else
        -- Throwing an error message due to now call description stated
        TriggerClientEvent("chat:addMessage", source, {args = {"^0[ ^1Error ^0] ", "You need to specify a call description."}})
    end
end

        ---------------------------------
        -- Civilian 911
        ---------------------------------

RegisterCommand('911', function(source, args, rawCommand)
    HandleCivilianCall("911", source, args, rawCommand)
end, false)

        ---------------------------------
        -- Civilian 311 Command
        ---------------------------------

RegisterCommand('311', function(source, args, rawCommand)
    HandleCivilianCall("311", source, args, rawCommand)
end, false)

        ---------------------------------
        -- Civilian 511 (SADOT, optional)
        ---------------------------------

RegisterCommand('511', function(source, args, rawCommand)
    HandleCivilianCall("511", source, args, rawCommand)
end, false)

-- Client Call request
RegisterServerEvent('cadSendCallApi')
AddEventHandler('cadSendCallApi', function(emergency, caller, location, description, source)
    -- send an event to be consumed by other resources
    TriggerEvent("cadIncomingCall", emergency, caller, location, description, source)
    if apiSendEnabled then
        local payload = json.encode({['id'] = communityID, ['key'] = apiKey, ['type'] = 'CALL_911', ['data'] = {{['serverId'] = serverId, ['isEmergency'] = emergency, ['caller'] = caller, ['location'] = location, ['description'] = description}}})
        debugPrint(("[SonoranCAD:DEBUG] cadSendCallApi payload: %s"):format(payload))
        PerformHttpRequest(apiURL, function(statusCode, res, headers) 
            if statusCode ~= 200 then
                print(("[SonoranCAD] API error sending call: %s %s %s"):format(statusCode, res, headers))
            end
        end, "POST", payload, {["Content-Type"]="application/json"})
    else
        debugPrint("[SonoranCAD] API sending is disabled. Incoming call ignored.")
    end
end)

-- Utility Functions

function stringsplit(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t={} ; i=1
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        t[i] = str
        i = i + 1
    end
    return t
end

function GetIdentifiers(player)
    local ids = {}
    for _, id in ipairs(GetPlayerIdentifiers(player)) do
        local split = stringsplit(id, ":")
        ids[split[1]] = split[2]
    end
    return ids
end