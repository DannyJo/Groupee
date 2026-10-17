-- Groupee: shares your XP progress with party members who also run the addon,
-- and shows theirs in a small movable frame and in unit tooltips.

local ADDON_NAME = ...
local PREFIX = "GROUPEE"
local PROTOCOL = 1
local SEND_DELAY = 1        -- seconds to coalesce bursts of XP events into one message
local MAX_PARTY = 4

local BAR_WIDTH, BAR_HEIGHT, BAR_GAP, PADDING = 180, 16, 3, 6

local data = {}             -- [fullName] = { level, cur, max, rested, time }
local sendPending = false

---------------------------------------------------------------------------
-- Compatibility shims (Forever / Retail clients vary in API surface)
---------------------------------------------------------------------------

local SendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix

local function GetRealm()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName():gsub("%s", ""))
end

local function FullName(name, realm)
    if not name then return nil end
    if not realm or realm == "" then
        if name:find("-", 1, true) then return name end
        realm = GetRealm()
    end
    return name .. "-" .. realm
end

local function UnitFullName(unit)
    local name, realm = UnitName(unit)
    return FullName(name, realm)
end

local function GroupChannel()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
end

---------------------------------------------------------------------------
-- Messaging
--   XP:<proto>:<level>:<cur>:<max>:<rested>   our current progress
--   REQ:<proto>                               ask everyone to send theirs
---------------------------------------------------------------------------

local function Send(msg)
    local channel = GroupChannel()
    if channel then
        SendAddonMessage(PREFIX, msg, channel)
    end
end

local function SendXP()
    sendPending = false
    local max = UnitXPMax("player") or 0
    local disabled = IsXPUserDisabled and IsXPUserDisabled()
    if disabled then max = 0 end
    Send(string.format("XP:%d:%d:%d:%d:%d", PROTOCOL, UnitLevel("player"),
        max > 0 and UnitXP("player") or 0, max, GetXPExhaustion() or 0))
end

local function QueueSendXP()
    if sendPending then return end
    sendPending = true
    C_Timer.After(SEND_DELAY, SendXP)
end

local UpdateDisplay -- forward declaration

local function OnAddonMessage(prefix, msg, _, sender)
    if prefix ~= PREFIX then return end
    sender = FullName(sender)
    if sender == UnitFullName("player") then return end

    local kind, proto, a, b, c, d = strsplit(":", msg)
    if tonumber(proto) ~= PROTOCOL then return end

    if kind == "XP" then
        data[sender] = {
            level = tonumber(a) or 0,
            cur = tonumber(b) or 0,
            max = tonumber(c) or 0,
            rested = tonumber(d) or 0,
            time = GetTime(),
        }
        UpdateDisplay()
    elseif kind == "REQ" then
        QueueSendXP()
    end
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "GroupeeFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
frame:SetSize(BAR_WIDTH + PADDING * 2, PADDING * 2)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropColor(0, 0, 0, 0.7)
frame:SetScript("OnDragStart", function(self)
    if not GroupeeDB.locked then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    GroupeeDB.pos = { point, relPoint, x, y }
end)
frame:Hide()

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local bars = {}             -- standalone frame bars, by row
local attachedBars = {}     -- [hostFrame] = bar attached to a default party frame

-- An XP bar is two stacked StatusBars: rested XP behind, current XP in front.
-- Position and size are set on bar.rested, which owns the pair.
local function CreateXPBar(parent)
    local rested = CreateFrame("StatusBar", nil, parent)
    rested:SetStatusBarTexture(BAR_TEXTURE)
    rested:SetStatusBarColor(0.0, 0.39, 0.88, 0.5)

    local bar = CreateFrame("StatusBar", nil, rested)
    bar:SetAllPoints()
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetStatusBarColor(0.58, 0.0, 0.55)

    local bg = rested:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local value = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    value:SetPoint("RIGHT", -4, 0)

    bar.rested, bar.value = rested, value
    return bar
end

