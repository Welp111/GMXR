local _
if SERVER then
	util.AddNetworkString("vrmod_fbt_cal")
	util.AddNetworkString("vrmod_fbt_toggle")
	local caldata = {}
	net.Receive("vrmod_fbt_cal", function(len, ply)
		local requestedPly = net.ReadBool() and net.ReadEntity() or nil
		local steamid = requestedPly and requestedPly:SteamID() or ply:SteamID()
		local cd = caldata[steamid] or {}
		caldata[steamid] = cd
		if not requestedPly then
			for i = 0, 3 do
				cd[i * 2 + 1] = net.ReadVector()
				cd[i * 2 + 2] = net.ReadAngle()
			end
		end

		net.Start("vrmod_fbt_cal")
		net.WriteEntity(requestedPly or ply)
		for i = 0, 3 do
			net.WriteVector(cd[i * 2 + 1])
			net.WriteAngle(cd[i * 2 + 2])
		end

		if requestedPly then
			if ply.hasRequestedVRPlayers then net.Send(ply) end
		else
			local omittedPlayers = {}
			for k, v in ipairs(player.GetAll()) do
				if not v.hasRequestedVRPlayers then omittedPlayers[#omittedPlayers + 1] = v end
			end

			net.SendOmit(omittedPlayers)
		end
	end)

	vrmod.NetReceiveLimited("vrmod_fbt_toggle", 10, 1, function(len, ply)
		net.Start("vrmod_fbt_toggle")
		net.WriteEntity(ply)
		net.WriteBool(net.ReadBool())
		net.Broadcast()
	end)
	return
end

-- CLIENT-SIDE CODE BELOW
local vrmod_fbt = {} -- Module table for organization
-- cl_character reads the tracker targets (GetTargets) to run FBT through
-- Hai IK, and places the body / hull off the waist for both solvers.
vrmod.fbt = vrmod_fbt
local POSE = vrmod.pose or {seq = {}, raw = {}}
vrmod.pose = POSE
vrmod_fbt.characterInfo = {}
vrmod_fbt.convarValues = select(2, vrmod.GetConvars()) -- Cache convars
vrmod_fbt.zeroVec = Vector()
vrmod_fbt.zeroAng = Angle()
vrmod_fbt.oneVec = Vector(1, 1, 1)
-- Per-player body settings (sh_network; client only): the player's own
local CharCfg = vrmod.CharCfg
local function GetPlayerCharacterIK(ply) return CharCfg(ply).characterIK end
-- Bones the trackers are calibrated against. The body itself is solved by
-- cl_character (Hai IK) from GetTargets.
local BONE_NAMES = {
	leftFoot = "ValveBiped.Bip01_L_Foot",
	rightFoot = "ValveBiped.Bip01_R_Foot",
	head = "ValveBiped.Bip01_Head1",
	pelvis = "ValveBiped.Bip01_Pelvis",
}

-- Bone ids and rest foot angles for a player's model. False (and a chat
-- line for the local player) when the model lacks one of the bones.
function vrmod_fbt.Init(ply)
	local steamid = ply:SteamID()
	local info = vrmod_fbt.characterInfo[steamid] or {}
	vrmod_fbt.characterInfo[steamid] = info
	local pmname = ply.vrmod_pm or ply:GetModel()
	if info.modelName == pmname then return true end
	local cm = ClientsideModel(pmname)
	if not IsValid(cm) then return false end
	cm:SetupBones()
	local boneids = {}
	for k, v in pairs(BONE_NAMES) do
		local b = cm:LookupBone(v)
		if not (b and cm:GetBoneMatrix(b)) then
			cm:Remove()
			vrmod_fbt.characterInfo[steamid] = nil
			vrmod.logger.Err("FBT Init failed for %s - missing bone: %s", steamid, k)
			if ply == LocalPlayer() then
				chat.AddText(Color(255, 80, 80), "[VRMod FBT] ", Color(255, 255, 255), "Missing bone for FBT: " .. k .. " (model not FBT-compatible)")
			end
			return false
		end
		boneids[k] = b
	end
	info.boneids, info.modelName = boneids, pmname
	info.defaultLeftFootAngles = cm:GetBoneMatrix(boneids.leftFoot):GetAngles()
	info.defaultRightFootAngles = cm:GetBoneMatrix(boneids.rightFoot):GetAngles()
	cm:Remove()
	vrmod.logger.Info("FBT Init succeeded for %s (model: %s)", steamid, pmname)
	return true
end

-- Reusable frame table for LocalPlayer to avoid per-frame allocation
local localFrame = {}

