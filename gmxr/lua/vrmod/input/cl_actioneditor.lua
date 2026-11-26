if SERVER then return end
g_VR = g_VR or {}
vrmod = vrmod or {}
g_VR.CustomActions = g_VR.CustomActions or {}
-- Names this file put into the XR action table (kept on g_VR to survive autorefresh)
local registered = g_VR.customActionNames or {}
g_VR.customActionNames = registered
local open = false
function VRUtilLoadCustomActions()
	local str = file.Read("vrmod/vrmod_custom_actions.txt")
	if str then g_VR.CustomActions = util.JSONToTable(str) or {} end
end

-- Custom actions are plain boolean XR actions. Actions can't be created after
-- the session attaches, so this only fills the table SetupXRActions reads on
-- the next VR start; the input itself is assigned in the XR bindings editor.
local function SyncXRActions()
	local all = vrmod.GetAllActions and vrmod.GetAllActions()
	if not all then return end
	for name in pairs(registered) do
		all[name], registered[name] = nil, nil
	end

	local list = g_VR.CustomActions
	for i = 1, #list do
		local name = list[i][1]
		if name ~= "" and not all[name] then
			all[name] = {type = "boolean", localizedActionName = "Custom: " .. name}
			registered[name] = true
		end
	end
end

VRUtilLoadCustomActions()
timer.Simple(0, SyncXRActions) -- after cl_input.lua has loaded, whatever the include order

concommand.Add("vrmod_actioneditor", function(ply, cmd, args)
	if open then return end
	open = true
	local window = vgui.Create("DFrame")
	window:SetPos(ScrW() / 2 - 350, ScrH() / 2 - 256)
	window:SetSize(700, 512)
	window:SetTitle("VRMod Custom Input Action Editor")
	window:MakePopup()
	local DLabel = vgui.Create("DLabel", window)
	DLabel:SetText("name                    [driving]    concmd on press                                                   concmd on release")
	DLabel:SetPos(15, 31)
	DLabel:SizeToContents()
	function window:OnClose()
		open = false
		-- Drop unnamed entries, duplicates and names that collide with a built-in action
		local all = vrmod.GetAllActions and vrmod.GetAllActions() or {}
		local list, names, i = g_VR.CustomActions, {}, 1
		while i <= #list do
			local name = list[i][1]
			if name == "" or names[name] or all[name] and not registered[name] then
				table.remove(list, i)
			else
				names[name] = true
				i = i + 1
			end
		end

		file.Write("vrmod/vrmod_custom_actions.txt", util.TableToJSON(list, false))
		SyncXRActions()
	end

	local DScrollPanel
	local function UpdateList(scrollTo)
		if DScrollPanel then
			DScrollPanel:Remove()
			DScrollPanel = nil
		end

		DScrollPanel = vgui.Create("DScrollPanel", window)
		DScrollPanel:SetSize(689, 451)
		DScrollPanel:SetPos(6, 56)
		for i = 1, #g_VR.CustomActions do
			local DPanel = DScrollPanel:Add("DPanel")
			DPanel:Dock(TOP)
			DPanel:DockMargin(0, 0, 0, 0)
			DPanel:SetSize(0, 25)
			DPanel:SetPaintBackground(false)
			--name
			local DTextEntry = vgui.Create("DTextEntry", DPanel)
			DTextEntry:SetPos(7, 0)
			DTextEntry:SetSize(110, 20)
			DTextEntry:SetValue(g_VR.CustomActions[i][1])
			local validCharacters = "abcdefghijklmnopqrstuvwxyz0123456789_"
			DTextEntry.AllowInput = function(self, char) if not string.find(validCharacters, char, 1, true) then return true end end
			DTextEntry.OnChange = function(self) g_VR.CustomActions[i][1] = self:GetValue() end
			--use driving actionset?
			local DCheckBox = vgui.Create("DCheckBox", DPanel)
			DCheckBox:SetPos(122, 0)
			DCheckBox:SetValue(g_VR.CustomActions[i].driving or g_VR.CustomActions[i][4] == "1")
			DCheckBox.OnChange = function(self) g_VR.CustomActions[i][4] = self:GetValue() and "1" or "" end
			--cmd on press
			local DTextEntry = vgui.Create("DTextEntry", DPanel)
			DTextEntry:SetPos(7 + 130 + 7, 0)
			DTextEntry:SetSize(225, 20)
			DTextEntry:SetValue(g_VR.CustomActions[i][2])
			DTextEntry.OnChange = function(self) g_VR.CustomActions[i][2] = self:GetValue() end
			--cmd release
			local DTextEntry = vgui.Create("DTextEntry", DPanel)
			DTextEntry:SetPos(7 + 130 + 7 + 225 + 7, 0)
			DTextEntry:SetSize(225, 20)
			DTextEntry:SetValue(g_VR.CustomActions[i][3])
			DTextEntry.OnChange = function(self) g_VR.CustomActions[i][3] = self:GetValue() end
			--remove button
			local DButton = vgui.Create("DButton", DPanel)
			DButton:SetText("REMOVE")
			DButton:SetSize(54, 20)
			DButton:SetPos(608, 0)
			function DButton:DoClick()
				table.remove(g_VR.CustomActions, i)
				UpdateList(DScrollPanel:GetVBar():GetScroll())
			end
		end

		timer.Simple(0, function() if IsValid(DScrollPanel) then DScrollPanel:GetVBar():SetScroll(scrollTo) end end)
	end

	local DButton = vgui.Create("DButton", window)
	DButton:SetText("ADD")
	DButton:SetSize(54, 20)
	DButton:SetPos(614, 31)
	function DButton:DoClick()
		g_VR.CustomActions[#g_VR.CustomActions + 1] = {"", "", "", ""}
		UpdateList(9999999)
	end

	VRUtilLoadCustomActions()
	UpdateList(0)
end)