local function CreateBar(i)
    local bar = CreateXPBar(frame)
    bar.rested:SetSize(BAR_WIDTH, BAR_HEIGHT)
    bar.rested:SetPoint("TOPLEFT", PADDING, -PADDING - (i - 1) * (BAR_HEIGHT + BAR_GAP))

    bar.name = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.name:SetPoint("LEFT", 4, 0)

    bars[i] = bar
    return bar
end

-- Finds the default UI frame showing a party unit. Returns the frame and its
-- style ("classic" for PartyMemberFrameN, "compact" for raid-style party frames).
local function FindPartyFrame(unit, index)
    if CompactPartyFrame and CompactPartyFrame:IsShown() then
        for i = 1, MAX_PARTY + 1 do
            local f = _G["CompactPartyFrameMember" .. i]
            if f and f:IsShown() and f.unit and UnitIsUnit(f.unit, unit) then
                return f, "compact"
            end
        end
    end
    local f = _G["PartyMemberFrame" .. index] or (PartyFrame and PartyFrame["MemberFrame" .. index])
    if f and f:IsShown() then
        return f, "classic"
    end
end

local function GetAttachedBar(host, style)
    local bar = attachedBars[host]
    if bar then return bar end

    bar = CreateXPBar(host)
    local rested = bar.rested
    rested:SetFrameLevel(host:GetFrameLevel() + 5)
    if style == "compact" then
        -- Raid-style frames are tightly stacked, so use a thin strip along the
        -- top edge with no text; the tooltip still shows the exact value.
        rested:SetPoint("TOPLEFT", 1, -1)
        rested:SetPoint("TOPRIGHT", -1, -1)
        rested:SetHeight(3)
        bar.value:Hide()
    else
        -- Sit directly under the mana bar, matching its width.
        local mana = host.manabar or host.ManaBar or _G[(host:GetName() or "") .. "ManaBar"]
        local anchor = mana or host
        rested:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -1)
        rested:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -1)
        rested:SetHeight(8)
        local font, _, flags = bar.value:GetFont()
        bar.value:SetFont(font, 8, flags ~= "" and flags or "OUTLINE")
        bar.value:ClearAllPoints()
        bar.value:SetPoint("CENTER")
    end

    attachedBars[host] = bar
    return bar
end

local function ClassColoredName(unit)
    local name = UnitName(unit) or "?"
    local _, class = UnitClass(unit)
    local color = class and RAID_CLASS_COLORS[class]
    if color then
        return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
    end
    return name
end

-- Returns "45.2%", "Max level" or nil when we have no data for the unit.
local function FormatProgress(info)
    if not info then return nil end
    if info.max <= 0 then return "Max level" end
    return string.format("%.1f%%", info.cur / info.max * 100)
end

local function SetProgress(bar, info)
    if info and info.max > 0 then
        bar:SetMinMaxValues(0, info.max)
        bar:SetValue(info.cur)
        bar.rested:SetMinMaxValues(0, info.max)
        bar.rested:SetValue(math.min(info.max, info.cur + info.rested))
    else
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(info and 1 or 0)
        bar.rested:SetMinMaxValues(0, 1)
        bar.rested:SetValue(0)
    end
    bar.value:SetText(FormatProgress(info) or "|cff808080no addon|r")
    bar.rested:Show()
end

function UpdateDisplay()
    local shown = 0
    local usedHosts = {}
    if not GroupeeDB.hidden and IsInGroup() then
        for i = 1, MAX_PARTY do
            local unit = "party" .. i
            if UnitExists(unit) then
                local info = data[UnitFullName(unit)]
                local host, style
                if GroupeeDB.attach ~= false then
                    host, style = FindPartyFrame(unit, i)
                end

                if host then
                    usedHosts[host] = true
                    SetProgress(GetAttachedBar(host, style), info)
                else
                    shown = shown + 1
                    local bar = bars[shown] or CreateBar(shown)
                    local level = info and info.level or UnitLevel(unit)
                    bar.name:SetText(string.format("%s |cffffd100%d|r", ClassColoredName(unit), level))
                    SetProgress(bar, info)
                end
            end
        end
    end

    for host, bar in pairs(attachedBars) do
        if not usedHosts[host] then bar.rested:Hide() end
    end
    for i = shown + 1, #bars do
        bars[i].rested:Hide()
    end

    if shown > 0 then
        frame:SetHeight(PADDING * 2 + shown * BAR_HEIGHT + (shown - 1) * BAR_GAP)
        frame:Show()
    else
        frame:Hide()
    end
