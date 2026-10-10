dofile(ROOT .. "/tests/harness.lua")

local H = 216

test("a death creates a corpse record and tags the character", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ x = 12.5, y = 34.5 })
    p:kill(game)
    local rec = onlyRecord()
    eq(rec.name, "Bob Smith", "name")
    eq(rec.owner, "bob", "owner")
    eq(rec.x, 12.5, "x")
    eq(rec.state, FYDS.STATE_CORPSE, "state")
    eq(p.modData[FYDS.TAG], rec.id, "tag on character")
end)

test("the corpse made by the game carries the tag", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p:die() -- PlayerOnGroundState
    eq(p.corpse.modData[FYDS.TAG], onlyRecord().id, "tag on corpse")
end)

test("animals and zombies do not create records", function()
    local game = setupGame()
    loadServer(game)
    local animal = newPlayer({ animal = true })
    animal:kill(game)
    fire("OnCharacterDeath", newZombie(nil, 1, 1))
    eq(count(records()), 0, "records")
end)

test("a repeated death event does not create a second record", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    fire("OnCharacterDeath", p)
    eq(count(records()), 1, "records")
end)

test("normal death: no forced corpse when the game makes one", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    tickFor(game, 1500)
    p:die()
    tickFor(game, 30000)
    eq(p.dieCalls, 1, "die calls")
end)

test("god mode during the death animation: god mode turned off, corpse forced", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p.godMod = true -- switched on a moment too late
    p:update()      -- heals the dying body back to "alive"
    eq(p:isDead(), false, "healed")
    tickFor(game, 100, 100, { p })
    eq(p.godMod, false, "god mode off")
    eq(p:isDead(), true, "dead again")
    tickFor(game, 2500, 100, { p })
    truthy(p.corpse, "corpse created")
    eq(p.corpse.modData[FYDS.TAG], onlyRecord().id, "corpse tagged")
    eq(p.dieCalls, 1, "die calls")
end)

test("stuck death (never reaches the ground state): corpse forced after 15s", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    tickFor(game, 14000)
    eq(p.corpse, nil, "not yet")
    tickFor(game, 1500)
    truthy(p.corpse, "corpse created")
end)

test("paused time does not count toward the stuck timeout", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    game.paused = true
    tickFor(game, 60000, 500)
    eq(p.corpse, nil, "no corpse while paused")
    game.paused = false
    tickFor(game, 15500)
    truthy(p.corpse, "corpse after unpausing")
end)

test("AlwaysLeaveBody off: nothing is forced", function()
    local game = setupGame()
    SandboxVars.PZFindYourDeadSelf.AlwaysLeaveBody = false
    loadServer(game)
    local p = newPlayer()
    p:kill(game)
    p.godMod = true
    p:update()
    tickFor(game, 30000, 500, { p })
    eq(p.corpse, nil, "no corpse")
    eq(p.godMod, true, "god mode untouched")
end)

test("reanimation: found within the scan interval, countdown cleared, follows the zombie", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local rec = onlyRecord()
    truthy(rec.willReanimate, "willReanimate")
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    eq(rec.state, FYDS.STATE_ZOMBIE, "state")
    eq(rec.corpseSince, nil, "countdown cleared")
    z.x, z.y = 50.5, 60.5
    tickFor(game, 1100)
    eq(rec.x, 50.5, "x follows")
    eq(rec.y, 60.5, "y follows")
    eq(FYDS.getLiveZombie(rec.id), z, "live zombie for the map")
end)

test("small zombie movement is not stored", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true, x = 10, y = 10 })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.x = 10.2
    tickFor(game, 1100)
    eq(onlyRecord().x, 10, "x unchanged")
end)

