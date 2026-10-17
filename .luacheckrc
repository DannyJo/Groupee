std = "lua51"
max_line_length = false
exclude_files = { ".release/" }

-- Globals Groupee defines.
globals = {
    "GroupeeDB",
    "Groupee_OnAddonCompartmentClick",
    "Groupee_OnAddonCompartmentEnter",
    "Groupee_OnAddonCompartmentLeave",
    "SLASH_GROUPEE1",
    "SlashCmdList",
}

-- WoW API used by Groupee. Add new API calls here.
read_globals = {
    "_G",
    "BackdropTemplateMixin", "C_AddOns", "C_ChatInfo", "C_Timer", "CompactPartyFrame", "CreateFrame", "Enum",
    "GameTooltip", "GetAddOnMetadata", "GetNormalizedRealmName", "GetRealmName", "GetTime", "GetXPExhaustion",
    "IsInGroup", "IsInRaid", "IsXPUserDisabled", "LE_PARTY_CATEGORY_INSTANCE", "PartyFrame",
    "RAID_CLASS_COLORS", "RegisterAddonMessagePrefix", "SendAddonMessage", "strsplit",
    "TooltipDataProcessor", "UIParent", "UnitClass", "UnitExists", "UnitIsPlayer", "UnitIsUnit",
    "UnitLevel", "UnitName", "UnitXP", "UnitXPMax",
}