-- The tracker frame for a player: LocalPlayer reads g_VR.tracking directly
-- (freshest), others the relayed lerped frame. nil when a tracker's missing.
-- Resolved by sh_trackers.lua on rescan, so this stays three table indexes.
-- All three are tested: a foot tracker's battery dying mid-session must not
-- error the bone callback.
function vrmod_fbt.GetFrame(ply)
	local fbt = g_VR.fbtPose
	local t = g_VR.tracking
	local waistPose     = fbt and fbt.pelvis    or t.pose_waist
	local leftFootPose  = fbt and fbt.leftfoot  or t.pose_leftfoot
	local rightFootPose = fbt and fbt.rightfoot or t.pose_rightfoot
	local frame
	if ply == LocalPlayer() and waistPose and leftFootPose and rightFootPose then
		local f = localFrame
		f.waistPos = waistPose.pos; f.waistAng = waistPose.ang
		f.leftfootPos = leftFootPose.pos; f.leftfootAng = leftFootPose.ang
		f.rightfootPos = rightFootPose.pos; f.rightfootAng = rightFootPose.ang
		frame = f
	else
		frame = g_VR.net[ply:SteamID()] and g_VR.net[ply:SteamID()].lerpedFrame
	end
	-- a relayed frame can lack waistPos right after a remote toggles FBT off
	if frame and frame.waistPos then return frame end
end

