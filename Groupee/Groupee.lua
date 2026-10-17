-- Groupee: shares your XP progress with party members who also run the addon,
-- and shows theirs in a small movable frame and in unit tooltips.

local ADDON_NAME = ...
local PREFIX = "GROUPEE"
local PROTOCOL = 1
local SEND_DELAY = 1        -- seconds to coalesce bursts of XP events into one message
local MAX_PARTY = 4
local XP_RATE_WINDOW = 600  -- XP/hour is averaged over this many seconds
local XP_RATE_MIN = 180     -- seconds to watch a member before showing their XP/hour

local BAR_WIDTH, BAR_HEIGHT, BAR_GAP, PADDING = 180, 16, 3, 6

local data = {}             -- [fullName] = { level, cur, max, rested, time, start, gains }
local versions = {}         -- [fullName] = { version, proto }
local warned = {}           -- [fullName] = true once told they can't share XP with us
local sendPending, versionPending = false, false

---------------------------------------------------------------------------
-- Compatibility shims (Forever / Retail clients vary in API surface)
---------------------------------------------------------------------------

local SendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

local VERSION = GetAddOnMetadata(ADDON_NAME, "Version") or "0"
local newestVersion = VERSION   -- highest version seen in the group this session

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

local function ShortName(fullName)
    return (fullName:gsub("%-.*", ""))
end

