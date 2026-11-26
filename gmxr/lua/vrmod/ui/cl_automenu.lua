-- lua/vrmod/ui/cl_automenu.lua
-- SteamVR coming up while a map is loaded runs `vrmod` (the settings menu).
--
-- The module looks for the runtime's process. VRMOD_IsHMDPresent can't be the
-- poll: the XR instance it creates is what launches SteamVR. linked = this
-- game holds an XR instance (VR starting or running), so that boot was our
-- own. Only a boot seen happening counts, not a SteamVR already up when the
-- map loads, and not while the menu is already open.
local frame -- the settings menu, from VRMod_Menu
local up    -- runtime state at the last poll; nil = not sampled yet

local function Watch(on)
	up = nil
	if not (on and VRMOD_IsRuntimeRunning) then timer.Remove("vrmod_automenu") return end
	timer.Create("vrmod_automenu", 2, 0, function()
		local now, linked = VRMOD_IsRuntimeRunning()
		if now and up == false and not linked and not IsValid(frame) then RunConsoleCommand("vrmod") end
		up = now
	end)
end

local convars = vrmod.AddCallbackedConvar("vrmod_automenu", nil, "1", nil, "Open the VRMod menu when SteamVR starts while a map is loaded", 0, 1, tobool, Watch)
Watch(convars.vrmod_automenu:GetBool())

hook.Add("VRMod_Menu", "vrmod_automenu", function(f)
	frame = f
	f.SettingsForm:CheckBox("Open this menu when SteamVR starts", "vrmod_automenu")
	f.SettingsForm:ControlHelp("Opens the VRMod menu by itself when SteamVR comes up while a map is loaded.")
end)