-- Calibrated tracker targets, once per frame per player: pelvis (tracker
-- frame + the pelvis bone's angle), both foot bones (position, angle), and
-- the stick-walk leg blend (0 trackers .. 1 walk anim; only upright -- the
-- walk cycle on a body lying down wrecked the legs). nil until calibrated.
local fbtTargets = {}
function vrmod_fbt.GetTargets(ply)
	local steamid = ply:SteamID()
	local info = vrmod_fbt.characterInfo[steamid]
	if not info or not info.waistCalibrationPos or not info.defaultLeftFootAngles then return end
	local T = fbtTargets[steamid]
	if not T then
		T = {}
		fbtTargets[steamid] = T
	end
	local fn = FrameNumber()
	if T.fn == fn then return T.ok and T or nil end
	T.fn = fn
	local frame = vrmod_fbt.GetFrame(ply)
	T.ok = frame ~= nil
	if not frame then return end
	local z = vrmod_fbt.zeroVec
	T.pelvisPos, T.pelvisAng = LocalToWorld(info.waistCalibrationPos, info.waistCalibrationAng, frame.waistPos, frame.waistAng)
	_, T.pelvisBoneAng = LocalToWorld(z, Angle(0, 90, 90), T.pelvisPos, T.pelvisAng)
	local p, a = LocalToWorld(info.leftFootCalibrationPos, info.leftFootCalibrationAng, frame.leftfootPos, frame.leftfootAng)
	T.lfPos = p
	_, T.lfAng = LocalToWorld(z, info.defaultLeftFootAngles, z, a)
	p, a = LocalToWorld(info.rightFootCalibrationPos, info.rightFootCalibrationAng, frame.rightfootPos, frame.rightfootAng)
	T.rfPos = p
	_, T.rfAng = LocalToWorld(z, info.defaultRightFootAngles, z, a)
	local sm
	if ply == LocalPlayer() then
		local wd = g_VR.input and g_VR.input.vector2_walkdirection
		sm = wd and (wd.x * wd.x + wd.y * wd.y) > 0.04 or false
	else
		sm = frame.stickMoving or false
	end
	local target = (GetPlayerCharacterIK(ply) and sm and T.pelvisAng:Up().z > 0.6) and 1 or 0
	T.legBlend = math.Approach(T.legBlend or target, target, RealFrameTime() * 3)
	return T
end

-- Track active calibration session
vrmod_fbt.activeCalibration = vrmod_fbt.activeCalibration or {}
function vrmod_fbt.Calibrate()
	local ply = LocalPlayer()
	-- Cleanup previous calibration if it exists
	if vrmod_fbt.activeCalibration.model then
		vrmod.logger.Info("Resetting previous FBT calibration...")
		vrmod_fbt.activeCalibration.model:Remove()
		ply.RenderOverride = nil
		hook.Remove("PostDrawTranslucentRenderables", "fbt_showtrackers")
		hook.Remove("VRMod_Input", "fbt_cal_input")
		vrmod_fbt.activeCalibration = {}
	end

	-- Create new calibration session
	local calibrationModel = ClientsideModel(ply.vrmod_pm or ply:GetModel())
	vrmod_fbt.activeCalibration.model = calibrationModel
	ply.RenderOverride = function() end
	calibrationModel:SetPos(Vector(g_VR.tracking.hmd.pos.x, g_VR.tracking.hmd.pos.y, ply:GetPos().z))
	calibrationModel:SetAngles(Angle(0, g_VR.tracking.hmd.ang.yaw, 0))
	-- Live match preview.
	--
	-- Which tracker becomes the waist and which become the feet is decided by
	-- measuring against the model's bones, not by whatever role SteamVR or
	-- SlimeVR assigned, so any three trackers work and a SlimeVR rig needs no
	-- role setup at all. The match is recomputed a few times a second and
	-- cached, so what gets committed on confirm is exactly what was on screen.
	local MATCH_INTERVAL = 0.1
	local SLOT_NAMES = { "pelvis", "leftfoot", "rightfoot" }
	local BOX_MIN, BOX_MAX = Vector(-1, -1, -1), Vector(1, 1, 1)
	local COL_MATCHED   = Color(60, 220, 90)
	local COL_UNMATCHED = Color(220, 70, 60)
	local COL_TARGET    = Color(255, 255, 255, 90)
	local unmatchedBuf  = {}
	local boneTargets   = {}
	local nextMatch     = 0

	local function UpdateMatch()
		if not vrmod.MatchFBTTrackers then return end
		if vrmod_fbt.Init(ply) == false then return end
		local info = vrmod_fbt.characterInfo[ply:SteamID()]
		if not info or not info.boneids then return end
		calibrationModel:SetupBones()
		local match, filled = vrmod.MatchFBTTrackers(calibrationModel, info.boneids)
		local ac = vrmod_fbt.activeCalibration
		ac.match, ac.filled, ac.boneids = match, filled, info.boneids
		boneTargets[1] = info.boneids.pelvis
		boneTargets[2] = info.boneids.leftFoot
		boneTargets[3] = info.boneids.rightFoot
		vrmod.GetUnmatchedFBTTrackers(match, unmatchedBuf)
	end

	hook.Add("PostDrawTranslucentRenderables", "fbt_showtrackers", function(depth, sky)
		if depth or sky then return end
		local rt = RealTime()
		if rt >= nextMatch then
			nextMatch = rt + MATCH_INTERVAL
			UpdateMatch()
		end

		local match = vrmod_fbt.activeCalibration.match
		render.SetColorMaterial()

		-- Target bones, with the accept radius drawn around them. Turns
		-- "nothing happened" into "stand closer".
		if boneTargets[1] then
			local radius = vrmod.GetFBTCalRadius and vrmod.GetFBTCalRadius() or 12
			for i = 1, 3 do
				local bone = boneTargets[i]
				local mtx = bone and bone >= 0 and calibrationModel:GetBoneMatrix(bone)
				if mtx then
					render.DrawWireframeSphere(mtx:GetTranslation(), radius, 12, 12,
						(match and match[SLOT_NAMES[i]]) and COL_MATCHED or COL_TARGET, true)
				end
			end
		end

		if match then
			for i = 1, 3 do
				local p = match[SLOT_NAMES[i]]
				if p then render.DrawBox(p.pos, p.ang, BOX_MIN, BOX_MAX, COL_MATCHED) end
			end
		end
		for i = 1, #unmatchedBuf do
			local p = unmatchedBuf[i].pose
			if p and p.pos then render.DrawBox(p.pos, p.ang, BOX_MIN, BOX_MAX, COL_UNMATCHED) end
		end
	end)

	-- Input hook for finalizing calibration
	hook.Add("VRMod_Input", "fbt_cal_input", function(action, pressed)
		if action ~= "boolean_reload" or not pressed then return end
		if vrmod_fbt.Init(ply) == false then return end
		local boneids = vrmod_fbt.characterInfo[ply:SteamID()].boneids
		calibrationModel:SetupBones()

		-- Re-match with commit so the assignment persists. Bail rather than
		-- send a partial calibration: the server stores all four transforms as
		-- one record and a missing foot would poison it until the next run.
		local match, filled
		if vrmod.MatchFBTTrackers then
			match, filled = vrmod.MatchFBTTrackers(calibrationModel, boneids, nil, true)
			if filled < 3 then
				vrmod.logger.Warn(string.format(
					"FBT calibration: matched %d/3 trackers within %s units -- stand with feet apart and try again",
					filled, tostring(vrmod.GetFBTCalRadius())))
				return
			end
		else
			local t = g_VR.tracking
			match = { pelvis = t.pose_waist, leftfoot = t.pose_leftfoot, rightfoot = t.pose_rightfoot }
			if not (match.pelvis and match.leftfoot and match.rightfoot) then return end
		end

		net.Start("vrmod_fbt_cal")
		net.WriteBool(false)
		local function sendBone(bone, tracker)
			local pos, ang = WorldToLocal(calibrationModel:GetBoneMatrix(bone):GetTranslation(), calibrationModel:GetAngles(), tracker.pos, tracker.ang)
			net.WriteVector(pos)
			net.WriteAngle(ang)
		end

		sendBone(boneids.head, g_VR.tracking.hmd)
		sendBone(boneids.pelvis, match.pelvis)
		sendBone(boneids.leftFoot, match.leftfoot)
		sendBone(boneids.rightFoot, match.rightfoot)
		net.SendToServer()
		-- Cleanup calibration session
		calibrationModel:Remove()
		ply.RenderOverride = nil
		hook.Remove("PostDrawTranslucentRenderables", "fbt_showtrackers")
		hook.Remove("VRMod_Input", "fbt_cal_input")
		vrmod_fbt.activeCalibration = {}
		vrmod.logger.Info("FBT calibration completed")
	end)
end

-- Starts FBT for a player
function vrmod_fbt.Start(ply)
	local steamid = ply:SteamID()
	if not g_VR.net[steamid] or vrmod_fbt.Init(ply) == false then return end
	local info = vrmod_fbt.characterInfo[steamid]
	if not info.headCalibrationPos then
		vrmod.logger.Info("FBT Start: no calibration data, requesting from server...")
		net.Start("vrmod_fbt_cal")
		net.WriteBool(true)
		net.WriteEntity(ply)
		net.SendToServer()
		return
	end

	-- cl_character solves the body off GetTargets while this flag is set
	g_VR.fbtActive = g_VR.fbtActive or {}
	g_VR.fbtActive[steamid] = true
	vrmod.logger.Info("FBT started for %s", steamid)
end

-- Stops FBT for a player
function vrmod_fbt.Stop(ply)
	local steamid = ply:SteamID()
	if not g_VR.fbtActive or not g_VR.fbtActive[steamid] then return end
	-- Clear FBT flag; the character system hooks never left so they now
	-- take over bone writing again without needing a full re-Start.
	g_VR.fbtActive[steamid] = nil
	vrmod.logger.Info("FBT stopped for %s", steamid)
end

hook.Add("VRMod_OpenQuickMenu", "fbt_quickmenu", function()
	vrmod.RemoveInGameMenuItem("Calibrate Full-body Tracking")
	vrmod.RemoveInGameMenuItem("Disable Full-body Tracking")
	if not g_VR.sixPoints then return end
	local steamid = LocalPlayer():SteamID()
	local active = g_VR.fbtActive and g_VR.fbtActive[steamid] or false
	if active then
		vrmod.AddInGameMenuItem("Disable Full-body Tracking", 5, 0, function() vrmod_fbt.Stop(LocalPlayer()) end)
	else
		vrmod.AddInGameMenuItem("Calibrate Full-body Tracking", 5, 0, vrmod_fbt.Calibrate, false, "press reload when done")
	end
end)

-- Net receivers
net.Receive("vrmod_fbt_cal", function()
	local ply = net.ReadEntity()
	local steamid = ply:SteamID()
	local info = vrmod_fbt.characterInfo[steamid] or {}
	vrmod_fbt.characterInfo[steamid] = info
	info.headCalibrationPos, info.headCalibrationAng = net.ReadVector(), net.ReadAngle()
	info.waistCalibrationPos, info.waistCalibrationAng = net.ReadVector(), net.ReadAngle()
	info.leftFootCalibrationPos, info.leftFootCalibrationAng = net.ReadVector(), net.ReadAngle()
	info.rightFootCalibrationPos, info.rightFootCalibrationAng = net.ReadVector(), net.ReadAngle()
	vrmod_fbt.Start(ply)
end)

net.Receive("vrmod_fbt_toggle", function()
	local ply = net.ReadEntity()
	if not IsValid(ply) then return end
	if net.ReadBool() then
		vrmod_fbt.Start(ply)
	else
		vrmod_fbt.Stop(ply)
	end
end)

-- VR exit cleanup
hook.Add("VRMod_Exit", "fbt_cleanup", function(ply, steamid)
	vrmod_fbt.Stop(ply)
	if ply == LocalPlayer() then
		hook.Remove("VRMod_Input", "fbt_walk_toggle")
		hook.Remove("VRMod_EnterVehicle", "fbt_enter_vehicle")
		hook.Remove("VRMod_ExitVehicle", "fbt_exit_vehicle")
	end
end)

vrmod.logger.Info("Full-body tracking module loaded")