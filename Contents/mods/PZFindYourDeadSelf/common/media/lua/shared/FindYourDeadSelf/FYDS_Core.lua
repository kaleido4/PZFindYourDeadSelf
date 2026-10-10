--[[
    Find Your Dead Self - shared core.

    Pure logic for death records: no game objects are touched here, so this file
    can be unit-tested outside the game (see tests/).

    A death record follows one body through its whole life:

        player dies        -> "corpse"   countdown starts
        corpse reanimates  -> "zombie"   countdown cleared, marker follows the zombie
        zombie is killed   -> "corpse"   a fresh full countdown starts
        countdown ends     -> record removed, skull disappears

    The countdown mirrors the game's own corpse removal (IsoDeadBody.updateBodies):
      * HoursForCorpseRemoval <= 0 means corpses are never removed;
      * a player's own corpse is only removed when the server option
        RemovePlayerCorpsesOnCorpseRemoval is on (off by default, also in SP);
      * the corpse of a killed zombie is removed once it has been dead for
        HoursForCorpseRemoval hours.
    With the sandbox option "Your Corpse Never Rots" the record keeper keeps our
    corpses fresh, so the game never removes them and the countdown never ends.
--]]

FYDS = FYDS or {}

FYDS.MOD_ID = "PZFindYourDeadSelf"
FYDS.DATA_KEY = "FindYourDeadSelf"
-- Key we put in the dying character's mod data. The game copies a character's
-- mod data onto its corpse, and a corpse's mod data onto the zombie it
-- reanimates into, so this tag follows the body through every stage.
FYDS.TAG = "FYDS_DeathId"

FYDS.STATE_CORPSE = "corpse"
FYDS.STATE_ZOMBIE = "zombie"

FYDS.VISIBILITY_ONLY_ME = 1
FYDS.VISIBILITY_FACTION = 2
FYDS.VISIBILITY_EVERYONE = 3

-- Kahlua's next() is unreliable, so emptiness is checked with pairs().
function FYDS.isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

function FYDS.newRecord(id, owner, name, x, y, z, nowHours, willReanimate)
    return {
        id = id,
        owner = owner,
        name = name,
        x = x, y = y, z = z,
        state = FYDS.STATE_CORPSE,
        corpseSince = nowHours,
        wasZombie = false,
        willReanimate = willReanimate and true or false,
    }
end

function FYDS.setPosition(rec, x, y, z)
    rec.x, rec.y, rec.z = x, y, z
end

-- Our corpse got up as a zombie: the countdown is cleared completely.
function FYDS.markReanimated(rec, x, y, z)
    rec.state = FYDS.STATE_ZOMBIE
    rec.corpseSince = nil
    rec.willReanimate = false
    FYDS.setPosition(rec, x, y, z)
end

-- Our zombie was killed: it is a fresh corpse with a fresh full countdown.
function FYDS.markKilled(rec, x, y, z, nowHours)
    rec.state = FYDS.STATE_CORPSE
    rec.corpseSince = nowHours
    rec.wasZombie = true
    rec.willReanimate = false
    FYDS.setPosition(rec, x, y, z)
end

-- True while we have to look for this record's zombie in the loaded world.
function FYDS.needsTracking(rec)
    return rec.state == FYDS.STATE_ZOMBIE or (rec.state == FYDS.STATE_CORPSE and rec.willReanimate)
end

function FYDS.isExpired(rec, nowHours, hoursForRemoval, removePlayerCorpses, keepCorpses)
    if rec.state ~= FYDS.STATE_CORPSE or not rec.corpseSince or keepCorpses then return false end
    if not hoursForRemoval or hoursForRemoval <= 0 then return false end
    if not rec.wasZombie and not removePlayerCorpses then return false end
    return nowHours - rec.corpseSince >= hoursForRemoval
end

-- Erasing a skull (map Remove tool, needs an eraser) only hides it for the
-- player who erased it; the record, its countdown and the corpse are untouched.
-- Who erased it is keyed by username in multiplayer. In singleplayer every
-- character is the same person, so one fixed key is used.
function FYDS.viewerKey(player)
    if isClient() or isServer() then return player:getUsername() end
    return "sp"
end

function FYDS.isErasedFor(rec, key)
    return rec.erasedBy ~= nil and rec.erasedBy[key] == true
end

function FYDS.markErased(rec, key)
    rec.erasedBy = rec.erasedBy or {}
    rec.erasedBy[key] = true
end

-- sameFaction(ownerName, viewerName) is passed in so this stays testable.
function FYDS.canSee(rec, viewerName, visibility, sameFaction)
    if visibility == FYDS.VISIBILITY_EVERYONE then return true end
    if rec.owner == viewerName then return true end
    if visibility == FYDS.VISIBILITY_FACTION and sameFaction then
        return sameFaction(rec.owner, viewerName) and true or false
    end
    return false
end