end

local function RestorePosition()
    frame:ClearAllPoints()
    local pos = GroupeeDB.pos
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -220)
    end
end

---------------------------------------------------------------------------
-- Tooltip: add "XP: 45.2%" when hovering a grouped player with the addon
---------------------------------------------------------------------------

local function OnTooltipSetUnit(tooltip)
    local _, unit = tooltip:GetUnit()
    if not unit or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
    local info = data[UnitFullName(unit)]
    local text = FormatProgress(info)
    if text then
        if info.max > 0 and info.rested > 0 then
            text = string.format("%s |cff4080ff(+%.0f%% rested)|r", text, info.rested / info.max * 100)
        end
        tooltip:AddLine("XP: " .. text, 0.8, 0.5, 1)
        tooltip:Show()
    end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if tooltip == GameTooltip then OnTooltipSetUnit(tooltip) end
    end)
else
    GameTooltip:HookScript("OnTooltipSetUnit", OnTooltipSetUnit)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_XP_UPDATE")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("UPDATE_EXHAUSTION")
events:RegisterEvent("UNIT_LEVEL")
events:RegisterEvent("CHAT_MSG_ADDON")

events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        GroupeeDB = GroupeeDB or {}
        RegisterPrefix(PREFIX)
        RestorePosition()
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Covers login and /reload: ask the group to resend, and share ours.
        if IsInGroup() then Send("REQ:" .. PROTOCOL) end
        QueueSendXP()
        UpdateDisplay()
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Every member sees this when someone joins, so each one resends.
        QueueSendXP()
        UpdateDisplay()
        -- The default party frames may reassign units after we run; refresh again.
        C_Timer.After(0.2, UpdateDisplay)
    elseif event == "UNIT_LEVEL" then
        UpdateDisplay()
    else
        QueueSendXP()
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_GROUPEE1 = "/groupee"
SlashCmdList.GROUPEE = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "lock" then
        GroupeeDB.locked = true
        print("Groupee: frame locked.")
    elseif msg == "unlock" then
        GroupeeDB.locked = false
        print("Groupee: frame unlocked, drag to move.")
    elseif msg == "reset" then
        GroupeeDB.pos = nil
        RestorePosition()
        print("Groupee: position reset.")
    elseif msg == "hide" then
        GroupeeDB.hidden = true
        UpdateDisplay()
    elseif msg == "show" then
        GroupeeDB.hidden = false
        UpdateDisplay()
    elseif msg == "attach" then
        GroupeeDB.attach = true
        UpdateDisplay()
        print("Groupee: bars attached to party frames.")
    elseif msg == "detach" then
        GroupeeDB.attach = false
        UpdateDisplay()
        print("Groupee: bars shown in a separate window.")
    elseif msg == "sync" then
        if IsInGroup() then Send("REQ:" .. PROTOCOL) end
        QueueSendXP()
    else
        print("Groupee commands: /groupee attach | detach | lock | unlock | reset | show | hide | sync")
    end
end

---------------------------------------------------------------------------
-- Addon compartment (minimap dropdown): left-click shows/hides, right-click
-- toggles between party-frame bars and the separate window.
---------------------------------------------------------------------------

function Groupee_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then
        GroupeeDB.attach = GroupeeDB.attach == false
        print(GroupeeDB.attach and "Groupee: bars attached to party frames."
            or "Groupee: bars shown in a separate window.")
    else
        GroupeeDB.hidden = not GroupeeDB.hidden
        print(GroupeeDB.hidden and "Groupee: hidden." or "Groupee: shown.")
    end
    UpdateDisplay()
end

function Groupee_OnAddonCompartmentEnter(_, menuButton)
    GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    GameTooltip:SetText("Groupee")
    GameTooltip:AddLine("Left-click: show / hide", 1, 1, 1)
    GameTooltip:AddLine("Right-click: attach / detach bars", 1, 1, 1)
    GameTooltip:Show()
end

function Groupee_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
