--[[
vrmod_wm_recoil.lua name is kinda outdated since this does normal camera recoil too but whatever

On flatscreen, recoil is where the shot goes relative to where you aim, and the
view, gun and all, turns with it. In VR the gun hangs off the hand instead.
This acts to apply that viewpunch to the gun (with backups)

1. The weapon adds an angle to its owner's aim when it fires (TFA, and the
   engine's own HL2 weapons with the view punch). That still happens in VR:
   shots already leave at aim + angle. Only the picture was missing. The gun
   that is DRAWN is turned by that same angle (R.Kick), and the aim weapons
   are given stays the hand's (R.Aim takes the turn back off for GetAimVector,
   the view angles and the server), so groups land where they did before.

2. The base turns the view itself and fires along it (TacRP, ARC9). In VR
   sh_locomotion writes the hand's aim into every usercmd, so that turn never
   lasted and those weapons had no recoil at all. R.Climb keeps count of the
   turn and R.Out puts it into the usercmd, so the shot follows it as on a
   monitor, and the gun is drawn turned by it like any other.

Either way a weapon's angle reaches this file through one method:
  SWEP:VRAimOffset() -> pitch, yaw [, roll]
what is on top of the hand's aim right now, in view-angle signs (pitch < 0 is
up). Returning nothing says the weapon adds the engine view punch. The engine's
own weapons get the view punch without being asked. A scripted weapon without
a VRAimOffset is left alone: most fire straight down GetAimVector and punch
the view for show, and a gun turned by that would point away from its shots.

Nothing here scales or invents recoil, and a weapon with none gets none.
]]

if SERVER then return end

local cv_enabled = CreateClientConVar("vrmod_wmrecoil_enabled", "1", true, false, "Weapon recoil turns the held gun (and, for bases that turn the view, its shots)")
local on = cv_enabled:GetBool()
cvars.AddChangeCallback("vrmod_wmrecoil_enabled", function() on = cv_enabled:GetBool() end, "wmrecoil")

local LocalPlayer, IsValid, LocalToWorld, WorldToLocal, RealTime = LocalPlayer, IsValid, LocalToWorld, WorldToLocal, RealTime
local math_sin, math_cos = math.sin, math.cos
local vector_origin = vector_origin

local EPS = 1e-4 -- (0.01 deg)^2: an offset can decay toward zero without ever reaching it

-- Never turned: a punched swing would throw the physical melee sweep, and
-- these aren't aimed shots anyway.
local NO_KICK = {melee = true, melee2 = true, knife = true, fist = true, grenade = true, slam = true, physgun = true, camera = true}

local lastWep, gun, offFn = nil, false, nil -- active weapon; it is turned; its VRAimOffset
-- The turn the gun is currently drawn with, as two view angles: the hand's aim
-- and that aim with the recoil angle on. Recoil is pitch and yaw added to the
-- AIM's (never in the gun's own frame, however it is canted), and any roll is
-- about the turned aim, so it moves no shot: turn = A1 * inverse(A0).
local A0, A1 = Angle(), Angle()
local kicked = false
local _v, _o = Angle(), Angle()

local STALE = 0.25                -- s after which the other hook is taken not to be running
local cur, curT = nil, -1         -- kind 2: the active layer's kept turn (its st), and when R.Climb last ran
local handP, handY, handT = 0, 0, -1 -- the hand's aim R.Out last saw, and when
local outY = 0                    -- the yaw R.Out last put on

vrmod_wmrecoil = vrmod_wmrecoil or {}
local R = vrmod_wmrecoil
-- Earlier versions of this file, for a lua refresh over one. The sh_locomotion
-- that went with them calls R.View unguarded: left as a stub so a stale copy
-- can't error every tick.
R.kick, R.frame, R.pre, R.Rotate = nil, nil, nil, nil
R.View = function() end

local function Turn(a)
	local _, l = WorldToLocal(vector_origin, a, vector_origin, A0)
	_, l = LocalToWorld(vector_origin, l, vector_origin, A1)
	return l
end

-- A gun-fixed angle (the muzzle, the gun hand) with the turn taken back off:
-- the hand's aim. What goes into GetAimVector, the usercmd and the server's
-- copy; the weapon or R.Climb puts the recoil on from there, and given the
-- drawn muzzle it would go on twice. Holds for whatever the gun was last
-- placed with, so it is right for a muzzle read at any point before the next
-- placement.
function R.Aim(ang)
	if not kicked then return ang end
	local _, l = WorldToLocal(vector_origin, ang, vector_origin, A1)
	_, l = LocalToWorld(vector_origin, l, vector_origin, A0)
	return l
end

