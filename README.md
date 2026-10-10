# Find Your Dead Self

Project Zomboid (Build 42) mod that shows where you died on the world map, so you can find your body with your next character.

- A red skull with the character's name marks the spot.
- If the body reanimates, the skull follows the zombie while it is in a loaded area, and keeps its last known position while it is not.
- When the zombie is killed, the skull stays where it fell.
- The skull disappears when the game would remove the corpse. This follows the game's own rules: `HoursForCorpseRemoval` (<= 0 means never), and player corpses only when the server option `RemovePlayerCorpsesOnCorpseRemoval` is on.
- Every death leaves a corpse, even when god mode is turned on while already dying.

## Sandbox options

| Option | Values | Default |
|---|---|---|
| Death Marker Visibility | Only me / Me + faction / Everyone (MP only) | Only me |
| Always Leave a Body | on / off | on |

## Layout

```
Contents/mods/PZFindYourDeadSelf/
  42/mod.info
  common/media/
    sandbox-options.txt
    lua/shared/FindYourDeadSelf/FYDS_Core.lua     pure record logic (unit-tested)
    lua/server/FindYourDeadSelf/FYDS_Server.lua   record keeper: SP and MP server
    lua/client/FindYourDeadSelf/FYDS_Client.lua   world map skulls
    lua/shared/Translate/EN/Sandbox.json
tests/                                            Kahlua test runner and tests
```

## How it works

The game copies a character's mod data onto its corpse, and a corpse's mod data onto the zombie it reanimates into. When a player dies we create a record in global mod data and put its id in the character's mod data, so the corpse and the zombie both carry it. Reanimated player zombies are found by that tag among the loaded zombies and followed while loaded.

Why corpses go missing with god mode: when health reaches 0 the game shows the death screen and deletes the character (`IsoPlayer.OnDeath`), but the corpse is only created later by `PlayerOnGroundState`, which calls `die()` only while `isDead()` is still true. `isDead()` just reads the current health, so god mode switched on during the death animation heals the body and the corpse is never made. The record keeper watches each death until its corpse exists: if the body gets healed it turns god mode off and zeroes the health again, and if the corpse still does not appear it calls `die()` itself.

## Tests

The tests run the mod's Lua in Kahlua, the Lua VM from the game's own `projectzomboid.jar`, against mocks of the game API.

```bash
JAVAC="/c/Program Files/Java/jdk-21.0.11/bin/javac" bash tests/run_tests.sh
```

Needs a JDK 17+ `javac` (only to compile the small runner) and the game installed; set `PZ_DIR` if it is not in `D:/Games/Steam/steamapps/common/ProjectZomboid`.
