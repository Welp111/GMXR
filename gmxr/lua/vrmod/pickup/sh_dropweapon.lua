local blacklist_path = "vrmod/vrmod_drop_blacklist.txt"
-- Shared blacklist check
local function InBlackList(weaponClass)
    if weaponClass == "weapon_vrmod_empty" then return true end
    if not file.Exists(blacklist_path, "DATA") then return false end
    local content = file.Read(blacklist_path, "DATA") or ""
    for line in string.gmatch(content, "[^\r\n]+") do
        if string.Trim(line) == weaponClass then return true end
    end
    return false
end

if SERVER then
    local debug_arcvr = CreateConVar("vrmod_debug_arcvr_ammo", "0", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Debug ArcticVR ammo stasis")

    -- Create blacklist file with defaults if missing
    if not file.Exists(blacklist_path, "DATA") then
        local default_blacklist = {"weapon_fists", "piss_swep", "weapon_bsmod_punch", "weapon_vrmod_empty", "weapon_haax_vr", "alex_matrix_stopbullets", "blink", "spartan_kick", "arcticvr_nade_frag", "arcticvr_nade_flash", "arcticvr_nade_smoke"}
        file.Write(blacklist_path, table.concat(default_blacklist, "\n"))
    end

    util.AddNetworkString("ChangeWeapon")
    util.AddNetworkString("DropWeapon")
    util.AddNetworkString("SelectEmptyWeapon")
    net.Receive("ChangeWeapon", function(_, ply)
        local weaponClass = net.ReadString()
        if weaponClass and isstring(weaponClass) then ply:SelectWeapon(weaponClass) end
    end)

    net.Receive("SelectEmptyWeapon", function(_, ply) ply:SelectWeapon("weapon_vrmod_empty") end)
    -- A weapon told to holster is no longer the hand's to drop. It stays the
    -- active weapon until the switch lands, and on delayed-holster bases
    -- (TacRP/ARC9/ArcCW) that is the whole holster anim: a grip release in
    -- that window, after a holster store or a weapon-menu switch, threw the
    -- gun. After a store its slot still held the class and re-Gave it on the
    -- next draw: a duplicate. PlayerSwitchWeapon fires on the request,
    -- refused ones included. 2s outlasts the anim without pinning a weapon
    -- that refuses to holster at all.
    hook.Add("PlayerSwitchWeapon", "VRMod_DropSheath", function(ply, old, new)
        if old ~= new then ply.vrmod_sheath, ply.vrmod_sheathT = old, CurTime() + 2 end
    end)
    -- The dropped worldmodel goes where the gun was drawn. The client sends
    -- the pose of the gun's R_Hand bone as it drew it (GripPose, below);
    -- the server rebuilds the model origin around it the way Source's own
    -- Weapon_Drop does: bone pose * inverse(the bone's pose in the model).
    -- The old spawn came off the server's hand -- a network frame late and
    -- extrapolated a frame ahead, so a throw landed well out -- pushed along
    -- the server's R_Hand bone, which on the server is the idle animation's,
    -- not the VR hand's. A left-hand gun got the right bone's offset, and
    -- in worldmodel mode is bone-shifted client-side where the server can't
    -- follow at all. Trusted within 72u of the server's hand, and never
    -- past a wall between the eyes and the grip.
    local R_HAND, DROP_R2 = "ValveBiped.Bip01_R_Hand", 72 * 72
    local trOut = {}
    local trD = {mask = MASK_SOLID_BRUSHONLY, output = trOut}
    local WorldToLocal, LocalToWorld = WorldToLocal, LocalToWorld
    -- A world model's origin in its own R_Hand bone's frame, per model: {pos,
    -- ang}, or false where the bone can't be read. Measured on a bare prop,
    -- never spawned: the gun itself may be the one still in the hand.
    local gripOff = {}
    local function GripOff(mdl)
        local off = gripOff[mdl]
        if off ~= nil then return off end
        off = false
        local e = ents.Create("prop_dynamic")
        if IsValid(e) then
            e:SetModel(mdl)
            local m = e:GetBoneMatrix(e:LookupBone(R_HAND) or 0)
            if m then
                local lp, la = WorldToLocal(m:GetTranslation(), m:GetAngles(), e:GetPos(), e:GetAngles())
                off = {WorldToLocal(vector_origin, angle_zero, lp, la)}
            end
            e:Remove()
        end
        gripOff[mdl] = off
        return off
    end
    net.Receive("DropWeapon", function(_, ply)
        local left = net.ReadBool()
        local rp, ra = net.ReadVector(), net.ReadAngle()
        local rhandvel, rhandangvel = net.ReadVector(), net.ReadVector()
        local shouldStrip = net.ReadBool()
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) or wep.undroppable or ply:InVehicle() or wep == ply.vrmod_sheath and CurTime() < ply.vrmod_sheathT then return end
        local class = wep:GetClass()
        if InBlackList(class) then return end
        local hp, ha = vrmod.utils.GetHandTransform(ply, left)
        if not (hp and rp:DistToSqr(hp) <= DROP_R2) then -- NaN fails too
            if not hp then return end
            rp, ra = hp, Angle(ha.p, ha.y, ha.r + 180) -- R_Hand = hand rolled 180
        end
        trD.start, trD.endpos = ply:EyePos(), rp
        util.TraceLine(trD)
        local shift = trOut.Hit and trOut.HitPos + trOut.HitNormal * 2 - rp
        -- The gun ITSELF is what lands on the floor wherever the hand held the
        -- only copy (the class would be stripped). This used to spawn a fresh
        -- entity of the class and strip the real one every time: everything
        -- the gun carried beyond its clip went with it -- ARC9 / TFA
        -- attachments, fire mode, wear -- and a base told a weapon with no
        -- owner apart (ARC9: no saved preset for it), so what you picked back
        -- up was a bare gun, optic gone. A copy is still what drops while
        -- another one stays behind: a holster slot or the other hand holds the
        -- class (not shouldStrip), an ArcVR dual-wield ghost, and ArcVR guns,
        -- whose magazine state travels by snapshot below.
        local dw = ply._dw
        local real = shouldStrip and not wep.ArcticVR and not (dw and dw.active and dw.class == class)
        local dropEnt = real and wep or ents.Create(class)
        if not IsValid(dropEnt) then return end
        local mdl = wep:GetModel()
        if not real then dropEnt:SetModel(mdl) end
        local pos, ang = rp, ra
        local off = GripOff(mdl)
        if off then pos, ang = LocalToWorld(off[1], off[2], rp, ra) end
        if shift then pos = pos + shift end -- rp may be the hand's live pose

        -- Restore some ammo into dropped weapon if applicable
        local ammoType = wep:GetPrimaryAmmoType()
        local ammoCount = ply:GetAmmoCount(ammoType)
        local clipSize = wep:GetMaxClip1()
        local currentClip = wep:Clip1()
        if ammoCount > 0 and currentClip < clipSize then
            local ammoToGive = math.min(clipSize - currentClip, ammoCount)
            wep:SetClip1(currentClip + ammoToGive)
            ply:RemoveAmmo(ammoToGive, ammoType)
        end

        -- ── ArcticVR ammo stasis ─────────────────────────────────────────────
        local avrSnapshot = nil
        if wep.ArcticVR then
            avrSnapshot = {
                LoadedRounds = wep.LoadedRounds or 0,
                Chambered = wep.Chambered or 0,
                Magazine = wep.Magazine, -- may be nil (no mag inserted)
            }
            if debug_arcvr:GetBool() then
                print("[VRMod ArcVR Debug] Dropping weapon: " .. class)
                print("[VRMod ArcVR Debug] Stamping - LoadedRounds: " .. tostring(avrSnapshot.LoadedRounds) .. " Chambered: " .. tostring(avrSnapshot.Chambered) .. " Mag: " .. tostring(avrSnapshot.Magazine))
            end

            -- CLEAR the active weapon so it doesn't drop a physical magazine when stripped!
            wep.Magazine = nil
            wep.LoadedRounds = 0
            wep.Chambered = 0
        end

        -- ─────────────────────────────────────────────────────────────────────
        local empty = ply:GetWeapon("weapon_vrmod_empty")
        if not IsValid(empty) then empty = ply:Give("weapon_vrmod_empty") end
        ply:SelectWeapon("weapon_vrmod_empty")
        -- Block touch pickup on what we just threw. It lands inside the
        -- player's hull, and a spawned copy is younger than a tick, which
        -- PlayerCanPickupWeapon exempts as a scripted give, so it was grabbed
        -- straight back. Stamped before it is loose in the world. dropT: when,
        -- for the hand's own re-grab guard (sh_manualpickup).
        dropEnt.vrmod_dropCooldown = CurTime() + 1
        dropEnt.vrmod_dropT = CurTime()
        if real then
            -- Delayed-holster bases (ArcCW/ARC9/TacRP/TFA) refused the switch
            -- above and are still active, mid holster anim. Dropping (or
            -- stripping) the active weapon makes the engine switch to the
            -- next best one, so the empty hand takes over first;
            -- SetActiveWeapon skips Deploy, so the viewmodel is pointed at it
            -- too. Their Deploy resets the holster they started, on the next
            -- draw.
            if IsValid(empty) and ply:GetActiveWeapon() ~= empty then
                ply:SetActiveWeapon(empty)
                local vm = ply:GetViewModel()
                if IsValid(vm) then vm:SetWeaponModel(empty:GetWeaponViewModel(), empty) end
            end
            ply:DropWeapon(wep)
            dropEnt:SetPos(pos)
            dropEnt:SetAngles(ang)
        else
            dropEnt:SetPos(pos)
            dropEnt:SetAngles(ang)
            dropEnt:Spawn()
            -- Carry the clip across: without this the spawned entity keeps the SWEP
            -- default (-1 on anything never deployed), so picking your own gun back
            -- up as a duplicate handed back no ammo at all.
            dropEnt:SetClip1(wep:Clip1())
        end
        local phys = dropEnt:GetPhysicsObject()
        if IsValid(phys) then
            phys:Wake()
            phys:SetMass(99)
            phys:SetVelocity(ply:GetVelocity() + rhandvel)
            phys:AddAngleVelocity(-phys:GetAngleVelocity() + phys:WorldToLocalVector(rhandangvel))
        end

        -- Stamp the ArcVR snapshot onto the spawned world entity.
        if avrSnapshot then
            dropEnt.VRMod_ArcVR_Stasis = avrSnapshot
            dropEnt.AVR_LoadedRounds   = avrSnapshot.LoadedRounds
            dropEnt.AVR_Chambered      = avrSnapshot.Chambered
            dropEnt.AVR_Magazine       = avrSnapshot.Magazine
        end

        if shouldStrip and not real then
            -- Double-check: don't strip if a DW ghost of the same class exists.
            if not (dw and dw.active and dw.class == class) then
                -- Delayed-holster bases (ArcCW/ARC9/TacRP) are still active
                -- here, mid holster anim. Stripping the active weapon makes
                -- the engine switch to the next best one, so the empty hand
                -- takes over first; SetActiveWeapon skips Deploy, so the
                -- viewmodel is pointed at it too.
                if IsValid(empty) and ply:GetActiveWeapon() ~= empty then
                    ply:SetActiveWeapon(empty)
                    local vm = ply:GetViewModel()
                    if IsValid(vm) then vm:SetWeaponModel(empty:GetWeaponViewModel(), empty) end
                end
                ply:StripWeapon(class)
            end
        elseif avrSnapshot and IsValid(wep) then
            -- Not stripping — weapon stays in inventory for other copies (holster/DW).
            -- Restore the snapshot so the inventory entity isn't left zeroed.
            wep.LoadedRounds = avrSnapshot.LoadedRounds
            wep.Chambered    = avrSnapshot.Chambered
            wep.Magazine     = avrSnapshot.Magazine
        end
    end)

    concommand.Add("vrmod_toggle_blacklist", function(ply)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) then
            ply:ChatPrint("[VRMod] No active weapon to toggle in blacklist.")
            return
        end

        local class = wep:GetClass()
        local lines = {}
        if file.Exists(blacklist_path, "DATA") then
            for line in string.gmatch(file.Read(blacklist_path, "DATA") or "", "[^\r\n]+") do
                table.insert(lines, string.Trim(line))
            end
        end

        for i, v in ipairs(lines) do
            if v == class then
                table.remove(lines, i)
                file.Write(blacklist_path, table.concat(lines, "\n"))
                ply:ChatPrint("[VRMod] Removed '" .. class .. "' from blacklist.")
                return
            end
        end

        table.insert(lines, class)
        file.Write(blacklist_path, table.concat(lines, "\n"))
        ply:ChatPrint("[VRMod] Added '" .. class .. "' to blacklist.")
    end)