-- From U.UpdateViewModelPos, with the gun hand's final angle (tracking hooks,
-- foregrip's two-hand aim, collisions and the wall pivot all done), just
-- before the gun is placed off it. Returns the angle to place it at. The hand
-- pose takes the turn too: the hand model, body IK, the offhand pinned to the
-- gun and the network frame are all read from it later in the frame.
function R.Kick(ang)
	if not on or not (g_VR.currentvmi or g_VR.wmActive) then kicked = false return ang end
	local ply = LocalPlayer()
	local wep = ply:GetActiveWeapon()
	if wep ~= lastWep then
		lastWep = wep
		-- wm_base and ArcVR move their own guns
		gun = IsValid(wep) and not (wep.IsWMBase or wep.ArcticVR or wep.NotAGun or wep.MeleeDamageType or NO_KICK[wep:GetHoldType()]) or false
		offFn = gun and wep.VRAimOffset or nil
		-- Scripted, and it doesn't say what is on its aim: nothing known to
		-- reach its shots, so nothing to show
		if gun and not offFn and wep:IsScripted() then gun = false end
	end
	if not gun or not IsValid(wep) then kicked = false return ang end

	local p, y, r
	if offFn then p, y, r = offFn(wep) end
	if p then r = r or 0 else p, y, r = ply:GetViewPunchAngles():Unpack() end
	if p * p + y * y + r * r < EPS then kicked = false return ang end

	local left = g_VR.gunInLeftHand or ArcticVR and ArcticVR.GunInLeftHand
	local t = g_VR.tracking
	local pose = left and t.pose_lefthand or t.pose_righthand
	-- The hand's aim: the muzzle as last drawn, with the turn it was drawn
	-- with taken off (R.Aim still holds that one). A frame old, which costs a
	-- fraction of a percent of the angle. No usable muzzle: the hand itself.
	local vmi, muz = g_VR.currentvmi, g_VR.viewModelMuzzle
	local ma = muz and not (vmi and vmi.wrongMuzzleAng) and muz.Ang
	local am = ma and R.Aim(ma) or left and pose and pose.ang or ang
	local ap, ah = am.p, am.y
	A0:SetUnpacked(ap, ah, 0)
	A1:SetUnpacked(ap + p, ah + y, r)
	kicked = true

	-- Left-handed, sh_lefthand places the gun off pose_lefthand at render;
	-- ang (the right hand) isn't the gun's and passes through.
	if left then
		if pose then pose.ang = Turn(pose.ang) end
		return ang
	end
	local a = Turn(ang)
	if pose then
		-- Normally the same angle. A climbing grip keeps the pose off the
		-- collision result the gun is placed at: that one is turned on its own.
		local pa = pose.ang
		pose.ang = pa == ang and a or Turn(pa)
	end
	return a
end