-- Compares dotted version strings ("0.10.1") numerically; returns -1, 0 or 1.
local function CompareVersions(a, b)
    local pa, pb = { strsplit(".", a) }, { strsplit(".", b) }
    for i = 1, math.max(#pa, #pb) do
        local x, y = tonumber(pa[i]) or 0, tonumber(pb[i]) or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
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
--   VER:<proto>:<version>                     our addon version
-- VER and REQ are handled whatever their protocol, so clients that can't
-- share XP can still tell each other which one needs updating.
---------------------------------------------------------------------------

local function Send(msg)
    local channel = GroupChannel()
    if channel then
        SendAddonMessage(PREFIX, msg, channel)
    end
end

local function SendXP()
    sendPending = false
    if versionPending then
        versionPending = false
        Send(string.format("VER:%d:%s", PROTOCOL, VERSION))
    end
    local max = UnitXPMax("player") or 0
    local disabled = IsXPUserDisabled and IsXPUserDisabled()
    if disabled then max = 0 end
    Send(string.format("XP:%d:%d:%d:%d:%d", PROTOCOL, UnitLevel("player"),
        max > 0 and UnitXP("player") or 0, max, GetXPExhaustion() or 0))
end

local function QueueSendXP(withVersion)
    if withVersion then versionPending = true end
    if sendPending then return end
    sendPending = true
    C_Timer.After(SEND_DELAY, SendXP)
end

local UpdateDisplay -- forward declaration

-- XP gained between two updates, counting across a level-up. Nil if it can't tell.
local function XPGained(old, level, cur)
    if level == old.level then
        if cur >= old.cur then return cur - old.cur end
    elseif level == old.level + 1 and old.max > 0 then
        return old.max - old.cur + cur
    end
end

local function RecordXP(name, level, cur, max, rested)
    local now = GetTime()
    local info = data[name]
    if not info then
        info = { start = now, gains = {} }
        data[name] = info
    else
        local gained = XPGained(info, level, cur)
        if not gained then
            info.start, info.gains = now, {}
        elseif gained > 0 then
            table.insert(info.gains, { time = now, xp = gained })
        end
        while info.gains[1] and now - info.gains[1].time > XP_RATE_WINDOW do
            table.remove(info.gains, 1)
        end
    end
    info.level, info.cur, info.max, info.rested, info.time = level, cur, max, rested, now
end

-- XP per hour over the last XP_RATE_WINDOW seconds, or nil until we've watched long enough.
local function XPPerHour(info)
    local now = GetTime()
    local span = math.min(XP_RATE_WINDOW, now - info.start)
    if span < XP_RATE_MIN then return nil end
    local total = 0
    for _, gain in ipairs(info.gains) do
        if now - gain.time <= XP_RATE_WINDOW then total = total + gain.xp end
    end
    return total / span * 3600
end

local function OnVersion(sender, proto, version)
    versions[sender] = { version = version, proto = proto }
    local newer = CompareVersions(version, newestVersion) > 0
    if newer then newestVersion = version end

    if proto ~= PROTOCOL then
        if not warned[sender] then
            warned[sender] = true
            print(string.format("Groupee: %s runs Groupee %s, which can't share XP with your %s. %s",
                ShortName(sender), version, VERSION,
                proto > PROTOCOL and "Please update Groupee." or "They need to update Groupee."))
        end
    elseif newer then
        print(string.format("Groupee: version %s is available, you have %s.", version, VERSION))
    end
    UpdateDisplay()
end

local function OnAddonMessage(prefix, msg, _, sender)
    if prefix ~= PREFIX then return end
    sender = FullName(sender)
    if sender == UnitFullName("player") then return end

    local kind, proto, a, b, c, d = strsplit(":", msg)
    proto = tonumber(proto)
    if not proto then return end

    if kind == "VER" and a then
        OnVersion(sender, proto, a)
    elseif kind == "REQ" then
        QueueSendXP(true)
    elseif kind == "XP" and proto == PROTOCOL then
        RecordXP(sender, tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0, tonumber(d) or 0)
        UpdateDisplay()
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

-- Text for a member we have no XP for: no addon, or a version that can't share with ours.
local function NoDataText(name)
    local ver = versions[name]
    if ver and ver.proto < PROTOCOL then return "|cffff8040old version|r" end
    if ver and ver.proto > PROTOCOL then return "|cffff8040newer version|r" end
    return "|cff808080no addon|r"
end

local function SetProgress(bar, info, name)
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
    bar.value:SetText(FormatProgress(info) or NoDataText(name))
    bar.rested:Show()
end

function UpdateDisplay()
    local shown = 0
    local usedHosts = {}
    if not GroupeeDB.hidden and IsInGroup() then
        for i = 1, MAX_PARTY do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitFullName(unit)
                local info = data[name]
                local host, style
                if GroupeeDB.attach ~= false then
                    host, style = FindPartyFrame(unit, i)
                end

                if host then
                    usedHosts[host] = true
                    SetProgress(GetAttachedBar(host, style), info, name)
                else
                    shown = shown + 1
                    local bar = bars[shown] or CreateBar(shown)
                    local level = info and info.level or UnitLevel(unit)
                    bar.name:SetText(string.format("%s |cffffd100%d|r", ClassColoredName(unit), level))
                    SetProgress(bar, info, name)
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
-- Tooltip: add "XP: 45.2%" and "XP/hour: 12.3k, level in 42m" when hovering
-- a grouped player with the addon
---------------------------------------------------------------------------

-- 950 -> "950", 12345 -> "12.3k", 1234567 -> "1.2M"
local function FormatNumber(n)
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return string.format("%d", n)
end

-- 300 -> "5m", 3900 -> "1h 05m"
local function FormatDuration(seconds)
    local minutes = math.max(1, math.ceil(seconds / 60))
    if minutes < 60 then return minutes .. "m" end
    return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

local function OnTooltipSetUnit(tooltip)
    local _, unit = tooltip:GetUnit()
    if not unit or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
    local name = UnitFullName(unit)
    local info = data[name]
    local text = FormatProgress(info)
    if text then
        if info.max > 0 and info.rested > 0 then
            text = string.format("%s |cff4080ff(+%.0f%% rested)|r", text, info.rested / info.max * 100)
        end
        tooltip:AddLine("XP: " .. text, 0.8, 0.5, 1)
        local rate = info.max > 0 and XPPerHour(info)
        if rate and rate > 0 then
            tooltip:AddLine(string.format("XP/hour: %s, level in %s", FormatNumber(rate),
                FormatDuration((info.max - info.cur) / rate * 3600)), 0.8, 0.5, 1)
        end
        tooltip:Show()
    elseif versions[name] and versions[name].proto ~= PROTOCOL then
        tooltip:AddLine("Groupee: " .. NoDataText(name) .. " (" .. versions[name].version .. ")", 0.8, 0.5, 1)
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
        QueueSendXP(true)
        UpdateDisplay()
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Every member sees this when someone joins, so each one resends.
        QueueSendXP(true)
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
        QueueSendXP(true)
    elseif msg == "version" then
        print("Groupee " .. VERSION)
        for i = 1, MAX_PARTY do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitFullName(unit)
                local ver = versions[name]
                local text
                if ver then
                    text = ver.version .. (ver.proto ~= PROTOCOL and " (can't share XP)" or "")
                elseif data[name] then
                    text = "0.2.0 or older"
                else
                    text = "not installed"
                end
                print(string.format("  %s: %s", ClassColoredName(unit), text))
            end
        end
    else
        print("Groupee commands: /groupee attach | detach | lock | unlock | reset | show | hide | sync | version")
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
