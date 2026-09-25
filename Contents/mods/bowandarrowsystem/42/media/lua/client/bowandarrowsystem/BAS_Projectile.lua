-- Bow and Arrow System: parabolic arrow projectiles (MSE-style).
-- At shot time the arrow is SIMULATED here in Lua (gravity integration, two
-- substeps a frame) and DRAWN by a custom Java entity, BowArrow3D -- an
-- IsoMovingObject with its own SpriteModel, which is the only way to make an
-- arrow point along its own flight direction. The ground, a wall or a fence
-- stops it; it then KEEPS that body and its impact pose (a Minecraft
-- "inGround" arrow), and the inventory item is handed over on approach.
-- If the Java bridge is missing the mod degrades to a plain world item
-- (WorldStaticModel = BAS_Arrow, drawn by IsoWorldInventoryObject) -- visible,
-- just not rotatable. See the dictionary entries BAS12-BAS14.
-- A zombie hit deals the real damage (the vanilla straight-line damage is
-- zeroed on the bow items) and records the arrow for recovery from the corpse.

BAS_Projectile = {}
BAS_Projectile.active = {}

-- Arrows that have STOPPED but are still alive as 3D bodies -- the MC
-- "inGround" idea. Nothing re-poses them after they stop, so each one keeps
-- the yaw/pitch it had at the moment of impact: an arrow lands head-down at
-- the angle it was falling, which reads as STUCK IN the ground instead of
-- lying flat like a dropped sprite. The inventory item waits in p.item and is
-- handed over when the player walks close enough (updateLanded).
BAS_Projectile.landed = {}

-- How close the player has to get, in tiles, to pull a stuck arrow out.
BAS_Projectile.PICKUP_RANGE = 1.6

-- How many world-space samples of an arrow's flight are kept for the trail
-- renderer. One sample per integration substep (2 per frame), so 40 is about
-- 20 frames of tail -- roughly 7 tiles at the current speeds.
BAS_Projectile.TRAIL_MAX = 40