end

hook.Add("WeaponEquip", "VRMod_ArcVR_RestoreStasis", function(wep, ply)
        -- Check if the weapon has a saved stasis snapshot
        if IsValid(wep) and wep.ArcticVR and wep.VRMod_ArcVR_Stasis then
            -- Restore the magazine and ammo variables
            wep.Magazine = wep.VRMod_ArcVR_Stasis.Magazine
            wep.LoadedRounds = wep.VRMod_ArcVR_Stasis.LoadedRounds
            wep.Chambered = wep.VRMod_ArcVR_Stasis.Chambered

            -- Clear the stasis so it doesn't trigger again
            wep.VRMod_ArcVR_Stasis = nil

            -- Delay the sync slightly to ensure the weapon is fully equipped by the player
            timer.Simple(0.1, function()
                if IsValid(wep) and wep.SendWeapon then
                    -- The 'true' argument forces a full sync of the magazine state to the client
                    wep:SendWeapon(false, true)
                end
            end)
        end
    end)

if CLIENT then
    local dropenable = CreateClientConVar("vrmod_weapondrop_enable", 1, true, FCVAR_ARCHIVE, "", 0, 1)
    local droprelease = CreateClientConVar("vrmod_weapondrop_release", 40, true, FCVAR_ARCHIVE, "Grip % below which the held weapon drops (5 = must let go almost fully, 90 = hair trigger)", 5, 90)

    -- Where the held gun's R_Hand bone is as drawn: the server rebuilds the
    -- dropped worldmodel around it. Worldmodel mode: the weapon's own
    -- bonemerged bone, after sh_lefthand's left-hand shift. Viewmodel mode:
    -- the viewmodel is hand * vmi offset in either hand (mirrored for the
    -- left), so undoing the offset gives the hand the gun sits in, and
    -- cl_character's R_Hand is that hand rolled 180.
    local R180, R_HAND = Angle(0, 0, 180), "ValveBiped.Bip01_R_Hand"
    local WorldToLocal, LocalToWorld = WorldToLocal, LocalToWorld
    local function GripPose(left)
        local vm = g_VR.viewModel
        if g_VR.wmActive and IsValid(vm) then
            local m = vm:GetBoneMatrix(vm:LookupBone(R_HAND) or 0)
            if m then return m:GetTranslation(), m:GetAngles() end
        end
        local pos, ang = g_VR.viewModelPos, g_VR.viewModelAng
        local vmi = g_VR.currentvmi
        if vmi then
            local ip, ia = WorldToLocal(vector_origin, angle_zero, vmi.offsetPos, vmi.offsetAng)
            pos, ang = LocalToWorld(ip, ia, pos, ang)
        end
        return LocalToWorld(vector_origin, R180, pos, ang)
    end

    -- The weapon a drop was just sent for is still GetActiveWeapon until the
    -- server's switch comes back. sh_holster asks before storing: the drop
    -- fires on the analog grip threshold and the store on the debounced grip
    -- boolean, so one release on the way into a holster zone could do both,
    -- leaving the gun on the floor and its class in the slot.
    local sentWep, sentT
    function vrmod.WeaponDropSent(wep) return wep == sentWep and CurTime() < sentT end

    -- RE-ARM. The hand that let a gun go grabs nothing until it has opened.
    -- The drop fires as the analog grip falls through vrmod_weapondrop_release
    -- (40%); the grab is the grip boolean, which latches around half closed.
    -- Ten points apart: a hand that dipped under the one and settled back on
    -- the controller crossed the other, with the gun still in its palm (or on
    -- the floor inside the 35u weapon reach), and had it straight back. So
    -- after a drop the grip has to fall well under the release level before
    -- that hand's grab / release reaches the default handler again:
    --   lockLvl[left]  the level to fall under (nil: open again, or a grip
    --                  with no analog value, which has only the time)
    --   lockT[left]    not before this, whatever the grip says
    -- LOCK_MAX: a grip that never reads that low doesn't lose the hand.
    -- A hand holding a pickup is never locked: there is no gun to grab back,
    -- and the release it swallowed left the prop stuck in that hand until
    -- the left hand's two-hand drop cleared it.
    local LOCK_MIN, LOCK_MAX = 0.3, 5
    local lockT, lockLvl = {[true] = 0, [false] = 0}, {}
    local SQUEEZE = {[true] = "vector1_left_squeeze", [false] = "vector1_right_squeeze"}
    local PICK = {boolean_left_pickup = true, boolean_right_pickup = false}
    hook.Add("VRMod_AllowDefaultAction", "VRMod_WeaponDropRearm", function(action)
        local left = PICK[action]
        if left ~= nil and (lockLvl[left] or CurTime() < lockT[left]) and not IsValid(left and g_VR.heldEntityLeft or g_VR.heldEntityRight) then return false end
    end)
    local function Rearm(inp, left, now)
        local lvl = lockLvl[left]
        if not lvl then return end
        local grip = tonumber(inp[SQUEEZE[left]])
        if not grip or grip < lvl or now > lockT[left] + LOCK_MAX then lockLvl[left] = nil end
    end

    -- The gun a drop was sent for, until it is seen ownerless. The weapon
    -- switch hides the active weapon's entity on this client (SetNoDraw, the
    -- viewmodel is what draws) and nothing shows it again; now that the gun
    -- itself is what gets dropped, it would lie there unseen, and not be a
    -- pickup target either.
    local shownWep, shownT

    -- Every weapon drop (release, left release, full holster slot). Strips
    -- the class only when no other copy exists (holster slot or other hand).
    -- Nothing to drop (empty hands, blacklisted, undroppable): no message and
    -- no re-arm lock. Every grip release with empty hands used to send one
    -- the server threw away, and lock that hand's pickup release with it.
    function vrmod.SendWeaponDrop(left)
        local ply = LocalPlayer()
        local wpn = ply:GetActiveWeapon()
        if not IsValid(wpn) or wpn.undroppable or InBlackList(wpn:GetClass()) then return end
        local now = CurTime()
        sentWep, sentT = wpn, now + 1
        shownWep, shownT = wpn, now + LOCK_MAX
        local grip, th = tonumber(g_VR.input[SQUEEZE[left]]), droprelease:GetInt() * 0.01
        lockT[left], lockLvl[left] = now + LOCK_MIN, grip and math.max(th - 0.15, th * 0.5) or nil
        local hs = vrmod_holster
        local p, a = GripPose(left)
        net.Start("DropWeapon")
        net.WriteBool(left)
        net.WriteVector(p)
        net.WriteAngle(a)
        net.WriteVector((left and vrmod.GetLeftHandVelocity or vrmod.GetRightHandVelocity)() * 2.5)
        net.WriteVector((left and vrmod.GetLeftHandAngularVelocity or vrmod.GetRightHandAngularVelocity)() * 2.5)
        net.WriteBool(not (hs and hs.CountWeapon) or hs.CountWeapon(wpn:GetClass()) <= 1)
        net.SendToServer()
    end

    local function DoDrop()
        if not dropenable:GetBool() or g_VR.antiDrop then return end
        local gf = vrmod_gripfix
        if gf and (gf.repos or gf.suppressDrop) then gf.suppressDrop = nil return end
        -- If the right hand is inside a holster zone, the holster system
        -- will handle storage; do not send the drop net message.
        local hs = vrmod_holster
        if hs and (hs.IsHandInHolster(false) or hs.IsStoreSuppressed and hs.IsStoreSuppressed(false)) then return end
        vrmod.SendWeaponDrop(false)
    end

    -- Analog release threshold: while squeeze data exists, this owns dropping.
    -- Arm when grip climbs past threshold + 0.1 hysteresis; drop the moment it
    -- falls back below threshold. vrmod_weapondrop_release is a percent (5-90).
    local armed = false
    hook.Add("Think", "VRMod_WeaponDropAnalog", function()
        local now = CurTime()
        local w = shownWep
        if w then
            if not IsValid(w) or now > shownT then
                shownWep = nil
            elseif not IsValid(w:GetOwner()) then
                w:SetNoDraw(false)
                shownWep = nil
            end
        end
        if not g_VR.active then armed = false return end
        local inp = g_VR.input
        if not inp then return end
        Rearm(inp, false, now)
        Rearm(inp, true, now)
        local grip = tonumber(inp.vector1_right_squeeze)
        if not grip then return end
        local thresh = droprelease:GetInt() * 0.01
        if armed then
            if grip < thresh then
                armed = false
                DoDrop()
            end
        elseif grip >= (thresh > 0.85 and 0.95 or thresh + 0.1) then
            armed = true
        end
    end)

    hook.Add("VRMod_Input", "Weapon_Drop", function(action, state)
        if action ~= "boolean_right_pickup" or state then return end
        -- Fallback only: analog path above handles controllers with squeeze data
        local inp = g_VR.input
        if inp and tonumber(inp.vector1_right_squeeze) then return end
        DoDrop()
    end)
end
