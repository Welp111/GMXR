if CLIENT then
	local convars, convarValues = vrmod.AddCallbackedConvar("vrmod_flashlight_attachment", nil, "0", nil, nil, 0, 2, function(val) return math.floor(tonumber(val) or 0) end)
	local attachments = {"pose_righthand", "pose_lefthand", "hmd",}
	local flashlight = nil
	local fwd, lastPos, lastAng = Vector(), Vector(1e9, 0, 0), Angle() -- scratch; lastPos far so first frame always updates
	vrmod.AddCallbackedConvar("vrmod_flashlight_projtex", nil, "1", nil, nil, 0, 1, function(val) return math.floor(tonumber(val) or 0) end)
	local usingDL, farZ, tanHalf = false, 750, 0.5
	local endPos, lightPos = Vector(), Vector() -- scratch
	-- vrmod_debug_flashlight: prints what the light's origin or beam stops on.
	-- Temporary, for the light-caught-in-the-air reports; strip once settled.
	local cvDbg = CreateClientConVar("vrmod_debug_flashlight", "0", false, false, "Print what the VR flashlight's origin or beam stops on", 0, 1)
	local dbg, dbgNext = cvDbg:GetBool(), 0
	cvars.AddChangeCallback("vrmod_debug_flashlight", function() dbg = cvDbg:GetBool() end, "vrmod_debug_flashlight")
	local function Dbg(what, tr, dist)
		local now = SysTime()
		if now < dbgNext then return end
		dbgNext = now + 0.5
		local e = tr.Entity
		local ok = IsValid(e)
		print(string.format("[Flashlight] %s %.1fu out by %s %s%s", what, dist, ok and e:GetClass() or "world", tostring(ok and e:GetModel() or tr.HitTexture), tr.StartSolid and " (starts inside it)" or ""))
	end
	-- Dynamic-light beam: stops where light would. MASK_SOLID also stopped it
	-- on glass, on grates (fences, railings, invisible walls) and on your own
	-- solids -- what the hands hold, hidden entities, a vehicle you sit in --
	-- which left the light hanging in the air at those.
	local trOut, lp, inside = {}
	local trace = {output = trOut, mask = MASK_OPAQUE_AND_NPCS, filter = function(e) return not (e == lp or e == inside or e:GetNoDraw() or e == g_VR.heldEntityLeft or e == g_VR.heldEntityRight) end}
	-- Light origin rides 10u ahead of the hand/muzzle, and the gun/wall pivot
	-- parks the muzzle ON the wall, so at a wall the origin sat inside the
	-- brush: a projtex origin in solid stops lighting the face in front of it
	-- and holds its last state (the "stuck" beam). Trace to the origin (static
	-- brushes only, same test as hand collisions) and stop 6u short, past the
	-- projtex near plane.
	-- The trace runs from the hand that carries the light, which collision
	-- keeps out of the world. It ran from the eye, and that ray also crossed
	-- whatever stood between head and hand -- a corner reached round, a ledge,
	-- a railing -- and dropped the light there, nowhere near the gun. The eye
	-- is only the fallback for a hand that is itself inside the world
	-- (collisions off, noclip).
	local oOut = {}
	local oTr = {output = oOut, mask = MASK_SOLID_BRUSHONLY}
	local function LightOrigin(out, from, pos, ang, eye)
		out:Set(ang:Forward())
		out:Mul(10)
		out:Add(pos)
		oTr.start, oTr.endpos, oTr.filter = from, out, vrmod.utils.IsStaticBrush
		util.TraceLine(oTr)
		if oOut.StartSolid and eye then
			from, oTr.start = eye, eye
			util.TraceLine(oTr)
		end
		if not oOut.Hit then return end
		if dbg then Dbg("origin stopped", oOut, oOut.Fraction * out:Distance(from)) end
		out:Sub(from)
		local f = oOut.Fraction - 6 / out:Length()
		out:Mul(f > 0 and f or 0)
		out:Add(from)
	end
	net.Receive("vrmod_flashlight", function()
		local enabled = net.ReadBool()
		if not flashlight and enabled then
			surface.PlaySound("items/flashlight1.wav")
			local fov = GetConVar("r_flashlightfov"):GetFloat()
			farZ = GetConVar("r_flashlightfar"):GetFloat()
			-- Projected-texture cone by default; vrmod_flashlight_projtex 0
			-- selects a traced dynamic light instead (one trace + one dlight at
			-- the beam's impact -- no per-model lighting passes, cheaper on weak
			-- GPUs). Applies on next flashlight toggle. The eye stutter blamed
			-- on this projtex was actually the pickup halos (see cl_halos.lua).
			usingDL = convarValues.vrmod_flashlight_projtex ~= 1
			if usingDL then
				flashlight = true
				tanHalf = math.tan(math.rad(fov * 0.5))
				lp = LocalPlayer()
			else
				flashlight = ProjectedTexture()
				-- Casts like the stock flashlight; whether shadows show is the
				-- engine's r_flashlightdepthtexture, not ours to manage.
				flashlight:SetEnableShadows(true)
				flashlight:SetTexture("effects/flashlight001")
				flashlight:SetFOV(fov)
				flashlight:SetFarZ(farZ)
				-- A fresh projtex has no transform: place it on the first
				-- frame, even with the hand where the last one left off
				lastPos.x = 1e9
			end
			-- gmod PreRender, NOT VRMod_PreRender: the VR hook fires inside
			-- RenderScene, and mutating projtex state mid-pipeline under
			-- mat_queue_mode 2 desyncs what each queued eye render samples ->
			-- per-eye flicker at fine fps. PreRender runs before the render
			-- path (df_flashlight's pattern, flicker-free on mcore); the light
			-- trails tracking by one frame, invisible for a cone. Also skip the
			-- mutation entirely while the hand is still -- no Update() means no
			-- queue interaction at all, exactly when flicker is most visible.
			hook.Add("PreRender", "vrmod_flashlight", function()
				if not g_VR.threePoints then return end
				local t = g_VR.tracking[attachments[convarValues.vrmod_flashlight_attachment + 1]]
				local pos, ang = t.pos, t.ang
				local muz = convarValues.vrmod_flashlight_attachment == 0 and g_VR.viewModelMuzzle
				if muz then
					pos = muz.Pos
					if not (g_VR.currentvmi and g_VR.currentvmi.wrongMuzzleAng) then ang = muz.Ang end
				end
				if usingDL then
					fwd:Set(ang:Forward())
					endPos:Set(fwd)
					endPos:Mul(farZ)
					endPos:Add(pos)
					trace.start = pos
					trace.endpos = endPos
					inside = nil
					util.TraceLine(trace)
					-- Begun inside something (the vehicle you sit in, a prop
					-- the muzzle is in): the beam leaves it
					if trOut.StartSolid and IsValid(trOut.Entity) then
						inside = trOut.Entity
						util.TraceLine(trace)
					end
					if dbg and trOut.Fraction * farZ < 64 then Dbg("beam stopped", trOut, trOut.Fraction * farZ) end
					local dl = DynamicLight(lp:EntIndex())
					if dl then
						-- sit on the surface, pulled out along the normal so the
						-- light doesn't bleed through it
						lightPos:Set(trOut.HitNormal)
						lightPos:Mul(8)
						lightPos:Add(trOut.HitPos)
						dl.pos = lightPos
						dl.r, dl.g, dl.b = 255, 250, 235
						dl.brightness = 3
						dl.decay = 1000
						-- spot radius at hit distance from the flashlight FOV
						dl.size = math.Clamp(trOut.Fraction * farZ * tanHalf * 2.2, 96, 600)
						dl.dietime = CurTime() + 0.1
					end
					return
				end
				local dp, dy, dr = ang.p - lastAng.p, ang.y - lastAng.y, ang.r - lastAng.r
				if lastPos:DistToSqr(pos) < 0.25 and dp < 0.5 and dp > -0.5 and dy < 0.5 and dy > -0.5 and dr < 0.5 and dr > -0.5 then return end
				lastPos:Set(pos)
				lastAng:Set(ang)
				-- The hand carrying the light: off the muzzle, that's the gun hand
				local tr = g_VR.tracking
				if muz and vrmod.utils.GunInLeftHand() then t = tr.pose_lefthand end
				LightOrigin(fwd, t.pos, pos, ang, tr.hmd.pos)
				flashlight:SetPos(fwd)
				flashlight:SetAngles(ang)
				flashlight:Update()
			end)
		elseif flashlight then
			surface.PlaySound("items/flashlight1.wav")
			hook.Remove("PreRender", "vrmod_flashlight")
			if not usingDL then flashlight:Remove() end -- dlight expires via dietime
			flashlight = nil
		end
	end)

	hook.Add("VRMod_Exit", "flashlight", function(ply, steamid)
		if ply == LocalPlayer() and flashlight then
			hook.Remove("PreRender", "vrmod_flashlight")
			if not usingDL then flashlight:Remove() end
			flashlight = nil
		end
	end)

	-- ── Dynamic Flashlight (df_flashlight) VR bridge ────────────
	-- The addon owns toggle + texture props (shadows/FOV/distance/texture); we
	-- only override the transform to the VR attachment pose. PreRender runs
	-- after Think, so we win whether df renders on Think (render_type 1) or
	-- PreRender (0). For the default we register after df's PreRender hook.
	local function setupDFBridge()
		if not ConVarExists("df_flashlight") then return end
		local player_Iterator = player.Iterator
		local fwd = Vector() -- scratch, reused
		-- pos, ang, then LightOrigin's hand and eye
		local function poseFor(ply, lp)
			if ply == lp then
				if not (g_VR.active and g_VR.threePoints) then return end
				local tr = g_VR.tracking
				local eye = tr.hmd.pos
				local att = convarValues.vrmod_flashlight_attachment
				if att == 0 and g_VR.viewModelMuzzle then -- match native VR feel: emit from muzzle
					local m = g_VR.viewModelMuzzle
					local t = tr.pose_righthand
					local h = vrmod.utils.GunInLeftHand() and tr.pose_lefthand or t
					h = h and h.pos
					if g_VR.currentvmi and g_VR.currentvmi.wrongMuzzleAng then return m.Pos, t and t.ang, h, eye end
					return m.Pos, m.Ang, h, eye
				end
				local t = tr[attachments[att + 1]]
				if t then return t.pos, t.ang, t.pos, eye end
			else -- remote VR player: networked hand pose (right hand; pref isn't networked)
				local n = g_VR.net and g_VR.net[ply:SteamID()]
				local lf = n and n.lerpedFrame
				if lf then return lf.righthandPos, lf.righthandAng, lf.righthandPos, lf.hmdPos end
			end
		end
		local function vrReposition()
			local lp = LocalPlayer()
			for _, ply in player_Iterator() do
				local tex = ply.DynamicFlashlight -- only set by df when flashlight is on
				if tex then
					local pos, ang, hand, eye = poseFor(ply, lp)
					if pos and ang then
						LightOrigin(fwd, hand or pos, pos, ang, eye)
						tex:SetPos(fwd)
						tex:SetAngles(ang)
						tex:Update()
					end
				end
			end
		end
		local function arm()
			hook.Remove("PreRender", "vrmod_df_vr")
			hook.Add("PreRender", "vrmod_df_vr", vrReposition)
		end
		arm()
		-- df can move its render hook to PreRender at runtime; re-arm after it.
		cvars.AddChangeCallback("df_flashlight_render_type", function() timer.Simple(0, arm) end, "vrmod_df_vr")
	end
	-- df may load before or after VRMod; defer if its convar isn't up yet.
	if ConVarExists("df_flashlight") then setupDFBridge()
	else hook.Add("InitPostEntity", "vrmod_df_vr_init", setupDFBridge) end
elseif SERVER then
	util.AddNetworkString("vrmod_flashlight")
	local skip = false
	hook.Add("PlayerSwitchFlashlight", "vrmod_flashlight", function(ply, enabled)
		if skip then return end
		-- Dynamic Flashlight addon present: let it own the on/off toggle and its proj text.
		local df = GetConVar("df_flashlight")
		if df and df:GetBool() then return end
		if g_VR[ply:SteamID()] then
			skip = true
			local res = hook.Run("PlayerSwitchFlashlight", ply, enabled)
			skip = false
			if res == false then return end
			net.Start("vrmod_flashlight")
			net.WriteBool(ply.m_bFlashlight ~= false and enabled)
			net.Send(ply)
			if enabled then
				return false --don't turn on the default flashlight cus we're using a custom one for vr
			end
		end
	end)
end