-- ===========================================================================
-- AIM MODEL -- Wurst7 / vanilla Minecraft, 2026-09-19 (2nd revision).
--
-- Reference the user asked for: Wurst7's Trajectories hack
-- (net/wurstclient/hacks/TrajectoriesHack.java). Its physics, verbatim:
--     throwPower = 3.0 * f          f = the bow's draw power,
--                                   f = (t^2 + 2t)/3 for t = ticks/20
--     gravity    = 0.05 blocks/tick^2
--     drag       = 0.999 per 0.1 tick  (0.99 per tick)
--     direction  = THE PLAYER'S LOOK VECTOR (yaw/pitch), and the predicted path
--                  is stepped until it hits a block or an entity
--   ...i.e. in Minecraft the arrow FOLLOWS WHERE YOU POINT, and the draw only
--   decides how far it can reach. A bow that is not drawn fully falls short of
--   the target you are pointing at -- it does not "aim somewhere else".
--
-- How that maps onto this mod (PZ has a cursor, not a look pitch):
--   ANGLE  : solved so the arc lands on the ground point under the CURSOR --
--            the PZ equivalent of "follows where you point". This is the
--            dictionary BAS10 rule and it is BACK after one revision without it
--            (that revision made the cursor pick only the direction, which
--            produced exactly the complaint it deserved: "the parabola is
--            always at max range, I want it to go from near to far").
--   SPEED  : v = stats.speed * f, straight from Wurst's throwPower = 3f -- the
--            scale is LINEAR in the draw, with NO floor (the old
--            CHARGE_SPEED_MIN = 0.45 floor is gone), so the reach falls off as
--            f^2 and a half draw genuinely cannot reach far.
--   REACH  : the cursor is clamped to what this draw can physically reach, so a
--            weak draw visibly lands SHORT of the crosshair instead of failing
--            the solve. Preview and shot share this code, so what you see is
--            what you get.
--
-- Unit mapping used for the speeds/gravity below: 1 Minecraft tick = 3 PZ frames
-- (20 vs 60 per second), so per-frame values are the per-tick values divided by
-- 3 (velocity) and by 9 (acceleration):
--     v_full = 3.0 blocks/tick = 1.0 tile/frame
--     gravity = 0.05 / 9       = 0.005556 tile/frame^2
-- NOT ported: Wurst's air drag (0.99/tick). With drag the landing distance no
-- longer has a closed-form solution, so the pitch would have to be solved
-- numerically every frame -- the preview runs each frame, and the mod's whole
-- discipline is "the arc you see is the arc that flies". Drag over a 26-tile
-- flight costs about 9% of the speed, i.e. the arrow would land visibly short of
-- the crosshair for no gameplay gain. Left out deliberately.
--
-- Unified range rule -- the single source of truth for every distance limit.
--   dimension : HORIZONTAL (x/y) straight-line distance, in tiles. Height
--               difference is NOT part of it; aiming up or down a hill does
--               not change how far 26 tiles is.
--   origin    : the PLAYER's position. Not the muzzle (0.5 tiles ahead), not
--               the arc's first point.
--   ceiling   : RANGE_MAX = 26, HARD. Nothing ever travels farther from the
--               player than this, whatever the angle, the height or the draw.
--   floor     : RANGE_MIN = 2, so a shot always leaves the bow.
-- Everything that needs a limit reads these constants -- the preview arc, the
-- real arrow, the red ground ring -- so all of them move together.
BAS_Projectile.RANGE_MIN = 2
BAS_Projectile.RANGE_MAX = 26

-- Launch geometry. The arrow leaves 0.5 tiles ahead of the player and
-- LAUNCH_HEIGHT up; both are shared with BAS_Client's preview so the shown arc
-- and the real one start from the same point.
BAS_Projectile.LAUNCH_AHEAD = 0.5
BAS_Projectile.LAUNCH_HEIGHT = 0.45

-- Charge scaling (the charge system itself lives in BAS_Client).
-- SPEED is linear in the draw and has no floor, matching Wurst's throwPower =
-- 3f exactly: reach ~ v^2, so a half draw reaches about a quarter as far as a
-- full one and a tap shot barely leaves the bow. The bow's `speed` in the table
-- below is therefore the FULL-DRAW speed in tiles per frame.
-- DAMAGE keeps its own floor (0.5x): a weak arrow that does land should still
-- hurt, and PZ has no MC-style armour to soak it.
BAS_Projectile.CHARGE_SPEED_MIN = 0.0    -- no floor: the draw IS the speed
BAS_Projectile.CHARGE_DMG_MIN = 0.5      -- damage multiplier at charge 0


-- DAMAGE CALIBRATION. Reference: a zombie has 1.8-2.1 health (IsoZombie.java:379)
-- and this is read as "100 health", so the numbers below are percentages of a
-- zombie.
--
-- Ceiling set by the user 2026-09-25 (refined twice; the last word is
-- max damage 25-40 at full draw): a FULL draw must land between 0.25 and 0.40 -- 25 to 40
-- damage -- and NOTHING may exceed 0.40. The charge multiplier is still
-- 0.5x .. 2.0x, so dmgMin/dmgMax are the charge-0 numbers and a full draw
-- doubles them:
--     tap shot (charge 0)          x0.50 -> 0.06-0.10   ->  10-16 arrows
--     half draw                    x1.25 -> 0.16-0.25   ->   4-7 arrows
--     FULL draw                    x2.00 -> 0.25-0.40   ->   3-4 arrows
-- A crit no longer multiplies the damage at all -- see hitZombie. critMult 2.0
-- used to push a full draw to 0.50-0.80, straight over the ceiling; what a crit
-- still buys is the guaranteed knockdown/flinch.
-- To make snap shots hurt more, raise CHARGE_DMG_MIN (the 0.5 floor): the
-- ceiling stays put and only the bottom of the curve moves.
--
-- speed = FULL-DRAW launch speed in tiles per frame (Wurst's throwPower = 3
-- blocks/tick = 1.0 tile/frame at 1 tick = 3 frames). The mod ships exactly ONE
-- bow now (BAS.BAS_Bow, the former hunting bow) and it sits at the Minecraft
-- value; the old crude bow entry is gone with the item.
-- gravity = Minecraft's 0.05 blocks/tick^2 / 9 = 0.005556 tiles/frame^2.
BAS_Projectile.stats = {
	["BAS.BAS_Bow"] = { speed = 1.0, gravity = 0.005556, dmgMin = 0.125, dmgMax = 0.20, spread = 0.02 },
}

-- Chance (%) that a FULL draw crits. 0 = never, 100 = every full draw one-shots
-- (the old behaviour). Only a full draw can roll it at all -- see hitZombie.
BAS_Projectile.CRIT_CHANCE = 25

-- The range of a projectile fired from height h at angle `a` with speed v, on
-- flat ground (the landing plane is one launch height below the muzzle):
--     R = (v*cos a / g) * (v*sin a + sqrt(v^2*sin^2 a + 2*g*h))
-- Exact for constant gravity, which is what the integration below uses.
-- Used to compute the PHYSICAL REACH of a shot (its value at the optimal angle,
-- 45 degrees on flat ground), which is what clamps an out-of-reach cursor.
BAS_Projectile.rangeAtAngle = function(v, g, a, h)
	local sa, ca = math.sin(a), math.cos(a)
	return (v * ca / g) * (v * sa + math.sqrt(v * v * sa * sa + 2 * g * h))
end


-- Half-tile obstacles (fences, low walls) are "hoppable" in PZ: the player can
-- climb them and -- crucially -- vanilla bullets ignore them completely, which
-- is exactly why an arrow used to slip straight through a fence and hit the
-- zombie standing behind it. An arrow is a physical object, so it clears the
-- obstacle only when its arc is ABOVE the top edge; a flat shot is stopped.
--   * Height is the ONLY thing that decides a fence -- see hasFenceBetween().
--   * The fence test must run BEFORE the wall test in both BAS_Projectile.step
--     and BAS_Client.traceTrajectory, because isBlockedTo() reports a map fence
--     as a full wall and would otherwise stop the arrow at any altitude.
-- Raise/lower this to match whatever the fence visuals look like.
BAS_Projectile.FENCE_HEIGHT = 0.5

-- Zombie hit volume. HIT_RADIUS is the horizontal radius around the zombie's
-- centre; the z band is measured from the ZOMBIE'S OWN z (its feet), so it works
-- on stairs, porches and rooftops too.
--
-- HIT_Z_HIGH = 1.3 comes from the character's real size: a character sprite is
-- 128 px tall while one z-level is 96 px (IsoUtils.YToScreen: 96 * tileScale per
-- z), i.e. a character is about 1.33 z-levels tall -- so 1.3 reaches the head.
-- (With the previous 1.2 a head shot could not register at all.)
BAS_Projectile.HIT_RADIUS = 0.3
BAS_Projectile.HIT_Z_LOW = -0.2
BAS_Projectile.HIT_Z_HIGH = 1.3

-- TEMP DIAG (turn off once the "arrow clearly flew over its head but it still
-- died" question is settled): one console line per zombie hit, reporting the
-- arrow's height, the zombie's height, the difference, the horizontal distance,
-- how far the arrow had flown, and the two LEVELS. If `arrowLev` and `zedLev`
-- differ the hit was found by the second (level-below) lookup -- see
-- step()'s comment on why that lookup exists.
BAS_Projectile.HIT_DIAG = false

-- TEMP DIAG (2026-09-25): one line per LODGED arrow, "lodged=<slot> took=<bool>
-- model=<name>". It answers the two questions that decide whether a stuck arrow
-- can be SEEN at all:
--   took  -- did the engine really take the item? getAttachedItem reads the slot
--            back and compares it with our own instance. false/nil = the attach
--            silently did nothing (and the arrow fell to the ground instead).
--   model -- what the renderer will ask the item for (getStaticModel). nil =
--            the item has no model, so it could never be drawn.
-- Set it to false once "the arrow sticks in the zombie" is confirmed.
BAS_Projectile.LODGE_DIAG = true

-- Bridge to the Java 3D flight body (BowArrow3D). Resolved once and cached.
-- The jar only exposes BowAPI.BowArrow3D when ZombieBuddy managed to load it;
-- if it is missing the mod must still work, so every call site checks first
-- and falls back to the plain world-item path (visible, just not rotating).
BAS_Projectile.arrow3d = function()
	if BAS_Projectile._a3 == nil then
		local t = nil
		if type(BowAPI) == "table" and type(BowAPI.BowArrow3D) == "table"
			and type(BowAPI.BowArrow3D.spawn) == "function" then
			t = BowAPI.BowArrow3D
		end
		BAS_Projectile._a3 = t or false
	end
	if BAS_Projectile._a3 == false then
		return nil
	end
	return BAS_Projectile._a3
end

-- Drop the 3D flight body. Called the moment the arrow stops or hits, because
-- from then on the real world item represents it (and two arrows on screen at
-- once would be one too many).
-- Can the Java side actually RESOLVE the model script? If not, a 3D body would
-- render nothing at all (IsoObject.renderModel() returning false is silent --
-- the object falls back to its carrier sprite), so in that case we must use the
-- plain world item instead: visible, just not rotatable. Checked once.
BAS_Projectile.modelOk = function(a3)
	if BAS_Projectile._modelOk == nil then
		local ok = true
		if type(a3.probe) == "function" then
			local s = tostring(a3.probe())
			ok = string.find(s, "FOUND", 1, true) ~= nil
			BAS_Projectile._modelOkReport = s
		end
		BAS_Projectile._modelOk = ok
	end
	return BAS_Projectile._modelOk
end

BAS_Projectile.dropBody = function(p)
	if p.body and p.body > 0 then
		local a3 = BAS_Projectile.arrow3d()
		if a3 then
			a3.destroy(p.body)
		end
		p.body = nil
	end
end

-- Is there a hoppable obstacle (fence / low wall) between these two squares?
--
-- Uses getHoppableTo(), which inspects the OBJECT's sprite flags and resolves a
-- diagonal step through the two in-between squares. The previous test,
-- isHoppableTo(), read the SQUARE's tile flags instead, so it failed in two
-- opposite ways: it returned FALSE for every player-built fence (an
-- IsoThumpable object, no tile flag) -- the arrow flew straight through it --
-- and it returned FALSE for every diagonal crossing, while isBlockedTo()
-- happily reported those same map fences as full walls, which stopped the
-- arrow no matter how high it was flying. Fences must be decided by HEIGHT
-- alone, never by the wall test.
BAS_Projectile.hasFenceBetween = function(prevSq, currSq)
	if not prevSq or not currSq or prevSq == currSq then
		return false
	end
	local found = false
	local ok = pcall(function()
		found = prevSq:getHoppableTo(currSq) ~= nil
	end)
	if not ok then
		-- fallback: square-level test (misses diagonals and built fences)
		found = prevSq:isHoppableTo(currSq)
	end
	return found
end

-- Where exactly did the arrow cross out of `prevSq`? Bisects the substep until
-- the last position still inside prevSq is found (8 steps -> under 0.002 tiles
-- of slack), so an arrow that hits a wall or a fence comes to rest ON the
-- obstacle instead of freezing at its previous substep position.
--
-- Used by BOTH sides on purpose: BAS_Projectile.step (the real arrow) and
-- BAS_Client.traceTrajectory (the preview). The ground and range branches have
-- always interpolated; the wall and fence branches never did (dictionary BAS11
-- left that as a known leftover), so before this the arrow visibly stopped
-- short of whatever it had just hit -- and the preview, which stops one substep
-- early too, would have disagreed with the shot the moment only one of them
-- learned to interpolate.
BAS_Projectile.clampToBoundary = function(x0, y0, z0, nx, ny, nz, prevSq)
	local cell = getCell()
	local lo, hi = 0, 1
	for i = 1, 8 do
		local mid = (lo + hi) / 2
		local sq = cell:getGridSquare(x0 + (nx - x0) * mid, y0 + (ny - y0) * mid, z0 + (nz - z0) * mid)
		if sq == prevSq then
			lo = mid
		else
			hi = mid
		end
	end
	return x0 + (nx - x0) * lo, y0 + (ny - y0) * lo, z0 + (nz - z0) * lo
end

-- Is there a zombie inside the hit volume (HIT_RADIUS around nx/ny, HIT_Z_* above
-- its own feet) in this square? Returns the zombie or nil.
-- Shared by step() (the real arrow) and BAS_Client.traceTrajectory (the preview)
-- so the two can never disagree about what will be hit.
BAS_Projectile.zombieInSquare = function(sq, nx, ny, nz)
	if not sq then
		return nil
	end
	local moving = sq:getMovingObjects()
	if not moving then
		return nil
	end
	for ii = 0, moving:size() - 1 do
		local obj = moving:get(ii)
		if obj and obj:isZombie() then
			local zx, zy = obj:getX(), obj:getY()
			local zd = nz - obj:getZ()
			if math.sqrt((zx - nx) * (zx - nx) + (zy - ny) * (zy - ny)) < BAS_Projectile.HIT_RADIUS
				and zd >= BAS_Projectile.HIT_Z_LOW
				and zd <= BAS_Projectile.HIT_Z_HIGH then
				return obj
			end
		end
	end
	return nil
end

-- Find a zombie the arrow can hit at (nx, ny, nz): the square at the ARROW'S OWN
-- level first, then the level below.
--
-- The second lookup is NOT optional. getGridSquare(x, y, nz) resolves to
-- PZMath.fastfloor(nz), and IsoCell.getGridSquare(int,int,int) is a plain level
-- lookup that never falls back to a lower level (IsoCell.java:2800-2818). A
-- character is ~1.33 z-levels tall, so an arrow at z = 1.2 is physically inside
-- a zombie whose feet are at z = 0 -- but the square it was asking about was
-- LEVEL 1, which holds no ground zombies at all. Effect before this: the whole
-- z band was a lie above z = 1.0 (the level lookup silently exempted those
-- arrows) and an arrow lobbed down onto a zombie from above could never hit it.
-- With both levels checked, the band is the ONLY gate: over the head (zd > 1.3)
-- is a guaranteed miss at any altitude.
BAS_Projectile.zombieAt = function(cell, nx, ny, nz)
	local hit = BAS_Projectile.zombieInSquare(cell:getGridSquare(nx, ny, nz), nx, ny, nz)
	if hit then
		return hit
	end
	return BAS_Projectile.zombieInSquare(cell:getGridSquare(nx, ny, nz - 1), nx, ny, nz)
end

-- Shared aim math. Returns:
--     dx, dy    unit aim direction on the ground plane, toward the cursor
--     pitch     the launch angle that lands this shot on `dist` (LOW solution)
--     stats     the bow's stat table
--     dist      the distance this shot is solved for: the cursor distance,
--               clamped into [RANGE_MIN, min(RANGE_MAX, physical reach)]. A
--               weak draw therefore lands SHORT of the cursor (MC behaviour)
--               instead of failing to solve.
--     v         this shot's charge-scaled launch speed
--     maxRange  the outer bound of this shot (min(RANGE_MAX, reach)) -- for the
--               red ring. NOT the landing point: that is the preview arc's tip.
BAS_Projectile.getAim = function(player, weapon)
	local stats = BAS_Projectile.stats[weapon:getFullType()]
	if not stats then
		return nil
	end
	local targetZ = math.floor(player:getZ())
	local mouseX, mouseY = ISCoordConversion.ToWorld(getMouseXScaled(), getMouseYScaled(), targetZ)
	local dx = mouseX - player:getX()
	local dy = mouseY - player:getY()
	local realDist = math.sqrt(dx * dx + dy * dy)
	-- stabilize the direction when the cursor sits right on the player
	if realDist < 0.5 then
		if BAS_Projectile.lastDx and BAS_Projectile.lastDy then
			dx, dy = BAS_Projectile.lastDx, BAS_Projectile.lastDy
			realDist = 1
		else
			realDist = 0.1
		end
	end
	-- CURSOR -> DISTANCE, exactly like Minecraft's "the arrow follows where you
	-- point". The cursor's ground point is the target; the shot is solved to land
	-- on it, BUT only as far as this draw can actually carry it.
	-- IMPORTANT: normalize with the REAL distance, otherwise the direction
	-- vector is not unit length and the trajectory/scatter runs wild.
	dx, dy = dx / realDist, dy / realDist
	BAS_Projectile.lastDx, BAS_Projectile.lastDy = dx, dy
	-- SPEED = the draw, straight from Wurst's throwPower = 3f: LINEAR in the
	-- draw with no floor, so the reach falls off as the square of the draw.
	local chargeFrac = 1
	local ch = BAS_Client and BAS_Client.charge
	if ch then
		if ch < 0 then
			ch = 0
		elseif ch > 100 then
			ch = 100
		end
		chargeFrac = ch / 100
	end
	local v = stats.speed
		* (BAS_Projectile.CHARGE_SPEED_MIN + (1 - BAS_Projectile.CHARGE_SPEED_MIN) * chargeFrac)
	local g = stats.gravity
	local startZ = player:getZ() + BAS_Projectile.LAUNCH_HEIGHT
	local dz = targetZ - startZ
	-- PHYSICAL REACH of this shot: its range fired at the optimal angle from the
	-- real launch height (45 degrees on flat ground). This is what makes a weak
	-- draw fall SHORT of the cursor rather than fail to solve: the target is
	-- clamped to what the bow can actually do, and the preview shows the tip
	-- stopping there -- the MC behaviour of an under-drawn arrow.
	local h = startZ - targetZ
	local reach = BAS_Projectile.rangeAtAngle(v, g, math.pi / 4, h)
	-- spread (uncertainty): random angle jitter scaled by the bow type and
	-- the Aiming skill level (MC-style: skilled archers shoot straight).
	-- The preview and the shot share this code, so the prediction stays
	-- honest: it wobbles exactly as much as the real arrow will.
	--
	-- TEMPORARILY OFF (2026-09-19): the jitter is re-rolled every frame, so the
	-- preview arc wobbles and is impossible to read while aiming. Set this to
	-- true (nothing else) to bring the "wander" back once the rest is finished.
	BAS_Projectile.SPREAD_ENABLED = false
	local spread = stats.spread or 0
	if BAS_Projectile.SPREAD_ENABLED and spread > 0 then
		local skill = player:getPerkLevel(Perks.Aiming)
		if skill < 0 then
			skill = 0
		elseif skill > 10 then
			skill = 10
		end
		local spreadRad = spread * (1 - skill * 0.07)
		if spreadRad < 0.004 then
			spreadRad = 0.004
		end
		local ang = math.atan2(dy, dx) + ZombRandFloat(-1, 1) * spreadRad
		dx, dy = math.cos(ang), math.sin(ang)
	end
	-- The distance this shot is solved for: the cursor, clamped into
	-- [RANGE_MIN, min(RANGE_MAX, reach)]. The RANGE_MAX half is the hard rule
	-- (nothing shoots past 26 tiles); the `reach` half is physics, and it is the
	-- one that bites on a weak draw. `maxRange` is reported separately so the red
	-- ring can show the outer bound instead of the landing point.
	-- NOTE the + LAUNCH_AHEAD: `reach` is measured from the MUZZLE, `dist` from
	-- the PLAYER. Clamping player-relative against muzzle-relative would let the
	-- solve ask for 0.5 tiles more than the arrow can do and fall into the
	-- 45-degree guard right at the boundary.
	local maxRange = BAS_Projectile.RANGE_MAX
	local reachFromPlayer = reach + BAS_Projectile.LAUNCH_AHEAD
	if reachFromPlayer < maxRange then
		maxRange = reachFromPlayer
	end
	local dist = realDist
	if dist > maxRange then
		dist = maxRange
	end
	-- the floor only applies when this shot can even carry that far (a
	-- nearly-undrawn bow has a reach below RANGE_MIN)
	if dist < BAS_Projectile.RANGE_MIN and maxRange >= BAS_Projectile.RANGE_MIN then
		dist = BAS_Projectile.RANGE_MIN
	end
	-- Solve the LOW-angle launch that lands exactly on `dist`, from the real
	-- launch height. `inner` has no solution only if `dist` exceeds the reach
	-- computed above -- impossible now, since dist <= reach -- so the 45-degree
	-- fallback below is a guard, not a path anything should take.
	local pitch = 0.15
	local targetDist = dist - BAS_Projectile.LAUNCH_AHEAD
	if targetDist > 1 then
		local v2 = v * v
		local inner = v2 * v2 - g * (g * targetDist * targetDist + 2 * dz * v2)
		if inner >= 0 then
			local den = g * targetDist
			if den > 0 then
				pitch = math.atan((v2 - math.sqrt(inner)) / den)
			end
		else
			pitch = math.pi / 4
		end
	end
	-- v and maxRange come back out because the caller cannot derive them: `v`
	-- drives the preview integration and `maxRange` (the reach) drives the ring.
	return dx, dy, pitch, stats, dist, v, maxRange
end

BAS_Projectile.launch = function(player, weapon)
	-- Use the EXACT aim state of the current frame's preview
	-- (BAS_Projectile.currentAim is refreshed by traceTrajectory while
	-- aiming): the shot flies precisely along the shown parabola with
	-- zero drift (same mouse, same pitch, same direction).
	local aim = BAS_Projectile.currentAim
	if not aim then
		return
	end
	local stats = aim.stats
	if not stats or not weapon:getModData().BAS_lastArrow then
		return
	end
	local arrowType = weapon:getModData().BAS_lastArrow
	local arrow = instanceItem(arrowType)
	if not arrow then
		return
	end
	local startX, startY, startZ = aim.startX, aim.startY, aim.startZ
	-- The world item exists for the whole flight, but it is NOT what you see:
	-- while the arrow is in the air it is drawn by the Java flight body (spawned
	-- a few lines below), because a world item cannot be rotated. The item is
	-- still created up front so that (a) the plain-world-item fallback works
	-- when the bridge is missing and (b) the arrow is already an item when it
	-- lands. syncWorldItem() is what re-registers it per step in that fallback
	-- path -- IsoWorldInventoryObject has no position setters, so travelling
	-- means re-adding it every step.
	local p = {
		item = arrow,
		x = startX,
		y = startY,
		z = startZ,
		startX = startX,
		startY = startY,
		-- MUST be stored: step() derives the ground plane from it
		-- (math.floor(startZ)). Without this field it fell back to the
		-- CURRENT height, so once the arrow climbed above z = 1 the "ground"
		-- moved up with it, the arrow was declared landed in mid-air and the
		-- dropped item was placed on the wrong floor.
		startZ = startZ,
		targetDist = aim.targetDist or (BAS_Projectile.RANGE_MAX - BAS_Projectile.LAUNCH_AHEAD),
		xSpeed = aim.xSpeed,
		ySpeed = aim.ySpeed,
		zSpeed = aim.zSpeed,
		gravity = stats.gravity,
		stats = stats,
		arrowType = arrowType,
		character = player,
		-- draw charge at the shot moment: full draw = 2x damage (MC style).
		-- Owned by the bow engine (BAS_Client.charge), NOT by the charge UI --
		-- the shot must not depend on a UI element being alive.
		charge = (BAS_Client and BAS_Client.charge) or 100,
		alive = true,
		frames = 0,
		-- Flight trail: world-space samples of where this arrow has been.
		-- BASArrowUI draws them as a fading line so the shot stays readable
		-- even though the arrow crosses ~0.35 tiles per frame.
		trail = {},
	}
	-- 3D flight body. A world inventory object cannot rotate (it has no angle
	-- interface at all), so while the arrow is IN THE AIR it is drawn by a
	-- custom IsoMovingObject whose SpriteModel.rotate is rewritten every step
	-- -- that is what makes the head follow the flight direction. The plain
	-- world item is only created once it lands (see placeItem).
	-- The model's +X axis is the arrow head, so yaw aims it along the
	-- horizontal velocity; pitch is recomputed each step from the climb rate.
	p.hsp = math.sqrt(aim.xSpeed * aim.xSpeed + aim.ySpeed * aim.ySpeed)
	p.yaw = math.deg(math.atan2(aim.ySpeed, aim.xSpeed))
	local a3 = BAS_Projectile.arrow3d()
	if a3 and BAS_Projectile.modelOk(a3) then
		p.body = a3.spawn(p.x, p.y, p.z, p.yaw, 0)
		-- TEMP DIAG (delete once the flying arrow is confirmed visible): dumps
		-- the bridge state exactly once per session, on the first shot.
		if not BAS_Projectile.diagDone then
			BAS_Projectile.diagDone = true
			print("[BAS] arrow3d probe -> " .. tostring(BAS_Projectile._modelOkReport or "n/a"))
			print("[BAS] arrow3d spawn -> body=" .. tostring(p.body))
		end
	end
	table.insert(BAS_Projectile.active, p)
end

BAS_Projectile.update = function()
	local list = BAS_Projectile.active
	for i = #list, 1, -1 do
		local p = list[i]
		if not p.alive then
			table.remove(list, i)
		else
			BAS_Projectile.step(p)
		end
	end
end

BAS_Projectile.step = function(p)
	local cell = getCell()
	local divisions = 2
	p.frames = (p.frames or 0) + 1
	-- Hard safety caps: no arrow ever flies past the range rule (RANGE_MAX from
	-- the player, i.e. RANGE_MAX - LAUNCH_AHEAD from the muzzle) or for more than
	-- 3000 frames, and the preview stops at the exact same point. Since the aim
	-- model changed (fixed angle + charge-driven speed) this branch is a CEILING,
	-- not the normal landing: at a full draw the physics lands right on it, and a
	-- weaker draw lands earlier on its own. It only bites when shooting downhill,
	-- where gravity alone would carry the arrow past 26 tiles.
	local targetDist = p.targetDist or (BAS_Projectile.RANGE_MAX - BAS_Projectile.LAUNCH_AHEAD)
	-- same as the preview: the arrow has landed only when it comes back down to
	-- the plane it was fired from. The old "fractional part of z near zero" test
	-- also fired while the arrow was still climbing past any integer height.
	local groundZ = math.floor(p.startZ or p.z)
	for d = 1, divisions do
		if not p.alive then
			return
		end
		local dt = 1 / divisions
		-- same integration as the preview (trapezoid rule for z'' = -g):
		-- `p.z + (p.zSpeed/2)*dt` only moved half the distance
		local nx = p.x + p.xSpeed * dt
		local ny = p.y + p.ySpeed * dt
		local nz = p.z + p.zSpeed * dt - 0.5 * p.gravity * dt * dt
		p.zSpeed = p.zSpeed - p.gravity * dt
		if p.frames > 3000 then
			p.alive = false
			BAS_Projectile.placeItem(p)
			return
		end
		local dxd = nx - p.startX
		local dyd = ny - p.startY
		local nowDist = math.sqrt(dxd * dxd + dyd * dyd)
		if nowDist >= targetDist then
			-- reached the range limit: land EXACTLY on targetDist, using the
			-- very same interpolation as the preview, so the arrow stops where
			-- the arc's tip is drawn. (This used to snap p.x/p.y using
			-- xSpeed/speed, which is aimDir * cos(pitch) -- a slightly wrong
			-- direction that made the shot disagree with the preview.)
			local k = targetDist / nowDist
			p.x = p.startX + dxd * k
			p.y = p.startY + dyd * k
			-- NEVER let the landing z dip below the ground plane. Measured:
			-- a shot that stops exactly on targetDist can interpolate to
			-- z = -0.009, and getGridSquare() floors that to floor -1, finds no
			-- square at all and placeItem() returns silently -- the arrow then
			-- never exists in the world ("shot at the ground, nothing to pick
			-- up"). Clamped to groundZ the square always resolves.
			p.z = math.max(groundZ, p.z + (nz - p.z) * k)
			p.alive = false
			BAS_Projectile.placeItem(p)
			return
		end
		-- landed on the ground: settle EXACTLY onto the ground plane with the
		-- same interpolation the preview uses, and move the item there. This
		-- branch used to just stop, which left the arrow at its previous
		-- substep position and disagreed with the drawn arc.
		if nz <= groundZ then
			local k = (p.z - groundZ) / (p.z - nz)
			if k < 0 then
				k = 0
			elseif k > 1 then
				k = 1
			end
			p.x = p.x + (nx - p.x) * k
			p.y = p.y + (ny - p.y) * k
			p.z = groundZ
			p.alive = false
			BAS_Projectile.placeItem(p)
			return
		end
		local prev = cell:getGridSquare(p.x, p.y, p.z)
		local curr = cell:getGridSquare(nx, ny, nz)
		if prev and curr and prev ~= curr then
			-- A fence is decided by HEIGHT alone, and it must be tested BEFORE
			-- the wall test: isBlockedTo() reports a map fence as a full wall,
			-- which used to stop the arrow at any altitude (fence treated as a
			-- wall). When the arc does clear the top edge, the fence must not
			-- fall through to the wall test either.
			if BAS_Projectile.hasFenceBetween(prev, curr) then
				if nz <= math.floor(nz) + BAS_Projectile.FENCE_HEIGHT then
					p.alive = false
					-- Stop AT the fence, not a substep short of it: without this
					-- the arrow froze at its previous substep position, up to
					-- ~0.35 tiles (and, on a steep arc, most of a tile) away
					-- from the thing it visibly just hit.
					p.x, p.y, p.z = BAS_Projectile.clampToBoundary(p.x, p.y, p.z, nx, ny, nz, prev)
					if p.character then
						p.character:playSound("WoodenStickHit")
					end
					BAS_Projectile.placeItem(p)
					return
				end
				-- high enough: sail over it
			elseif prev:isBlockedTo(curr) then
				p.alive = false
				-- same: settle on the wall face instead of short of it (the
				-- ground and range branches always interpolated; these two never
				-- did -- dictionary BAS11 flagged it as a leftover)
				p.x, p.y, p.z = BAS_Projectile.clampToBoundary(p.x, p.y, p.z, nx, ny, nz, prev)
				BAS_Projectile.placeItem(p)
				return
			end
		end
		-- zombie hit check: the arrow's own level AND the level below (see
		-- zombieAt() for why the second lookup is mandatory), with the z band as
		-- the only gate -- so an arrow that really clears the head (zd > 1.3) is
		-- a guaranteed miss at any altitude.
		local hit = BAS_Projectile.zombieAt(cell, nx, ny, nz)
		if hit then
			BAS_Projectile.hitZombie(p, hit, nx, ny, nz)
			return
		end
		p.x, p.y, p.z = nx, ny, nz
		-- Record the trail once per substep (smoother line than per frame).
		-- Bounded to TRAIL_MAX so a long flight cannot grow it without limit.
		local trail = p.trail
		if trail then
			trail[#trail + 1] = { x = nx, y = ny, z = nz }
			if #trail > BAS_Projectile.TRAIL_MAX then
				table.remove(trail, 1)
			end
		end
	end
	-- Keep the 3D body in step with the simulation, tilting it with the current
	-- climb rate so a rising arrow really points up and a falling one down.
	if p.body and p.body > 0 then
		local a3 = BAS_Projectile.arrow3d()
		if a3 then
			local pitch = math.deg(math.atan2(p.zSpeed, p.hsp or 1))
			a3.pose(p.body, p.x, p.y, p.z, p.yaw or 0, pitch)
		end
	else
		-- No usable 3D body (Java bridge missing, or the model script did not
		-- resolve): fall back to a plain world item so the arrow is at least
		-- VISIBLE in flight. It cannot rotate -- but invisible is worse.
		BAS_Projectile.syncWorldItem(p)
	end
end

-- Register -- or re-register -- the arrow's world object at its current
-- position. Called EVERY step while it flies, and once more when it stops.
--
-- This is the whole reason a flying arrow is visible: the item scripts set
-- WorldStaticModel = BAS_Arrow, and a world inventory object renders its model
-- through IsoWorldInventoryObject.render -> WorldItemModelDrawer.renderMain.
-- No custom entity and no Java bridge are involved.
BAS_Projectile.syncWorldItem = function(p)
	if not p.item then
		return
	end
	-- Resolve the square on the level the arrow was FIRED from. It flies level,
	-- so that is its ground floor; math.floor(p.z) would floor -0.009 to level
	-- -1 and find nothing at all (measured, and that is how the arrow used to
	-- vanish without a trace).
	local level = math.floor(p.startZ or p.z)
	local sq = getCell():getGridSquare(p.x, p.y, level)
	if not sq then
		return
	end
	-- Always detach before re-adding. AddWorldInventoryItem registers the item
	-- with the square's container, so re-adding it while it is still attached
	-- to that same square makes ItemContainer.AddItem log "container already
	-- has id" -- and an arrow stays inside one tile for several frames.
	local wi = p.item:getWorldItem()
	if wi then
		local oldSquare = wi:getSquare()
		if oldSquare then
			oldSquare:transmitRemoveItemFromSquare(wi)
			wi:removeFromSquare()
		end
	end
	-- height 0 = lying ON the floor, exactly what vanilla passes for every
	-- dropped ground item (Resources.java:442, IsoAnimal.java:1803/1903).
	-- Deriving it from p.z made the arrow FLOAT, for two separate reasons:
	--   * z = -0.009 floored to -1, so h became 0.991 -- an arrow hanging a
	--     metre in the air (caught by the [BAS] place probe)
	--   * the wall / fence stop branches leave p.z at flight height, so h was
	--     half a metre or more
	-- A stopped arrow always drops to the ground, so ask for the ground.
	sq:AddWorldInventoryItem(p.item, p.x - math.floor(p.x), p.y - math.floor(p.y), 0)
end

-- Called when the arrow STOPS -- ground, wall, fence, range limit. Settles it
-- on its final position and stops the per-step sync from running again.
BAS_Projectile.placeItem = function(p)
	if not p.item or p.placed then
		return
	end
	p.placed = true
	-- The arrow KEEPS its 3D body after stopping. Nothing re-poses it, so it
	-- stays exactly as it was at the moment of impact -- head down at the
	-- angle it was falling -- which is what makes it look STUCK in the ground
	-- rather than lying flat. The inventory item waits in p.item and is handed
	-- over on approach (see updateLanded), exactly like Minecraft's inGround
	-- arrows, which keep their pose and are collected by walking over them.
	if p.body and p.body > 0 then
		local a3 = BAS_Projectile.arrow3d()
		if a3 then
			-- settle onto the floor of the level it was fired from, keeping the
			-- impact yaw and pitch
			local level = math.floor(p.startZ or p.z)
			local pitch = math.deg(math.atan2(p.zSpeed, p.hsp or 1))
			a3.pose(p.body, p.x, p.y, level, p.yaw or 0, pitch)
			BAS_Projectile.landed[#BAS_Projectile.landed + 1] = p
			return
		end
	end
	-- Fallback when the Java bridge is missing: the old behaviour -- a plain
	-- world item, visible and collectable, just not posed.
	BAS_Projectile.dropBody(p)
	BAS_Projectile.syncWorldItem(p)
end

-- Walk-over pickup for stuck arrows. Called every frame from OnPlayerUpdate,
-- whether or not the bow is in hand.
BAS_Projectile.updateLanded = function(player)
	local list = BAS_Projectile.landed
	if #list == 0 then
		return
	end
	local a3 = BAS_Projectile.arrow3d()
	local r2 = BAS_Projectile.PICKUP_RANGE * BAS_Projectile.PICKUP_RANGE
	for i = #list, 1, -1 do
		local p = list[i]
		if not p.body or p.body <= 0 then
			table.remove(list, i)
		else
			local dx = player:getX() - p.x
			local dy = player:getY() - p.y
			if dx * dx + dy * dy <= r2 then
				if a3 then
					a3.destroy(p.body)
				end
				p.body = nil
				if p.item then
					player:getInventory():AddItem(p.item)
				end
				table.remove(list, i)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- WHERE THE ARROW ENDS UP IN A ZOMBIE (2026-09-25)
--
-- Attached items are the engine's own mechanism, not a custom visual: the arrow
-- becomes a real item hanging off the zombie's AttachedItems, so the ENGINE
-- draws it there and hands it to the corpse on death -- no corpse code of ours
-- runs at all. Slot names are the ones vanilla registers for the "Human" group
-- in media/lua/shared/NPCs/AttachedLocations.lua; the name each slot maps to
-- ("Knife Stomach" -> knife_stomach) is a block inside the arrow's OWN model
-- script (models_arrow.txt).
--
-- WHERE THE POSE COMES FROM (measured 2026-09-25): vanilla writes those blocks
-- on the CHARACTER model -- media/scripts/generated/models_characters.txt,
-- model MaleBody (and FemaleBody) -- with a bone AND an offset AND a rotate:
--     attachment knife_stomach { offset = 0.041 0.002 0.128,
--                                rotate = 3.0 84.0 -99.0, bone = Bip01_Spine }
--     attachment knife_left_leg{ offset = 0.015 -0.007 0.084,
--                                rotate = -89.0 -2.0 -18.0, bone = Bip01_L_Thigh }
-- The arrow's own blocks used to be zero (offset 0 0 0, rotate 0 0 0, no bone),
-- which pinned every arrow to the bone's ORIGIN -- inside the leg, inside the
-- torso, invisible. They now carry vanilla's exact numbers for all six slots, so
-- the arrow lands where a lodged knife lands no matter which side wins.
-- Tune the fit in-game:
--     Debug menu -> Dev -> Attachment -> pick the arrow, drag the gizmo, Save
-- (that editor writes the block straight back into the script).
-- ⚠️ Vanilla's numbers were authored for a knife BLADE, so the arrow may point
-- the wrong way: in that editor, fix the angle first, then the offset.
--
-- The slot is chosen by how high the arrow hit, the same way vanilla's
-- OnBreak.lua picks by hit part and then walks to the next free alternative:
-- head/neck -> JawStab, chest -> shoulder, belly -> stomach, low -> a leg.
-- The first FREE slot wins, so several arrows can stick in one zombie.
-- ---------------------------------------------------------------------------
BAS_Projectile.ATTACH_SLOTS = {
	{ min = 1.10, slots = { "JawStab", "Knife Shoulder", "Knife Stomach", "Stomach" } },
	{ min = 0.75, slots = { "Knife Shoulder", "Knife Stomach", "Stomach" } },
	{ min = 0.35, slots = { "Knife Stomach", "Knife Shoulder", "Stomach" } },
	{ min = -100, slots = { "Knife Left Leg", "Knife Right Leg", "Stomach" } },
}

-- Returns the slot the arrow was lodged in, or nil when every candidate was
-- taken (then the arrow is dropped on the zombie's square rather than lost).
BAS_Projectile.lodgeArrow = function(zombie, item, hz)
	if not (zombie and item) then
		return nil
	end
	local zedZ = zombie:getZ() or 0
	local zd = (hz or zedZ) - zedZ
	local plan = BAS_Projectile.ATTACH_SLOTS[#BAS_Projectile.ATTACH_SLOTS]
	for i = 1, #BAS_Projectile.ATTACH_SLOTS do
		if zd >= BAS_Projectile.ATTACH_SLOTS[i].min then
			plan = BAS_Projectile.ATTACH_SLOTS[i]
			break
		end
	end
	for _, slot in ipairs(plan.slots) do
		-- pcall on both reads and the write: a slot name this engine build does
		-- not know must cost us that slot, never the whole hit (the arrow is
		-- already gone from the world by the time we get here).
		local free = false
		local ok = pcall(function()
			free = zombie:getAttachedItem(slot) == nil
		end)
		if ok and free then
			local set = pcall(function()
				zombie:setAttachedItem(slot, item)
			end)
			if set then
				-- The LIVE attach needs a packet; the corpse handoff does not.
				if isServer() then
					sendAttachedItem(zombie, slot, item)
				end
				return slot
			end
		end
	end
	local sq = zombie:getSquare()
	if sq then
		sq:AddWorldInventoryItem(item, ZombRand(100) / 100, ZombRand(100) / 100, 0.0)
	end
	return nil
end

BAS_Projectile.hitZombie = function(p, zombie, hx, hy, hz)
	-- TEMP DIAG (BAS_Projectile.HIT_DIAG): one line per hit. `arrowLev` vs
	-- `zedLev` shows whether the level-below lookup was the one that found this
	-- zombie; `zd` is the height of the arrow above the zombie's feet, which is
	-- what HIT_Z_HIGH is measured against.
	if BAS_Projectile.HIT_DIAG then
		local ax = hx or p.x
		local ay = hy or p.y
		local az = hz or p.z
		local zd = az - zombie:getZ()
		local hdist = math.sqrt((zombie:getX() - ax) * (zombie:getX() - ax)
			+ (zombie:getY() - ay) * (zombie:getY() - ay))
		local flown = math.sqrt((ax - p.startX) * (ax - p.startX)
			+ (ay - p.startY) * (ay - p.startY))
		print(string.format("[BAS] hit arrowZ=%.2f zedZ=%.2f zd=%.2f hdist=%.2f flown=%.2f arrowLev=%d zedLev=%d",
			az, zombie:getZ(), zd, hdist, flown, math.floor(az), math.floor(zombie:getZ())))
	end
	-- An arrow that hits a zombie never lands, so it never reaches placeItem():
	-- tear down its 3D flight body here instead (nothing is dropped).
	p.alive = false
	BAS_Projectile.dropBody(p)
	local wi = p.item:getWorldItem()
	if wi and wi:getSquare() then
		wi:getSquare():transmitRemoveItemFromSquare(wi)
		wi:removeFromSquare()
	end
	local stats = p.stats
	-- draw-charge damage scaling (MC power_multiplier). p.charge is 0..100, so
	-- the multiplier runs CHARGE_DMG_MIN (a weak let-off shot) .. 2.0 (a full
	-- draw), matching the speed/range scaling applied in getAim().
	local charge = p.charge or 100
	if charge < 0 then
		charge = 0
	elseif charge > 100 then
		charge = 100
	end
	local dmgMult = BAS_Projectile.CHARGE_DMG_MIN
		+ (2.0 - BAS_Projectile.CHARGE_DMG_MIN) * (charge / 100)
	local dmg = (stats.dmgMin + ZombRandFloat(0.0, stats.dmgMax - stats.dmgMin)) * dmgMult
	-- CRIT IS THE FULL DRAW'S REWARD -- but it no longer touches the DAMAGE.
	-- critMult used to sit on top of the charge multiplier (0.20 x 2.0 x 2.0 =
	-- 0.80 on a full draw), which is over the 0.40 ceiling the user set, so the
	-- multiplier is gone. What a crit still buys is the guaranteed
	-- knockdown/flinch just below, and it can only be rolled by a FULL draw
	-- (BAS_Projectile.CRIT_CHANCE) -- a panicked snap shot can never crit.
	local crit = charge >= (BAS_Client and BAS_Client.CHARGE_MAX or 100)
		and ZombRand(100) < BAS_Projectile.CRIT_CHANCE
	local hp = zombie:getHealth()
	zombie:setHealth(hp - dmg)
	-- ------------------------------------------------------------------
	-- IMPACT FEEDBACK (2026-09-25). Until now a hit only moved a number: no
	-- blood, no flinch -- nothing that reads as "I hit it". setHealth() is
	-- silent by design; vanilla's blood and reaction come from
	-- IsoZombie.Hit(), which wants a HandWeapon that this bow is not. So the
	-- pieces are applied directly, all of them vanilla APIs:
	--   addBlood(part, ...)   -- the exact call vanilla's own tutorial uses
	--                            (Tutorial/Steps.lua:597-601)
	--   setStaggerBack(true)  -- the flinch the engine itself applies on a hit
	-- Both are pcall'd: a missing member must cost us the effect, not the hit.
	-- ------------------------------------------------------------------
	-- How high the arrow struck, as a Lua number. `zombie:getZ()` is a Java
	-- float and Kahlua's comparison operators refuse anything that is not a
	-- Lua number ("__le not defined for operand"), so the subtraction is done
	-- against a real Lua number first -- the same shape lodgeArrow() uses.
	local zd = (hz or zombie:getZ() or 0) - (zombie:getZ() or 0)
	local part = BloodBodyPartType.Torso_Upper
	if zd >= 1.0 then
		part = BloodBodyPartType.Head
	end
	pcall(function()
		zombie:addBlood(part, false, true, false)
	end)
	pcall(function()
		zombie:setStaggerBack(true)
	end)
	-- knockback (MC style): PZ has no small push API, so a crit (every full
	-- draw now) always knocks the zombie down, and normal hits have a 20% chance
	if crit or ZombRand(100) < 20 then
		zombie:knockDown(true)
	end
	-- hit sound (MC hit_sound): impact sound at the shooter's position
	if p.character then
		p.character:playSound("SpearCraftedHit")
	end
	if hp - dmg <= 0 then
		zombie:Kill(p.character)
		if zombie:isZombie() then
			zombie:DoZombieInventory()
			triggerEvent("OnZombieDead", zombie)
		end
	end
	-- ------------------------------------------------------------------
	-- Lodge the arrow in the zombie (2026-09-25).
	--
	-- The arrow now STAYS: it hangs off the zombie's own attached items, so the
	-- engine renders it in place and carries it onto the corpse for free. Only
	-- when every slot is taken does the old bookkeeping run -- that path drops
	-- the arrow next to the corpse when the zombie dies (BAS_Bow.OnZombieDead),
	-- so a hit can never hand out two arrows for one shot.
	-- ------------------------------------------------------------------
	local lodged = BAS_Projectile.lodgeArrow(zombie, p.item, hz)
	if lodged then
		if BAS_Projectile.LODGE_DIAG then
			local took, mdl = "?", "?"
			pcall(function()
				took = tostring(zombie:getAttachedItem(lodged) == p.item)
			end)
			pcall(function()
				mdl = tostring(p.item and p.item:getStaticModel())
			end)
			print("[BAS] lodged=" .. tostring(lodged) .. " took=" .. took .. " model=" .. mdl)
		end
	elseif ZombRand(100) < BAS_Bow.recoveryChance[p.arrowType] then
		local modData = zombie:getModData()
		local arrows = modData.BAS_arrows
		if not arrows then
			arrows = {}
			modData.BAS_arrows = arrows
		end
		arrows[p.arrowType] = (arrows[p.arrowType] or 0) + 1
	end
end
