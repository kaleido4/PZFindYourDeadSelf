--[[
    Find Your Dead Self - world map skulls.

    Draws a red skull and the character's name on the world map for every death
    record this player may see. Nothing runs unless the world map is open.

    Singleplayer: records are read straight from the record keeper
    (FYDS_Server.lua), which runs in the same Lua state, and a zombie that is in
    a loaded area is drawn at its live position.
    Multiplayer: the server sends the visible records (see FYDS_Server.lua);
    we ask for them once when the game starts.
--]]

if isServer() then return end

require "FindYourDeadSelf/FYDS_Core"
require "ISUI/Maps/ISWorldMap"

local SKULL_TEXTURE = "media/ui/LootableMaps/map_skull.png" -- vanilla map symbol
local RED, GREEN, BLUE = 0.85, 0.08, 0.08
local MIN_ICON_SIZE, MAX_ICON_SIZE = 18, 28
local MIN_ZOOM, MAX_ZOOM = 12, 18 -- icon grows between these map zoom levels

local receivedRecords = {} -- multiplayer only
local skullTexture

local function getRecords()
    if FYDS.getAuthorityRecords then
        return FYDS.getAuthorityRecords()
    end
    return receivedRecords
end

local function iconSize(map)
    local t = (map.mapAPI:getZoomF() - MIN_ZOOM) / (MAX_ZOOM - MIN_ZOOM)
    t = math.min(math.max(t, 0), 1)
    return MIN_ICON_SIZE + (MAX_ICON_SIZE - MIN_ICON_SIZE) * t
end

local function renderSkulls(map)
    local records = getRecords()
    if not records or FYDS.isEmpty(records) then return end
    skullTexture = skullTexture or getTexture(SKULL_TEXTURE)
    if not skullTexture then return end

    local api = map.mapAPI
    local size = iconSize(map)
    local half = size / 2
    local font = UIFont.Small
    local fontHeight = getTextManager():getFontHeight(font)

    for _, rec in pairs(records) do
        local x, y = rec.x, rec.y
        local zombie = FYDS.getLiveZombie and FYDS.getLiveZombie(rec.id)
        if zombie then
            x, y = zombie:getX(), zombie:getY()
        end
        local sx = api:worldToUIX(x, y)
        local sy = api:worldToUIY(x, y)
        if sx > -size and sy > -size and sx < map.width + size and sy < map.height + size then
            map:drawTextureScaledAspect(skullTexture, sx - half, sy - half, size, size, 1, RED, GREEN, BLUE)
            if rec.name then
                map:drawText(rec.name, sx + half + 2, sy - fontHeight / 2, RED, GREEN, BLUE, 1, font)
            end
        end
    end
end

local originalPrerender = ISWorldMap.prerender
function ISWorldMap:prerender()
    originalPrerender(self)
    renderSkulls(self)
end

local function onServerCommand(module, command, args)
    if module ~= FYDS.MOD_ID then return end
    if command == "records" then
        receivedRecords = args.records or {}
    end
end

local function onGameStart()
    if isClient() then
        sendClientCommand(FYDS.MOD_ID, "request", {})
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnGameStart.Add(onGameStart)