-- Recoil that is a turn of the view (kind 2 above). For a compat layer to
-- call from the client's StartCommand in place of the base's own, SC, with
-- va = cmd:GetViewAngles() read before it: the hand's aim.
--
-- st.p / st.y are what the base has turned the view by so far. The base is
-- handed the hand's aim plus that -- the view it would be looking down on a
-- monitor -- and whatever it then does to it, kick or its own return, becomes
-- the new total. The usercmd leaves with the total on, which is what the
-- weapon fires along on both realms; nothing else is networked. The layer's
-- VRAimOffset returns st.p, st.y, so the gun is drawn turned by the same.
--
-- Putting it on the usercmd is R.Out's job, from sh_locomotion's CreateMove:
-- that hook writes the view angles too, and whether it runs before or after
-- the client's StartCommand is the engine's business. Written here alone,
-- the turn showed on the gun and never reached a shot. It is set here as
-- well, for when this hook is the later one. Returns the hand's pitch, yaw.
--
-- One thing has no monitor equivalent. A mouse is relative: a player who
-- pulled down against the climb is simply looking where they now look. A hand
-- is absolute, and whatever part of the turn the base never takes back would
-- leave the gun off the hand for good. So once the weapon's recoil has died
-- down (rest), that part eases back at rate (1/s, 0 = never). own: the
-- base's table, when the base is returning its share itself; own.RecoilRise
-- (an Angle, as TacRP and ARC9 both keep it) is that share, and is left to it.
--
-- Movement in the usercmd was worked out against the hand's heading; it is
-- turned to the new one, so recoil doesn't steer the walk stick or the
-- roomscale follow. The layer should hand the base its own "last view" back
-- afterwards (cmd:GetViewAngles()), or it reads the easing as mouse input.
function R.Climb(st, SC, ply, cmd, va, rest, rate, own)
	if not on then
		st.p, st.y = 0, 0
		SC(ply, cmd)
		cmd:SetViewAngles(va)
		return (va.p + 180) % 360 - 180, va.y
	end
	local now = RealTime()
	cur, curT = st, now
	-- The hand's aim: what R.Out last saw. va may already carry the turn (R.Out
	-- ran first) or be last frame's view (it runs next). Without R.Out (an
	-- older sh_locomotion), va is the hand's aim itself.
	local ap, ay, oy
	if now - handT < STALE then
		ap, ay, oy = handP, handY, outY
	else
		ap, ay, oy = (va.p + 180) % 360 - 180, va.y, 0 -- Vector:Angle() pitch is 0..360
	end
	local p, y = st.p, st.y
	_v:SetUnpacked(ap + p, ay + y, va.r)
	cmd:SetViewAngles(_v)
	SC(ply, cmd)
	local na = cmd:GetViewAngles()
	p, y = (na.p - ap + 180) % 360 - 180, (na.y - ay + 180) % 360 - 180

	local dt = now - (st.t or now)
	st.t = now
	if rest and rate > 0 and (p ~= 0 or y ~= 0) then
		local k = rate * (dt < 0.1 and dt or 0.1)
		if k > 1 then k = 1 end
		local rise = own and own.RecoilRise -- read after SC: this tick's return is out of it
		p = p - (p - (rise and rise.p or 0)) * k
		y = y - (y - (rise and rise.y or 0)) * k
		if p * p + y * y < EPS then p, y = 0, 0 end
	end
	-- A view stops at straight up and straight down
	local t = ap + p
	t = t > 89 and 89 or t < -89 and -89 or t
	p = t - ap
	st.p, st.y = p, y
	_v:SetUnpacked(t, ay + y, na.r)
	cmd:SetViewAngles(_v)

	-- The walk was worked out against the heading the usercmd had (the
	-- hand's, plus the yaw R.Out put on). Moot when CreateMove is still to
	-- come: it writes the walk afresh.
	oy = y - oy
	if oy ~= 0 then
		local fm, sm = cmd:GetForwardMove(), cmd:GetSideMove()
		if fm ~= 0 or sm ~= 0 then
			local a = oy * 0.017453292519943
			local c, s = math_cos(a), math_sin(a)
			cmd:SetForwardMove(fm * c - sm * s)
			cmd:SetSideMove(fm * s + sm * c)
		end
	end
	return ap, ay
end

-- From sh_locomotion's CreateMove, with the hand's aim it is about to write
-- into the usercmd (R.Aim's result): the same with the kept view turn on.
-- Read at once: the angle returned is a scratch one.
function R.Out(ang)
	local now = RealTime()
	handP, handY, handT = (ang.p + 180) % 360 - 180, ang.y, now
	local st = cur
	if not st or not on or now - curT > STALE or st.p == 0 and st.y == 0 then
		outY = 0
		return ang
	end
	local t = handP + st.p
	outY = st.y
	_o:SetUnpacked(t > 89 and 89 or t < -89 and -89 or t, handY + outY, ang.r)
	return _o
end

hook.Add("VRMod_Exit", "vrmod_wmrecoil_exit", function(ply)
	if ply ~= LocalPlayer() then return end
	lastWep, gun, offFn, kicked = nil, false, nil, false
	cur, curT, handT, outY = nil, -1, -1, 0
end)

concommand.Add("vrmod_wmrecoil_test", function()
	local ply = LocalPlayer()
	local wep = ply:GetActiveWeapon()
	print("[Recoil] enabled:", on, " weapon:", IsValid(wep) and wep:GetClass() or "none", " turned:", gun)
	if not IsValid(wep) then return end
	if not gun then
		if wep:IsScripted() and not wep.VRAimOffset and not NO_KICK[wep:GetHoldType()] then
			print("  scripted weapon with no VRAimOffset (no compat layer for its base)")
		end
		return
	end
	local p, y
	if offFn then p, y = offFn(wep) end
	print("  angle from:", p and "the weapon's VRAimOffset" or "engine view punch")
	if not p then p, y = ply:GetViewPunchAngles():Unpack() end
	print(string.format("  now: pitch %.2f yaw %.2f   gun drawn turned: %s", p, y, tostring(kicked)))
	if cur then
		local now = RealTime()
		print(string.format("  view turn kept for the base: pitch %.2f yaw %.2f   its StartCommand layer ran %.2fs ago, sh_locomotion's R.Out %.2fs ago (either over %.2f: not running)",
			cur.p, cur.y, now - curT, now - handT, STALE))
	end
	local muz = g_VR.viewModelMuzzle
	if muz and muz.Ang then
		local aim = R.Aim(muz.Ang)
		print(string.format("  barrel p %.2f y %.2f   hand's aim p %.2f y %.2f", muz.Ang.p, muz.Ang.y, aim.p, aim.y))
	end
end)