test("unloaded zombie keeps its last known position and is found again later", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.x, z.y = 70, 80
    tickFor(game, 1100)
    z.inWorld = false
    removeFromList(game, z)
    z.x, z.y = 999, 999 -- position no longer valid once unloaded
    tickFor(game, 7000)
    local rec = onlyRecord()
    eq(rec.state, FYDS.STATE_ZOMBIE, "still a zombie")
    eq(rec.x, 70, "last known x")
    eq(FYDS.getLiveZombie(rec.id), nil, "not live")
    -- Back in a loaded area.
    z.inWorld, z.x, z.y = true, 75, 85
    game.zombieList[#game.zombieList + 1] = z
    tickFor(game, 6000)
    eq(rec.x, 75, "found again")
end)

test("zombie killed: static corpse with a fresh full countdown, then removed", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    game.now = 400
    z.x, z.y = 33, 44
    z.dead = true
    fire("OnZombieDead", z)
    local rec = onlyRecord()
    eq(rec.state, FYDS.STATE_CORPSE, "state")
    eq(rec.corpseSince, 400, "fresh countdown")
    eq(rec.x, 33, "where it fell")
    game.now = 400 + H - 1
    tickFor(game, 11000)
    eq(count(records()), 1, "still there just before")
    game.now = 400 + H
    tickFor(game, 11000)
    eq(count(records()), 0, "removed")
end)

test("zombie death noticed even without OnZombieDead", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local z = reanimate(game, p.corpse)
    tickFor(game, 6000)
    z.dead = true
    tickFor(game, 1100)
    eq(onlyRecord().state, FYDS.STATE_CORPSE, "state")
end)

test("other zombies are ignored", function()
    local game = setupGame()
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    game.zombieList[1] = newZombie(nil, 1, 1)             -- ordinary zombie
    game.zombieList[2] = newZombie({ [FYDS.TAG] = "99" }, 2, 2) -- unknown id
    local ordinary = newZombie(nil, 3, 3)
    ordinary.reanimatedPlayer = false
    game.zombieList[3] = ordinary
    fire("OnZombieDead", ordinary)
    tickFor(game, 6000)
    eq(onlyRecord().state, FYDS.STATE_CORPSE, "unchanged")
end)

test("player corpse is kept forever by default, removed when the server option is on", function()
    local game = setupGame()
    loadServer(game)
    newPlayer():kill(game)
    game.now = game.now + 100000
    tickFor(game, 11000)
    eq(count(records()), 1, "kept")
    game.serverOptions.RemovePlayerCorpsesOnCorpseRemoval = true
    tickFor(game, 11000)
    eq(count(records()), 0, "removed")
end)

test("records survive a reload, and tracking resumes", function()
    local store = {}
    local game = setupGame({ store = store })
    loadServer(game)
    local p = newPlayer({ infected = true })
    p:kill(game)
    p:die()
    local corpse = p.corpse
    -- Save, quit, load.
    game = setupGame({ store = store })
    loadServer(game)
    eq(count(records()), 1, "record kept")
    reanimate(game, corpse)
    tickFor(game, 6000)
    eq(onlyRecord().state, FYDS.STATE_ZOMBIE, "tracked after reload")
    local p2 = newPlayer({ username = "bob", forename = "Second" })
    p2:kill(game)
    eq(count(records()), 2, "ids do not collide")
end)

test("singleplayer sends nothing over the network", function()
    local game = setupGame()
    loadServer(game)
    newPlayer():kill(game)
    tickFor(game, 31000)
    eq(#game.sent, 0, "sent")
end)

test("MP client does not run the record keeper", function()
    local game = setupGame({ client = true })
    dofile(MOD .. "shared/FindYourDeadSelf/FYDS_Core.lua")
    dofile(MOD .. "server/FindYourDeadSelf/FYDS_Server.lua")
    eq(FYDS.getAuthorityRecords, nil, "no authority on client")
end)

local function lastSentTo(game, player)
    local last
    for i = 1, #game.sent do
        if game.sent[i].player == player then last = game.sent[i] end
    end
    return last
end

local function sentNames(msg)
    local names = {}
    for _, r in pairs(msg.args.records) do names[#names + 1] = r.name end
    table.sort(names)
    return table.concat(names, ",")
end

local function mpGame(visibility)
    local game = setupGame({ server = true })
    SandboxVars.PZFindYourDeadSelf.Visibility = visibility
    loadServer(game)
    local alice = newPlayer({ username = "alice", forename = "Alice", surname = "" })
    local carol = newPlayer({ username = "carol", forename = "Carol", surname = "" })
    local dave = newPlayer({ username = "dave", forename = "Dave", surname = "" })
    game.online = { alice, carol, dave }
    game.factions = { alice = "Red", carol = "Red", dave = "Blue" }
    local aliceOld = newPlayer({ username = "alice", forename = "OldAlice", surname = "" })
    local daveOld = newPlayer({ username = "dave", forename = "OldDave", surname = "" })
    aliceOld:kill(game)
    daveOld:kill(game)
    tickFor(game, 200)
    return game, alice, carol, dave
end

test("MP visibility: only me", function()
    local game, alice, carol, dave = mpGame(FYDS.VISIBILITY_ONLY_ME)
    eq(sentNames(lastSentTo(game, alice)), "OldAlice", "alice")
    eq(sentNames(lastSentTo(game, carol)), "", "carol")
    eq(sentNames(lastSentTo(game, dave)), "OldDave", "dave")
end)

test("MP visibility: me + faction", function()
    local game, alice, carol, dave = mpGame(FYDS.VISIBILITY_FACTION)
    eq(sentNames(lastSentTo(game, alice)), "OldAlice", "alice")
    eq(sentNames(lastSentTo(game, carol)), "OldAlice", "carol sees faction mate")
    eq(sentNames(lastSentTo(game, dave)), "OldDave", "dave")
end)

test("MP visibility: everyone", function()
    local game, alice, carol, dave = mpGame(FYDS.VISIBILITY_EVERYONE)
    eq(sentNames(lastSentTo(game, carol)), "OldAlice,OldDave", "carol")
end)

test("MP: a joining player's request is answered", function()
    local game, alice = mpGame(FYDS.VISIBILITY_ONLY_ME)
    game.sent = {}
    fire("OnClientCommand", FYDS.MOD_ID, "request", alice, {})
    eq(#game.sent, 1, "one reply")
    eq(sentNames(game.sent[1]), "OldAlice", "content")
    fire("OnClientCommand", "SomeOtherMod", "request", alice, {})
    eq(#game.sent, 1, "other modules ignored")
end)

test("MP: zombie movement is sent, an idle server is quiet until the resync", function()
    local game = setupGame({ server = true })
    loadServer(game)
    local alice = newPlayer({ username = "alice" })
    game.online = { alice }
    local old = newPlayer({ username = "alice", infected = true })
    old:kill(game)
    old:die()
    local z = reanimate(game, old.corpse)
    tickFor(game, 6000)
    game.sent = {}
    tickFor(game, 5000)
    eq(#game.sent, 0, "nothing while nothing changes")
    z.x = z.x + 5
    tickFor(game, 1100)
    eq(#game.sent, 1, "movement sent")
    eq(lastSentTo(game, alice).args.records[1].x, z.x, "new position")
end)

finish("server")
